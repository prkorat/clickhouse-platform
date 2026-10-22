-- The one PII table (design doc Section 4.7). Facts carry only the pseudonymous customer_id,
-- so GDPR erasure is a delete here, not a rewrite of petabytes of facts.
-- Regulated cold tier: client-side encrypted on top of SSE-KMS (storage policy tiered_regulated).

CREATE TABLE IF NOT EXISTS pii.customers_local ON CLUSTER '{cluster}'
(
  customer_id   UInt64,
  email         String,
  phone         String,
  full_name     String,
  date_of_birth Date,
  country       LowCardinality(String),
  ip_address    String TTL updated_at + INTERVAL 90 DAY,   -- detail not needed after 90 days
  updated_at    DateTime DEFAULT now()
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}', updated_at)
ORDER BY customer_id
SETTINGS storage_policy = 'tiered_regulated';

CREATE TABLE IF NOT EXISTS pii.customers ON CLUSTER '{cluster}' AS pii.customers_local
ENGINE = Distributed('{cluster}', pii, customers_local, cityHash64(customer_id));
