output "key_arns" {
  value = { for k, key in aws_kms_key.this : k => key.arn }
}
