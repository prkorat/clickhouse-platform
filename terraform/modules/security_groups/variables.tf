variable "name_prefix" {
  type        = string
  description = "Prefix for resource names, e.g. ch-prod-use1"
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR; egress is limited to it"
}

variable "client_prefix_list_id" {
  type        = string
  description = "Managed prefix list of PrivateLink NLB / VPN subnets allowed to reach chproxy"
}

variable "s3_prefix_list_id" {
  type        = string
  description = "Prefix list of the S3 gateway endpoint"
}

variable "tags" {
  type    = map(string)
  default = {}
}
