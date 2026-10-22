package main

import rego.v1

good_tls := {"clickhouse": {
	"tcp_port": {"-remove": "1"},
	"http_port": {"-remove": "1"},
	"openSSL": {
		"server": {"verificationMode": "strict", "disableProtocols": "sslv2,sslv3,tlsv1,tlsv1_1", "loadDefaultCAFile": "false"},
		"client": {"verificationMode": "strict", "disableProtocols": "sslv2,sslv3,tlsv1,tlsv1_1", "loadDefaultCAFile": "false"},
	},
	"interserver_http_credentials": {"user": "interserver", "password": {"-from_env": "CH_INTERSERVER_PASSWORD"}},
}}

test_good_config_passes if {
	count(deny) == 0 with input as good_tls
}

test_plaintext_tcp_port_denied if {
	some msg in deny with input as {"clickhouse": {"tcp_port": "9000"}}
	contains(msg, "tcp_port")
}

test_relaxed_verification_denied if {
	some msg in deny with input as {"clickhouse": {"openSSL": {"server": {
		"verificationMode": "relaxed", "disableProtocols": "sslv2,sslv3,tlsv1,tlsv1_1", "loadDefaultCAFile": "false",
	}}}}
	contains(msg, "strict")
}

test_literal_interserver_password_denied if {
	some msg in deny with input as {"clickhouse": {"interserver_http_credentials": {"password": "hunter2"}}}
	contains(msg, "from_env")
}

test_row_policy_default_allow_denied if {
	some msg in deny with input as {"clickhouse": {"access_control_improvements": {
		"users_without_row_policies_can_read_rows": "true",
		"select_from_system_db_requires_grant": "true",
		"select_from_information_schema_requires_grant": "true",
		"on_cluster_queries_require_cluster_grant": "true",
	}}}
	contains(msg, "users_without_row_policies_can_read_rows")
}
