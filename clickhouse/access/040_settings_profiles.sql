-- Settings profiles with constraints users cannot raise (design doc Section 4.8).
--
-- | Setting                          | ETL     | BI          | Power   | Service |
-- | max_memory_usage                 | 40 GB   | 10 (max 20) | 50 GB   | 4 GB    |
-- | max_threads                      | 8       | 16          | 32      | 4       |
-- | max_execution_time               | 3600 s  | 300 s       | 1800 s  | 30 s    |
-- | max_partitions_per_insert_block  | 100     | read-only   | 100     | 10      |

CREATE SETTINGS PROFILE OR REPLACE profile_bi SETTINGS
  max_memory_usage = 10000000000 MAX 20000000000,
  max_threads = 16 MAX 16,
  max_execution_time = 300 MAX 300,
  max_result_rows = 1000000, result_overflow_mode = 'throw',
  max_rows_to_read = 50000000000,
  max_concurrent_queries_for_user = 30,
  readonly = 2,                       -- may set session settings, never write
  workload = 'bi' CONST
TO role_bi_analyst, role_support, role_readonly;

CREATE SETTINGS PROFILE OR REPLACE profile_etl SETTINGS
  max_memory_usage = 40000000000 MAX 60000000000,
  max_threads = 8,
  max_insert_threads = 4,
  max_execution_time = 3600,
  max_partitions_per_insert_block = 100 CONST,
  max_concurrent_queries_for_user = 20,
  workload = 'ingest' CONST
TO role_etl_service;

CREATE SETTINGS PROFILE OR REPLACE profile_power SETTINGS
  max_memory_usage = 50000000000 MAX 50000000000,
  max_threads = 32, max_execution_time = 1800,
  max_result_rows = 10000000, result_overflow_mode = 'throw',
  max_partitions_per_insert_block = 100,
  max_concurrent_queries_for_user = 10,
  workload = 'adhoc' CONST
TO role_data_engineer, role_platform_engineer;

CREATE SETTINGS PROFILE OR REPLACE profile_service SETTINGS
  max_memory_usage = 4000000000 MAX 4000000000,
  max_threads = 4, max_execution_time = 30 MAX 30,
  max_result_rows = 100000, result_overflow_mode = 'throw',
  max_partitions_per_insert_block = 10 CONST,
  max_concurrent_queries_for_user = 50,
  readonly = 1,                       -- APIs never write or change settings
  workload = 'api' CONST
TO role_api_service;
