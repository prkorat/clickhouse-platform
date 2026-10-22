#!/usr/bin/env bash
# Security and data-flow integration tests against the local Docker cluster (also run in CI).
# Each test logs in as a role-based dev user and asserts what production enforces.
#
#   make test      (runs make up, db-init and seed first)
set -uo pipefail

COMPOSE="docker compose -f $(cd "$(dirname "$0")/.." && pwd)/local/docker-compose.yml"
pass=0; failed=0

as() {  # as <user> <node> <query>
  local user="$1" node="$2"; shift 2
  local pw="dev"; [ "$user" = "admin" ] && pw="admin"
  ${COMPOSE} exec -T "$node" clickhouse-client --user "$user" --password "$pw" --format TSV --query "$*" 2>&1
}

expect_eq() {  # name, expected, actual
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass + 1))
  else echo "  FAIL  $1: expected '$2', got '$3'"; failed=$((failed + 1)); fi
}

expect_err() {  # name, error-substring, actual
  if printf '%s' "$3" | grep -q "$2"; then echo "  PASS  $1"; pass=$((pass + 1))
  else echo "  FAIL  $1: expected error containing '$2', got '$3'"; failed=$((failed + 1)); fi
}

echo "Data flow"
expect_eq  "raw -> analytics MV populated all shards"    "10000" "$(as admin ch-s1-r1 'SELECT count() FROM analytics.events')"
expect_eq  "analytics -> curated MV"                     "10000" "$(as admin ch-s1-r1 'SELECT count() FROM curated.events')"
expect_eq  "both shards hold data"                       "2"     "$(as admin ch-s1-r1 "SELECT uniqExact(shardNum()) FROM curated.events")"
expect_eq  "replica ch-s1-r2 matches ch-s1-r1"           "$(as admin ch-s1-r1 'SELECT count() FROM curated.events_local')" \
                                                         "$(as admin ch-s1-r2 'SYSTEM SYNC REPLICA curated.events_local; SELECT count() FROM curated.events_local' | tail -1)"
expect_eq  "mart aggregates match the fact"              "$(as admin ch-s1-r1 'SELECT sum(amount) FROM analytics.events')" \
                                                         "$(as admin ch-s1-r1 'SELECT sum(revenue) FROM marts.daily_revenue')"

echo "Row-level security (tenant_scope, default-deny)"
expect_eq  "analyst sees only tenant customers 1-10"     "10"    "$(as dev_analyst ch-s2-r1 'SELECT uniqExact(customer_id) FROM curated.events')"
expect_eq  "engineer sees all customers (allow_all)"     "100"   "$(as dev_engineer ch-s2-r1 'SELECT uniqExact(customer_id) FROM curated.events')"

echo "Column-level security and masking"
expect_err "analyst cannot read PII table"               "ACCESS_DENIED" "$(as dev_analyst ch-s1-r1 'SELECT email FROM pii.customers LIMIT 1')"
expect_err "analyst cannot read ungranted column"        "ACCESS_DENIED" "$(as dev_analyst ch-s1-r1 'SELECT * FROM curated.events LIMIT 1')"
expect_eq  "analyst reads masked email via DEFINER view" "us***@example.com" \
                                                         "$(as dev_analyst ch-s1-r1 'SELECT email_masked FROM curated.v_customers_masked WHERE customer_id = 1')"
expect_err "engineer cannot read PII table"              "ACCESS_DENIED" "$(as dev_engineer ch-s1-r1 'SELECT email FROM pii.customers LIMIT 1')"

echo "Write paths and table functions"
expect_err "analyst cannot write"                        "ACCESS_DENIED\|READONLY"      "$(as dev_analyst ch-s1-r1 "INSERT INTO marts.daily_revenue_local (day) VALUES (today())")"
expect_err "API user cannot call s3()"                   "ACCESS_DENIED" "$(as dev_api ch-s1-r1 "SELECT * FROM s3('https://example.com/x.csv') LIMIT 1")"
expect_err "ETL cannot read PII"                         "ACCESS_DENIED" "$(as dev_etl ch-s1-r1 'SELECT * FROM pii.customers LIMIT 1')"

echo "Resource governance (profile constraints)"
expect_err "analyst cannot raise max_execution_time"     "SETTING_CONSTRAINT_VIOLATION" \
                                                         "$(as dev_analyst ch-s1-r1 'SELECT 1 SETTINGS max_execution_time = 3600')"
expect_err "analyst cannot change workload"              "SETTING_CONSTRAINT_VIOLATION" \
                                                         "$(as dev_analyst ch-s1-r1 "SELECT 1 SETTINGS workload = 'ingest'")"

echo "Audit"
as admin ch-s1-r1 "SELECT count() FROM pii.customers WHERE email = 'user1@example.com'" >/dev/null
expect_eq  "PII literals are masked in query_log"        "0"   "$(as admin ch-s1-r1 "SYSTEM FLUSH LOGS; SELECT count() FROM system.query_log WHERE position(query, 'user1@example') > 0 AND query NOT LIKE '%system.query_log%' AND event_time > now() - INTERVAL 1 HOUR" | tail -1)"
expect_err "auditor cannot read business data"           "ACCESS_DENIED" "$(as dev_auditor ch-s1-r1 'SELECT count() FROM curated.events')"

echo
echo "${pass} passed, ${failed} failed"
[ "$failed" -eq 0 ]
