-- Conformed event fact (design doc Section 5.5): tiered storage with TTL moves and a final delete.
-- 30 days hot (NVMe) -> 90 days warm (gp3) -> 2 years cold (S3), then dropped by whole parts.

CREATE TABLE IF NOT EXISTS analytics.events_local ON CLUSTER '{cluster}'
(
  event_time   DateTime64(3) CODEC(Delta, ZSTD(1)),
  customer_id  UInt64,
  event_type   LowCardinality(String),
  event_id     UUID,
  amount       Decimal(18, 4) CODEC(ZSTD(1)),
  country      LowCardinality(String),
  payload      String CODEC(ZSTD(3))
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (customer_id, event_type, event_time)
TTL toDateTime(event_time) + INTERVAL 30 DAY TO VOLUME 'warm',
    toDateTime(event_time) + INTERVAL 90 DAY TO VOLUME 'cold',
    toDateTime(event_time) + INTERVAL 730 DAY DELETE
SETTINGS storage_policy = 'tiered', ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS analytics.events ON CLUSTER '{cluster}' AS analytics.events_local
ENGINE = Distributed('{cluster}', analytics, events_local, cityHash64(customer_id));

-- raw -> analytics. Runs on each shard against its local raw part; same sharding key, so rows stay local.
CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_events_from_raw ON CLUSTER '{cluster}'
TO analytics.events_local AS
SELECT event_time, customer_id, event_type, event_id, amount, country, payload
FROM raw.events_local;
