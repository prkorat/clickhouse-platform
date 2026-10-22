# Identity-based micro-segmentation (design doc Section 4.1): one SG per role, rules reference SGs, never CIDRs.
# Port matrix:
#   8443  HTTPS            proxy, kafka-connect      -> data
#   9440  native TLS       proxy, kafka-connect, data -> data
#   9010  interserver TLS  data                       -> data
#   9281  Keeper TLS       data                       -> keeper
#   9234  Keeper Raft TLS  keeper                     -> keeper
#   9363  Prometheus       prometheus                 -> data, keeper
# Plaintext 8123/9000/9009/9181 and MySQL/PostgreSQL 9004/9005 are not opened anywhere. No port 22.

locals {
  roles = ["ch_data", "ch_keeper", "ch_proxy", "kafka_connect", "prometheus"]

  ingress = {
    data_https_from_proxy    = { sg = "ch_data", src = "ch_proxy", port = 8443, desc = "HTTPS from chproxy" }
    data_https_from_connect  = { sg = "ch_data", src = "kafka_connect", port = 8443, desc = "HTTPS from Kafka Connect" }
    data_native_from_proxy   = { sg = "ch_data", src = "ch_proxy", port = 9440, desc = "Native TLS from chproxy" }
    data_native_from_connect = { sg = "ch_data", src = "kafka_connect", port = 9440, desc = "Native TLS from Kafka Connect" }
    data_native_from_data    = { sg = "ch_data", src = "ch_data", port = 9440, desc = "Distributed queries between shards" }
    data_interserver         = { sg = "ch_data", src = "ch_data", port = 9010, desc = "Replica fetch over HTTPS" }
    data_metrics             = { sg = "ch_data", src = "prometheus", port = 9363, desc = "Prometheus scrape" }
    keeper_client            = { sg = "ch_keeper", src = "ch_data", port = 9281, desc = "Keeper client TLS from data nodes" }
    keeper_raft              = { sg = "ch_keeper", src = "ch_keeper", port = 9234, desc = "Keeper Raft over TLS" }
    keeper_metrics           = { sg = "ch_keeper", src = "prometheus", port = 9363, desc = "Prometheus scrape" }
  }
}

resource "aws_security_group" "this" {
  for_each    = toset(local.roles)
  name        = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  description = "ClickHouse platform: ${each.key}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Role = each.key })

  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each                     = local.ingress
  security_group_id            = aws_security_group.this[each.value.sg].id
  referenced_security_group_id = aws_security_group.this[each.value.src].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.value.desc
  tags                         = var.tags
}

# chproxy accepts client traffic only from the PrivateLink NLB / VPN subnet (prefix list, not 0.0.0.0/0).
resource "aws_vpc_security_group_ingress_rule" "proxy_from_clients" {
  for_each          = toset(["8443", "9440"])
  security_group_id = aws_security_group.this["ch_proxy"].id
  prefix_list_id    = var.client_prefix_list_id
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  description       = "Clients via PrivateLink / VPN"
  tags              = var.tags
}

# Egress: inside the VPC only; internet egress is via Network Firewall allowlist + VPC endpoints.
resource "aws_vpc_security_group_egress_rule" "vpc_only" {
  for_each          = toset(local.roles)
  security_group_id = aws_security_group.this[each.key].id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
  description       = "Intra-VPC only"
  tags              = var.tags
}

resource "aws_vpc_security_group_egress_rule" "s3_endpoint" {
  for_each          = toset(["ch_data"])
  security_group_id = aws_security_group.this[each.key].id
  prefix_list_id    = var.s3_prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "S3 gateway endpoint (cold tier, backups)"
  tags              = var.tags
}
