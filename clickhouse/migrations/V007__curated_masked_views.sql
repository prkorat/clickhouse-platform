-- Masking for self-managed ClickHouse: a DEFINER view owned by a non-login user that can read PII,
-- granted to BI (design doc Section 4.7). CREATE MASKING POLICY is ClickHouse Cloud only.
-- svc_view_owner is created by clickhouse/access/070_definer_users.sql (apply access before migrations).

CREATE OR REPLACE VIEW curated.v_customers_masked ON CLUSTER '{cluster}'
  DEFINER = svc_view_owner SQL SECURITY DEFINER AS
SELECT
  customer_id,
  concat(substring(email, 1, 2), '***@', splitByChar('@', email)[2]) AS email_masked,
  concat('***-***-', right(phone, 4))                                 AS phone_masked,
  country,
  toStartOfMonth(date_of_birth)                                      AS birth_month
FROM pii.customers;
