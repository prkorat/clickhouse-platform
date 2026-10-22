-- Quotas, tracked per user, enforced per hour and per day (design doc Section 4.8).

CREATE QUOTA OR REPLACE quota_bi KEYED BY user_name
  FOR INTERVAL 1 hour MAX queries = 2000, errors = 200, result_rows = 100000000, read_bytes = 5000000000000,
  FOR INTERVAL 1 day  MAX execution_time = 86400
  TO role_bi_analyst;

CREATE QUOTA OR REPLACE quota_etl KEYED BY user_name
  FOR INTERVAL 1 hour MAX queries = 50000, errors = 1000
  TO role_etl_service;

CREATE QUOTA OR REPLACE quota_power KEYED BY user_name
  FOR INTERVAL 1 hour MAX queries = 500, read_bytes = 20000000000000
  TO role_data_engineer, role_platform_engineer;

CREATE QUOTA OR REPLACE quota_service KEYED BY user_name
  FOR INTERVAL 1 minute MAX queries = 3000, errors = 300
  TO role_api_service;

-- Applied by the region-failover runbook (runbooks/region-failover.md) when DR runs one replica per shard.
CREATE QUOTA OR REPLACE quota_bi_degraded KEYED BY user_name
  FOR INTERVAL 1 hour MAX queries = 500, result_rows = 20000000, read_bytes = 1000000000000;
