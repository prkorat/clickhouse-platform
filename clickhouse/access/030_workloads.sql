-- Workload scheduler (design doc Section 4.8): CPU shared by weight, ad-hoc work capped.
-- Definitions replicate through Keeper (workload_zookeeper_path in config.d/50-limits.xml).
-- To change a weight: use CREATE OR REPLACE WORKLOAD for that one leaf in a new statement below.

CREATE RESOURCE IF NOT EXISTS cpu (MASTER THREAD, WORKER THREAD);
CREATE WORKLOAD IF NOT EXISTS all SETTINGS max_concurrent_threads_ratio_to_cores = 2;
CREATE WORKLOAD IF NOT EXISTS ingest IN all SETTINGS weight = 5;
CREATE WORKLOAD IF NOT EXISTS bi     IN all SETTINGS weight = 3;
CREATE WORKLOAD IF NOT EXISTS api    IN all SETTINGS weight = 3;
CREATE WORKLOAD IF NOT EXISTS adhoc  IN all SETTINGS weight = 1, max_cpu_share = 0.3;
