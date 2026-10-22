-- Grants per role (design doc Section 4.3 / 5.4). Least privilege; no WITH GRANT OPTION below admin.
-- Grants on objects that do not exist yet are allowed, so this file can run before migrations.
-- Removing a line here does NOT revoke it: add an explicit REVOKE in 090_revokes.sql
-- (the nightly drift job diffs SHOW ACCESS against Git and reports leftovers).

-- Distributed tables: grant on both <table> and <table>_local, because the shard-side query
-- runs as the initial user.

-- Admin (break-glass only)
GRANT ALL ON *.* TO role_admin WITH GRANT OPTION;

-- DBA: operate the engine, not the access model, not PII
GRANT SYSTEM MERGES, SYSTEM TTL MERGES, SYSTEM MOVES, SYSTEM FETCHES, SYSTEM SENDS,
      SYSTEM REPLICATION QUEUES, SYSTEM SYNC REPLICA, SYSTEM RESTART REPLICA,
      SYSTEM FLUSH LOGS, SYSTEM RELOAD CONFIG, SYSTEM DROP CACHE, KILL QUERY, CLUSTER ON *.* TO role_dba;
GRANT CREATE TABLE, ALTER, DROP TABLE, OPTIMIZE, TRUNCATE ON analytics.* TO role_dba;
GRANT CREATE TABLE, ALTER, DROP TABLE, OPTIMIZE ON staging.* TO role_dba;
GRANT SELECT ON system.* TO role_dba;

-- Platform engineer: observe and reload, no table data
GRANT SELECT ON system.* TO role_platform_engineer;
GRANT SYSTEM FLUSH LOGS, SYSTEM RELOAD CONFIG, SHOW TABLES, SHOW DATABASES ON *.* TO role_platform_engineer;

-- Data engineer: build in staging and analytics; read curated non-PII
GRANT CREATE TABLE, CREATE VIEW, ALTER, DROP TABLE, DROP VIEW, INSERT, SELECT, OPTIMIZE ON staging.* TO role_data_engineer;
GRANT CREATE TABLE, CREATE VIEW, ALTER, INSERT, SELECT ON analytics.* TO role_data_engineer;
GRANT SELECT ON curated.* TO role_data_engineer;
GRANT CREATE TEMPORARY TABLE ON *.* TO role_data_engineer;

-- ETL service: write paths only; S3 reads only through a named collection
GRANT INSERT ON raw.* TO role_etl_service;
GRANT SELECT, INSERT ON staging.* TO role_etl_service;
GRANT SELECT, INSERT, ALTER UPDATE, ALTER DELETE ON analytics.* TO role_etl_service;
GRANT CREATE TEMPORARY TABLE, S3 ON *.* TO role_etl_service;
GRANT NAMED COLLECTION ON s3_landing TO role_etl_service;

-- API service: curated marts only; no table functions (SQL-injection blast radius, Section 4.10)
GRANT SELECT ON marts.* TO role_api_service;

-- BI analyst: marts and masked views only; named columns on curated facts
GRANT SELECT ON marts.* TO role_bi_analyst;
GRANT dictGet ON governance.user_tenants_dict TO role_bi_analyst, role_support;  -- row policy lookup
GRANT SELECT(event_id, event_time, customer_id, event_type, amount, country) ON curated.events TO role_bi_analyst;
GRANT SELECT(event_id, event_time, customer_id, event_type, amount, country) ON curated.events_local TO role_bi_analyst;
GRANT SELECT ON curated.v_customers_masked TO role_bi_analyst;

-- Read-only
GRANT SELECT ON marts.* TO role_readonly;

-- Support: tenant-scoped views
GRANT SELECT ON support.* TO role_support;

-- Security auditor: access model and audit logs, no business data
GRANT SELECT ON system.query_log TO role_security_auditor;
GRANT SELECT ON system.session_log TO role_security_auditor;
GRANT SELECT ON system.users TO role_security_auditor;
GRANT SELECT ON system.roles TO role_security_auditor;
GRANT SELECT ON system.grants TO role_security_auditor;
GRANT SELECT ON system.role_grants TO role_security_auditor;
GRANT SELECT ON system.row_policies TO role_security_auditor;
GRANT SELECT ON system.quotas TO role_security_auditor;
GRANT SELECT ON system.settings_profiles TO role_security_auditor;
GRANT SHOW USERS, SHOW ROLES, SHOW ROW POLICIES, SHOW QUOTAS, SHOW SETTINGS PROFILES ON *.* TO role_security_auditor;

-- PII reader (granted to a person per approved ticket, revoked by expiry job)
GRANT SELECT ON pii.* TO role_pii_reader;
