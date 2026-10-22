#!/usr/bin/env bash
# Create the next migration file from a template.
#   scripts/new-migration.sh add_orders_table
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/clickhouse/migrations"
NAME="${1:?usage: new-migration.sh <snake_case_description>}"
[[ "$NAME" =~ ^[a-z0-9_]+$ ]] || { echo "description must be snake_case" >&2; exit 1; }

last="$(find "$DIR" -maxdepth 1 -name "V*__*.sql" -printf '%f\n' | sed -nE 's/^V0*([0-9]+)__.*/\1/p' | sort -n | tail -1)"
next="$(printf 'V%03d' $(( ${last:-0} + 1 )))"
file="${DIR}/${next}__${NAME}.sql"

cat > "$file" <<'EOF'
-- <What this changes and why. Link the ticket.>
--
-- Checklist (reviewers will check):
--   [ ] Every statement has ON CLUSTER '{cluster}' and IF NOT EXISTS / IF EXISTS
--   [ ] New sharded tables: <name>_local (Replicated*MergeTree) + <name> (Distributed, same sharding key)
--   [ ] ORDER BY starts with the most selective filter column; PARTITION BY is daily or monthly, never finer
--   [ ] TTL and storage_policy set ('tiered', or 'tiered_regulated' for PII/PCI/PHI)
--   [ ] No PII columns outside the pii database
--   [ ] Grants/row policies for new tables added in clickhouse/access/ (both <name> and <name>_local)

CREATE TABLE IF NOT EXISTS db.table_local ON CLUSTER '{cluster}'
(
  event_time  DateTime64(3) CODEC(Delta, ZSTD(1)),
  customer_id UInt64
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (customer_id, event_time)
TTL toDateTime(event_time) + INTERVAL 30 DAY TO VOLUME 'warm',
    toDateTime(event_time) + INTERVAL 90 DAY TO VOLUME 'cold'
SETTINGS storage_policy = 'tiered';

CREATE TABLE IF NOT EXISTS db.table ON CLUSTER '{cluster}' AS db.table_local
ENGINE = Distributed('{cluster}', db, table_local, cityHash64(customer_id));
EOF
echo "created ${file#"$(pwd)/"}"
