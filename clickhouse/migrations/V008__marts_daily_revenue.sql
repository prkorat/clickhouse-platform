-- Example mart for dashboards and APIs: daily revenue per country and event type.
-- Incrementally maintained by a materialized view; dashboards never scan the raw fact.

CREATE TABLE IF NOT EXISTS marts.daily_revenue_local ON CLUSTER '{cluster}'
(
  day         Date,
  country     LowCardinality(String),
  event_type  LowCardinality(String),
  events      UInt64,
  revenue     Decimal(38, 4),
  customers   AggregateFunction(uniq, UInt64)
)
ENGINE = ReplicatedAggregatingMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
PARTITION BY toYYYYMM(day)
ORDER BY (day, country, event_type)
TTL day + INTERVAL 730 DAY DELETE;

CREATE TABLE IF NOT EXISTS marts.daily_revenue ON CLUSTER '{cluster}' AS marts.daily_revenue_local
ENGINE = Distributed('{cluster}', marts, daily_revenue_local, rand());

CREATE MATERIALIZED VIEW IF NOT EXISTS marts.mv_daily_revenue ON CLUSTER '{cluster}'
TO marts.daily_revenue_local AS
SELECT
  toDate(event_time)  AS day,
  country,
  event_type,
  count()             AS events,
  sum(amount)         AS revenue,
  uniqState(customer_id) AS customers
FROM analytics.events_local
GROUP BY day, country, event_type;

-- Query pattern for consumers (merge partial aggregates):
--   SELECT day, country, sum(events), sum(revenue), uniqMerge(customers)
--   FROM marts.daily_revenue GROUP BY day, country;
