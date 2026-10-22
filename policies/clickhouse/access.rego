# Access-model guardrails for ClickHouse XML config (design doc Section 4.3 / 4.7).
package main

import rego.v1

required_access_improvements := {
	"users_without_row_policies_can_read_rows": "false",
	"select_from_system_db_requires_grant": "true",
	"select_from_information_schema_requires_grant": "true",
	"on_cluster_queries_require_cluster_grant": "true",
}

deny contains msg if {
	aci := input.clickhouse.access_control_improvements
	some key, want in required_access_improvements
	object.get(aci, key, "<unset>") != want
	msg := sprintf("access_control_improvements.%s must be %s", [key, want])
}

# LDAP must use TLS and verify the directory's certificate.
deny contains msg if {
	some name, server in input.clickhouse.ldap_servers
	server.enable_tls != "yes"
	msg := sprintf("ldap_servers.%s.enable_tls must be yes (LDAPS)", [name])
}

deny contains msg if {
	some name, server in input.clickhouse.ldap_servers
	server.tls_require_cert != "demand"
	msg := sprintf("ldap_servers.%s.tls_require_cert must be demand", [name])
}

# No plaintext passwords for XML users (the 'default' user carries an unknowable hash only).
deny contains msg if {
	some name, user in input.clickhouse.users
	is_string(user.password)
	msg := sprintf("users.%s has a plaintext <password>; use SQL users with mTLS or LDAP", [name])
}
