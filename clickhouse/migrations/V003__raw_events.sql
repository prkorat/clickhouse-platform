-- Landing table for the Kafka Connect sink (exactly-once). Short retention: raw is replayable from Kafka
-- (7 days) and from the S3 landing bucket. Hot tier only.

CREATE TABLE IF NOT EXISTS raw.events_local ON CLUSTER '{cluster}'
(
  event_time   DateTime64(3) CODEC(Delta, ZSTD(1)),
  customer_id  UInt64,
  event_type   LowCardinality(String),
  event_id     UUID,
  amount       Decimal(18, 4) CODEC(ZSTD(1)),
  country      LowCardinality(String),
  payload      String CODEC(ZSTD(3)),
  _topic       LowCardinality(String),
  _partition   UInt32,
  _offset      UInt64,
  _ingested_at DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (customer_id, event_type, event_time)
TTL toDateTime(event_time) + INTERVAL 14 DAY DELETE
SETTINGS storage_policy = 'tiered', ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS raw.events ON CLUSTER '{cluster}' AS raw.events_local
ENGINE = Distributed('{cluster}', raw, events_local, cityHash64(customer_id));
