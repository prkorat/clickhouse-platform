-- Governance tables (design doc Sections 4.7 and 7.3). Small, replicated to every node (not sharded).

-- Tenant mapping used by the tenant_scope row policy. One row per user (LDAP user name).
CREATE TABLE IF NOT EXISTS governance.user_tenants ON CLUSTER '{cluster}'
(
  user_name    String,
  customer_ids Array(UInt64),
  updated_at   DateTime DEFAULT now()
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/all/{database}/{table}', '{replica}', updated_at)
ORDER BY user_name;

CREATE DICTIONARY IF NOT EXISTS governance.user_tenants_dict ON CLUSTER '{cluster}'
(
  user_name    String,
  customer_ids Array(UInt64)
)
PRIMARY KEY user_name
-- Local source authenticates as svc_dict_reader (no_password, HOST LOCAL, SELECT on this one table only;
-- see clickhouse/access/070_definer_users.sql). Without USER it would use 'default', which is disabled.
SOURCE(CLICKHOUSE(USER 'svc_dict_reader' QUERY 'SELECT user_name, customer_ids FROM governance.user_tenants FINAL'))
LIFETIME(MIN 60 MAX 120)
LAYOUT(COMPLEX_KEY_HASHED());

-- GDPR Art. 17 erasure workflow. status: pending -> approved -> done.
CREATE TABLE IF NOT EXISTS governance.erasure_requests ON CLUSTER '{cluster}'
(
  ticket_id    String,
  customer_id  UInt64,
  status       LowCardinality(String),
  requested_at DateTime,
  updated_at   DateTime DEFAULT now()
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/all/{database}/{table}', '{replica}', updated_at)
ORDER BY (customer_id, ticket_id);

-- Re-applied after every restore so erased subjects never come back from a backup.
CREATE TABLE IF NOT EXISTS governance.suppression_list ON CLUSTER '{cluster}'
(
  customer_id UInt64,
  erased_at   DateTime,
  ticket_id   String
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/all/{database}/{table}', '{replica}', erased_at)
ORDER BY customer_id;

-- One row per backup run: where it is and which Kafka offsets it covers (replay start point).
CREATE TABLE IF NOT EXISTS governance.backup_catalog ON CLUSTER '{cluster}'
(
  backup_id      String,
  backup_url     String,
  backup_kind    LowCardinality(String),   -- full | incremental
  base_backup    String,
  started_at     DateTime,
  finished_at    Nullable(DateTime),
  status         LowCardinality(String),
  kafka_offsets  Map(String, UInt64),       -- 'topic:partition' -> offset at backup start
  row_counts     Map(String, UInt64)        -- 'db.table' -> rows
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/all/{database}/{table}', '{replica}')
ORDER BY started_at;
