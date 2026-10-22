variable "prod_writer_role_arns" {
  type        = list(string)
  description = "Production ClickHouse instance role(s), cross-account"
}

variable "dr_writer_role_arns" {
  type        = list(string)
  description = "DR ClickHouse instance role(s), cross-account"
}

variable "replication_role_arn" {
  type        = string
  description = "S3 replication role in this account"
}
