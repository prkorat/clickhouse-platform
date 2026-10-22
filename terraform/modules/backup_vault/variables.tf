variable "bucket_name" {
  type = string
}

variable "kms_key_arn" {
  type        = string
  description = "Backup-account CMK"
}

variable "retention_days" {
  type    = number
  default = 35
}

variable "writer_role_arns" {
  type        = list(string)
  description = "Production ClickHouse instance roles (cross-account) allowed to write backups"
}

variable "replica_bucket_arn" {
  type    = string
  default = ""
}

variable "replica_kms_key_arn" {
  type    = string
  default = ""
}

variable "replication_role_arn" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
