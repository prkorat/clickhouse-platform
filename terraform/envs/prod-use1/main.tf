# Production, us-east-1: 12 shards x 2 replicas (24 x i4i.16xlarge) + 3 Keeper (m7i.2xlarge), 3 AZs.
# Design doc Sections 3.1-3.3. The VPC, subnets, TGW, endpoints and Network Firewall come from the
# shared networking stack; their ids are inputs here (terraform.tfvars).

locals {
  name_prefix = "ch-${var.environment}-${var.region_short}"
  azs         = ["${var.region}a", "${var.region}b", "${var.region}c"]

  # Replica r1 and r2 of a shard always sit in different AZs; shards rotate across AZs.
  data_nodes = merge([
    for s in range(1, var.shard_count + 1) : {
      for r in range(1, var.replicas_per_shard + 1) :
      format("ch-s%02d-r%d", s, r) => {
        az      = local.azs[(s + r) % 3]
        shard   = format("%02d", s)
        replica = "r${r}"
      }
    }
  ]...)

  keeper_nodes = { for i in range(1, 4) : "keeper-${i}" => { az = local.azs[i - 1] } }

  tags = {
    Environment = var.environment
    Service     = "clickhouse"
    Owner       = "data-platform"
    DataClass   = "confidential"
    ManagedBy   = "terraform"
  }
}

module "security_groups" {
  source                = "../../modules/security_groups"
  name_prefix           = local.name_prefix
  vpc_id                = var.vpc_id
  vpc_cidr              = var.vpc_cidr
  client_prefix_list_id = var.client_prefix_list_id
  s3_prefix_list_id     = var.s3_prefix_list_id
  tags                  = local.tags
}

module "kms" {
  source              = "../../modules/kms"
  name_prefix         = local.name_prefix
  key_admin_role_arns = var.key_admin_role_arns
  key_user_role_arns = {
    ebs       = [module.clickhouse.role_arn, module.keeper.role_arn, var.autoscaling_service_role_arn]
    "s3-cold" = [module.clickhouse.role_arn, var.backup_role_arn]
    secrets   = [module.clickhouse.role_arn, module.keeper.role_arn]
  }
  tags = local.tags
}

module "cold_tier" {
  source            = "../../modules/s3_tiers"
  bucket_name       = "${local.name_prefix}-cold"
  kms_key_arn       = module.kms.key_arns["s3-cold"]
  allowed_role_arns = [module.clickhouse.role_arn, var.backup_role_arn]
  tags              = local.tags
}

module "clickhouse" {
  source                 = "../../modules/clickhouse_nodes"
  name_prefix            = local.name_prefix
  role                   = "clickhouse"
  nodes                  = local.data_nodes
  instance_type          = var.data_instance_type
  ami_id                 = var.ami_id
  subnet_ids_by_az       = var.data_subnet_ids_by_az
  security_group_ids     = [module.security_groups.ids["ch_data"]]
  ebs_kms_key_arn        = var.bootstrap_ebs_kms_key_arn
  kms_key_arns           = var.node_kms_key_arns
  secret_arns            = var.clickhouse_secret_arns
  cold_bucket_arn        = "arn:aws:s3:::${local.name_prefix}-cold"
  backup_bucket_arn      = var.backup_bucket_arn
  data_volume_count      = 4
  data_volume_size_gb    = 5000 # 4 x 5 TB gp3 warm tier per node (RAID 0)
  data_volume_iops       = 6000
  data_volume_throughput = 500
  dns_zone_id            = var.dns_zone_id
  dns_zone_name          = var.dns_zone_name
  tags                   = local.tags
}

module "keeper" {
  source                 = "../../modules/clickhouse_nodes"
  name_prefix            = local.name_prefix
  role                   = "keeper"
  nodes                  = local.keeper_nodes
  instance_type          = var.keeper_instance_type
  ami_id                 = var.ami_id
  subnet_ids_by_az       = var.keeper_subnet_ids_by_az
  security_group_ids     = [module.security_groups.ids["ch_keeper"]]
  ebs_kms_key_arn        = var.bootstrap_ebs_kms_key_arn
  kms_key_arns           = var.node_kms_key_arns
  secret_arns            = var.keeper_secret_arns
  data_volume_count      = 1
  data_volume_size_gb    = 500
  data_volume_iops       = 10000
  data_volume_throughput = 500
  dns_zone_id            = var.dns_zone_id
  dns_zone_name          = var.dns_zone_name
  tags                   = local.tags
}
