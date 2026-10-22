-- Row-level security (design doc Section 4.7).
-- The cluster runs default-deny (users_without_row_policies_can_read_rows = false), so every table
-- that has a restrictive policy also needs an explicit allow_all policy for engineering roles.
-- Distributed queries run the remote part as the initial user (cluster <secret>), so the policy
-- must exist on both the Distributed table and its *_local table.

-- Tenant scoping via a dictionary (fast; no subquery per query). Dictionary is created in V002.
CREATE ROW POLICY OR REPLACE tenant_scope ON curated.events FOR SELECT
  USING has(dictGet('governance.user_tenants_dict', 'customer_ids', currentUser()), customer_id)
  TO role_bi_analyst, role_support;
CREATE ROW POLICY OR REPLACE tenant_scope ON curated.events_local FOR SELECT
  USING has(dictGet('governance.user_tenants_dict', 'customer_ids', currentUser()), customer_id)
  TO role_bi_analyst, role_support;

-- Required companion under default-deny: without it, engineers and ETL see zero rows.
CREATE ROW POLICY OR REPLACE allow_all ON curated.events FOR SELECT USING 1
  TO role_data_engineer, role_etl_service, role_dba;
CREATE ROW POLICY OR REPLACE allow_all ON curated.events_local FOR SELECT USING 1
  TO role_data_engineer, role_etl_service, role_dba;
