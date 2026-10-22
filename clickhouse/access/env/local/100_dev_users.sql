-- LOCAL DOCKER CLUSTER ONLY. Never applied to staging or prod (scripts/apply-access.sh picks env/<ENV>/).
-- Roles are granted below; new users default to DEFAULT ROLE ALL, so granted roles are active at login.
-- One user per role so developers can test grants, row policies and quotas the way production enforces them.

CREATE USER IF NOT EXISTS dev_engineer IDENTIFIED WITH sha256_password BY 'dev';
CREATE USER IF NOT EXISTS dev_etl      IDENTIFIED WITH sha256_password BY 'dev';
CREATE USER IF NOT EXISTS dev_analyst  IDENTIFIED WITH sha256_password BY 'dev';
CREATE USER IF NOT EXISTS dev_api      IDENTIFIED WITH sha256_password BY 'dev';
CREATE USER IF NOT EXISTS dev_auditor  IDENTIFIED WITH sha256_password BY 'dev';

GRANT role_data_engineer   TO dev_engineer;
GRANT role_etl_service     TO dev_etl;
GRANT role_bi_analyst      TO dev_analyst;
GRANT role_api_service     TO dev_api;
GRANT role_security_auditor TO dev_auditor;
