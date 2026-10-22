# Customer-managed keys (design doc Section 4.6). Separate keys per purpose so a key policy can
# grant exactly the roles that need it: EBS, S3 cold tier, Secrets Manager (disk keys, interserver secret).

resource "aws_kms_key" "this" {
  for_each                = toset(var.purposes)
  description             = "${var.name_prefix} ${each.key}"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.key[each.key].json
  tags                    = merge(var.tags, { Purpose = each.key })
}

resource "aws_kms_alias" "this" {
  for_each      = aws_kms_key.this
  name          = "alias/${var.name_prefix}-${each.key}"
  target_key_id = each.value.key_id
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "key" {
  for_each = toset(var.purposes)

  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*", "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*", "kms:Get*", "kms:Delete*", "kms:TagResource", "kms:UntagResource", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = var.key_admin_role_arns
    }
  }

  # Key admins cannot decrypt: data access is limited to the workload roles below.
  statement {
    sid       = "Use"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = lookup(var.key_user_role_arns, each.key, [])
    }
  }

  statement {
    sid       = "AllowAWSServiceGrants"
    actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = lookup(var.key_user_role_arns, each.key, [])
    }
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}
