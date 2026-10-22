output "ids" {
  description = "Security group id per role: ch_data, ch_keeper, ch_proxy, kafka_connect, prometheus"
  value       = { for k, sg in aws_security_group.this : k => sg.id }
}
