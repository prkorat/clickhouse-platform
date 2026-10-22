variable "bucket_name" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "allowed_role_arns" {
  type        = list(string)
  description = "Only these principals may read/write objects (cluster instance role, backup role)"
}

variable "tags" {
  type    = map(string)
  default = {}
}
