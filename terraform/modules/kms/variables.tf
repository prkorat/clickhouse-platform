variable "name_prefix" {
  type = string
}

variable "purposes" {
  type    = list(string)
  default = ["ebs", "s3-cold", "secrets"]
}

variable "key_admin_role_arns" {
  type        = list(string)
  description = "Roles that administer keys (cannot use them for data)"
}

variable "key_user_role_arns" {
  type        = map(list(string))
  description = "Purpose -> roles allowed to encrypt/decrypt, e.g. { s3-cold = [instance_role_arn, backup_role_arn] }"
}

variable "tags" {
  type    = map(string)
  default = {}
}
