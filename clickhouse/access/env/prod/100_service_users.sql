-- Production service users (design doc Section 5.4). Humans come from LDAP; only these are defined in SQL.
-- Services authenticate with short-lived mTLS client certificates from Vault PKI (CN = user name).
-- The break-glass password hash is applied out of band from Vault (two-person retrieval), never from Git.

CREATE USER IF NOT EXISTS svc_kafka_connect IDENTIFIED WITH ssl_certificate CN 'svc_kafka_connect'
  HOST IP '10.40.48.0/22';
CREATE USER IF NOT EXISTS svc_airflow IDENTIFIED WITH ssl_certificate CN 'svc_airflow'
  HOST IP '10.40.52.0/24';
CREATE USER IF NOT EXISTS svc_orders_api IDENTIFIED WITH ssl_certificate CN 'svc_orders_api'
  HOST IP '10.20.0.0/16';
CREATE USER IF NOT EXISTS svc_audit_export IDENTIFIED WITH ssl_certificate CN 'svc_audit_export'
  HOST IP '10.40.56.0/24';
CREATE USER IF NOT EXISTS svc_ci_deployer IDENTIFIED WITH ssl_certificate CN 'svc_ci_deployer'
  HOST IP '10.40.56.0/24';

GRANT role_etl_service TO svc_kafka_connect, svc_airflow;
GRANT role_api_service TO svc_orders_api;
GRANT SELECT ON system.query_log TO svc_audit_export;
GRANT SELECT ON system.session_log TO svc_audit_export;
GRANT SELECT ON system.part_log TO svc_audit_export;
GRANT S3, REMOTE ON *.* TO svc_audit_export;      -- writes only to the audit bucket (S3 endpoint policy)
GRANT ACCESS MANAGEMENT, CREATE, ALTER, DROP, CLUSTER ON *.* TO svc_ci_deployer;  -- only via reviewed pipeline

-- On-node operations identity used by Ansible playbooks (drain, version and replica checks, SYSTEM STOP MERGES).
-- Client certificate rendered by Vault Agent on every data node; HOST LOCAL means it only works on the node itself.
CREATE USER IF NOT EXISTS svc_node_ops IDENTIFIED WITH ssl_certificate CN 'svc_node_ops' HOST LOCAL;
GRANT SELECT ON system.* TO svc_node_ops;
GRANT SYSTEM MERGES, SYSTEM SYNC REPLICA, SYSTEM DROP REPLICA, SYSTEM RELOAD CONFIG, SYSTEM FLUSH LOGS ON *.* TO svc_node_ops;
