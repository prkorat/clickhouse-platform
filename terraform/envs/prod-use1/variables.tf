variable "environment" {
  type    = string
  default = "prod"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "region_short" {
  type    = string
  default = "use1"
}

variable "shard_count" {
  type    = number
  default = 12
}

variable "replicas_per_shard" {
  type    = number
  default = 2
}

variable "data_instance_type" {
  type    = string
  default = "i4i.16xlarge"
}

variable "keeper_instance_type" {
  type    = string
  default = "m7i.2xlarge"
}

variable "ami_id" {
  type = string
}

# ---- From the shared networking stack
variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "data_subnet_ids_by_az" {
  type = map(string)
}

variable "keeper_subnet_ids_by_az" {
  type = map(string)
}

variable "client_prefix_list_id" {
  type = string
}

variable "s3_prefix_list_id" {
  type = string
}

variable "dns_zone_id" {
  type = string
}

variable "dns_zone_name" {
  type = string
}

# ---- Security / IAM
variable "key_admin_role_arns" {
  type = list(string)
}

variable "autoscaling_service_role_arn" {
  type = string
}

variable "backup_role_arn" {
  type = string
}

variable "backup_bucket_arn" {
  type        = string
  description = "Bucket in the backup account (terraform/envs/backup-account)"
}

variable "bootstrap_ebs_kms_key_arn" {
  type        = string
  description = "EBS CMK. Created by module.kms on first apply, then pinned here to break the role<->key cycle"
}

variable "node_kms_key_arns" {
  type = list(string)
}

variable "clickhouse_secret_arns" {
  type = list(string)
}

variable "keeper_secret_arns" {
  type = list(string)
}
