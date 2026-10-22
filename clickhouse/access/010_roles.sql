-- Roles (design doc Section 4.3). Replicated access storage propagates these to
-- every node, so no ON CLUSTER is needed. Idempotent: safe to re-apply on every deploy.
-- Human users get roles through LDAP group mapping: AD group CH-Prod-<role> -> <role>.

CREATE ROLE IF NOT EXISTS role_admin;              -- break-glass only
CREATE ROLE IF NOT EXISTS role_dba;                -- operate the engine
CREATE ROLE IF NOT EXISTS role_platform_engineer;  -- observe and reload, no table data
CREATE ROLE IF NOT EXISTS role_data_engineer;      -- build in staging/analytics
CREATE ROLE IF NOT EXISTS role_etl_service;        -- ingestion write paths
CREATE ROLE IF NOT EXISTS role_api_service;        -- application read paths
CREATE ROLE IF NOT EXISTS role_bi_analyst;         -- marts and masked views
CREATE ROLE IF NOT EXISTS role_readonly;           -- marts only
CREATE ROLE IF NOT EXISTS role_support;            -- tenant-scoped support views
CREATE ROLE IF NOT EXISTS role_security_auditor;   -- access model and audit logs
CREATE ROLE IF NOT EXISTS role_pii_reader;         -- per approved ticket, time-boxed
