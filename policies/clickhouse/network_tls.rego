# Conftest policy for ClickHouse XML config (design doc Section 6.2 / 6.3).
#   conftest test --parser xml -p policies/clickhouse clickhouse/config.d
# Each file is evaluated on its own, so every rule only fires when the element is present.
package main

import rego.v1

plaintext_ports := ["http_port", "tcp_port", "mysql_port", "postgresql_port", "interserver_http_port"]

# A plaintext port is allowed only as <x_port remove="1"/>.
deny contains msg if {
	some port in plaintext_ports
	value := input.clickhouse[port]
	not removed(value)
	msg := sprintf("plaintext port <%s> must be removed (<%s remove=\"1\"/>), found %v", [port, port, value])
}

removed(value) if value["-remove"] == "1"

# Mutual TLS: the server must demand client certificates.
deny contains msg if {
	mode := input.clickhouse.openSSL.server.verificationMode
	mode != "strict"
	msg := sprintf("openSSL.server.verificationMode must be strict (mutual TLS), found %v", [mode])
}

deny contains msg if {
	input.clickhouse.openSSL.server
	not input.clickhouse.openSSL.server.verificationMode
	msg := "openSSL.server.verificationMode must be set to strict"
}

# No TLS 1.0 / 1.1.
deny contains msg if {
	some side in ["server", "client"]
	cfg := input.clickhouse.openSSL[side]
	not contains(object.get(cfg, "disableProtocols", ""), "tlsv1_1")
	msg := sprintf("openSSL.%s.disableProtocols must include sslv2,sslv3,tlsv1,tlsv1_1", [side])
}

# Peers must be verified against the private CA only, not the OS trust store.
deny contains msg if {
	some side in ["server", "client"]
	cfg := input.clickhouse.openSSL[side]
	object.get(cfg, "loadDefaultCAFile", "true") != "false"
	msg := sprintf("openSSL.%s.loadDefaultCAFile must be false (trust only the platform CA)", [side])
}

# Interserver credentials must come from the environment, never a literal.
deny contains msg if {
	pw := input.clickhouse.interserver_http_credentials.password
	not pw["-from_env"]
	msg := "interserver_http_credentials.password must use from_env, not a literal"
}
