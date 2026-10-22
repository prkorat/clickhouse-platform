-- BI-facing fact. Same rows as analytics.events without the free-form payload (which may hold PII).
-- Protected by the tenant_scope row policy and column grants (clickhouse/access/060, 020).

CREATE TABLE IF NOT EXISTS curated.events_local ON CLUSTER '{cluster}'
(
  event_time   DateTime64(3) CODEC(Delta, ZSTD(1)),
  customer_id  UInt64,
  event_type   LowCardinality(String),
  event_id     UUID,
  amount       Decimal(18, 4) CODEC(ZSTD(1)),
  country      LowCardinality(String)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (customer_id, event_type, event_time)
TTL toDateTime(event_time) + INTERVAL 30 DAY TO VOLUME 'warm',
    toDateTime(event_time) + INTERVAL 90 DAY TO VOLUME 'cold',
    toDateTime(event_time) + INTERVAL 730 DAY DELETE
SETTINGS storage_policy = 'tiered', ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS curated.events ON CLUSTER '{cluster}' AS curated.events_local
ENGINE = Distributed('{cluster}', curated, events_local, cityHash64(customer_id));

CREATE MATERIALIZED VIEW IF NOT EXISTS curated.mv_events_from_analytics ON CLUSTER '{cluster}'
TO curated.events_local AS
SELECT event_time, customer_id, event_type, event_id, amount, country
FROM analytics.events_local;
