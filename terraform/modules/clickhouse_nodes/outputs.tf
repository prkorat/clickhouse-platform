output "private_ips" {
  value = { for k, i in aws_instance.node : k => i.private_ip }
}

output "instance_ids" {
  value = { for k, i in aws_instance.node : k => i.id }
}

output "role_arn" {
  value = aws_iam_role.node.arn
}
