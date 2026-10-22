-- Non-login / local-only identities used by the engine itself (design doc Section 4.7).

-- Owns SQL SECURITY DEFINER views. HOST NONE: can never authenticate.
CREATE USER IF NOT EXISTS svc_view_owner IDENTIFIED WITH no_password HOST NONE;
GRANT SELECT ON pii.customers TO svc_view_owner;
GRANT SELECT ON pii.customers_local TO svc_view_owner;   -- shard-side read of the Distributed table

-- Source user for governance.user_tenants_dict (row-policy tenant lookup). Loopback only;
-- reads exactly one table. ClickHouse local dictionary sources authenticate as a named user.
CREATE USER IF NOT EXISTS svc_dict_reader IDENTIFIED WITH no_password HOST LOCAL;
GRANT SELECT ON governance.user_tenants TO svc_dict_reader;
