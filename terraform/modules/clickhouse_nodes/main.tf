# Fixed-identity EC2 nodes for ClickHouse data nodes or Keeper (design doc Sections 3.1-3.2).
# Nodes are individually addressed (one resource per hostname), not an ASG: each replica has a stable
# name, macros and Keeper path. Replacing a node keeps its hostname (runbooks/replace-node.md).
#
# Data node: i4i.16xlarge (64 vCPU, 512 GiB, 4 x 3.75 TB instance-store NVMe = hot tier)
#            + 4 x gp3 warm volumes (RAID 0 by Ansible), spread across 3 AZs, replica r1/r2 in different AZs.
# Keeper:    m7i.2xlarge + gp3 io-optimised log/snapshot volume, one per AZ.

resource "aws_instance" "node" {
  for_each = var.nodes

  ami                     = var.ami_id
  instance_type           = var.instance_type
  subnet_id               = var.subnet_ids_by_az[each.value.az]
  vpc_security_group_ids  = var.security_group_ids
  iam_instance_profile    = aws_iam_instance_profile.node.name
  ebs_optimized           = true
  monitoring              = true
  disable_api_termination = var.termination_protection

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 100
    encrypted   = true
    kms_key_id  = var.ebs_kms_key_arn
  }

  # Nothing secret in user data: only the hostname; Ansible + Vault Agent do the rest.
  user_data = <<-EOT
    #cloud-config
    hostname: ${each.key}
    fqdn: ${each.key}.${var.dns_zone_name}
    prefer_fqdn_over_hostname: true
  EOT

  tags = merge(var.tags, {
    Name    = each.key
    Role    = var.role
    Shard   = lookup(each.value, "shard", "")
    Replica = lookup(each.value, "replica", "")
    AZ      = each.value.az
  })

  lifecycle {
    ignore_changes = [ami] # AMI rollouts go through the rolling-upgrade playbook, not a Terraform replace
  }
}

# Warm tier (data nodes) or Keeper log/snapshot volume.
locals {
  volumes = merge([
    for node, cfg in var.nodes : {
      for i in range(var.data_volume_count) :
      "${node}-${i}" => { node = node, az = cfg.az, index = i }
    }
  ]...)
  device_letters = ["f", "g", "h", "i", "j", "k", "l", "m"]
}

resource "aws_ebs_volume" "data" {
  for_each          = local.volumes
  availability_zone = each.value.az
  type              = "gp3"
  size              = var.data_volume_size_gb
  iops              = var.data_volume_iops
  throughput        = var.data_volume_throughput
  encrypted         = true
  kms_key_id        = var.ebs_kms_key_arn
  tags              = merge(var.tags, { Name = each.key, Node = each.value.node })
}

resource "aws_volume_attachment" "data" {
  for_each    = local.volumes
  device_name = "/dev/sd${local.device_letters[each.value.index]}"
  volume_id   = aws_ebs_volume.data[each.key].id
  instance_id = aws_instance.node[each.value.node].id
}

resource "aws_route53_record" "node" {
  for_each = var.nodes
  zone_id  = var.dns_zone_id
  name     = "${each.key}.${var.dns_zone_name}"
  type     = "A"
  ttl      = 60
  records  = [aws_instance.node[each.key].private_ip]
}

# ---- IAM: SSM for access (no SSH), S3 cold tier via instance role (no keys), scoped Secrets Manager reads.
resource "aws_iam_role" "node" {
  name               = "${var.name_prefix}-${var.role}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "node" {
  statement {
    sid       = "ReadOwnSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }

  dynamic "statement" {
    for_each = length(var.cold_bucket_arn) > 0 ? [1] : []
    content {
      sid       = "ColdTier"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:AbortMultipartUpload"]
      resources = [var.cold_bucket_arn, "${var.cold_bucket_arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.backup_bucket_arn) > 0 ? [1] : []
    content {
      sid       = "BackupWriteOnly" # cross-account backup bucket: write and read, never delete (Object Lock)
      actions   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:AbortMultipartUpload"]
      resources = [var.backup_bucket_arn, "${var.backup_bucket_arn}/*"]
    }
  }

  statement {
    sid       = "UseKeys"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = var.kms_key_arns
  }
}

resource "aws_iam_role_policy" "node" {
  name   = "clickhouse-node"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node.json
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name_prefix}-${var.role}"
  role = aws_iam_role.node.name
}
