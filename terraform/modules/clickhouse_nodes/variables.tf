variable "name_prefix" {
  type = string
}

variable "role" {
  type        = string
  description = "clickhouse or keeper"
  validation {
    condition     = contains(["clickhouse", "keeper"], var.role)
    error_message = "role must be clickhouse or keeper"
  }
}

variable "nodes" {
  type        = map(object({ az = string, shard = optional(string), replica = optional(string) }))
  description = "hostname -> placement, e.g. { \"ch-s01-r1\" = { az = \"us-east-1a\", shard = \"01\", replica = \"r1\" } }"
}

variable "instance_type" {
  type = string
}

variable "ami_id" {
  type        = string
  description = "CIS-hardened base AMI built by Packer (os_hardening role baked in)"
}

variable "subnet_ids_by_az" {
  type = map(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "ebs_kms_key_arn" {
  type = string
}

variable "kms_key_arns" {
  type        = list(string)
  description = "Keys the node role may use (EBS, S3 cold, secrets)"
}

variable "secret_arns" {
  type        = list(string)
  description = "Secrets Manager ARNs this role may read (disk keys, interserver secret, Keeper identity)"
}

variable "cold_bucket_arn" {
  type    = string
  default = ""
}

variable "backup_bucket_arn" {
  type    = string
  default = ""
}

variable "data_volume_count" {
  type        = number
  description = "gp3 volumes per node: 4 for data nodes (warm tier RAID 0), 1 for Keeper"
}

variable "data_volume_size_gb" {
  type = number
}

variable "data_volume_iops" {
  type    = number
  default = 3000
}

variable "data_volume_throughput" {
  type    = number
  default = 250
}

variable "dns_zone_id" {
  type = string
}

variable "dns_zone_name" {
  type        = string
  description = "Private zone, e.g. ch.prod.internal"
}

variable "termination_protection" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
