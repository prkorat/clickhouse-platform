# Immutable backup bucket in the dedicated BACKUP account (design doc Section 7.1).
# Apply this module with the backup-account provider. Production admins cannot delete backups:
# Object Lock COMPLIANCE mode, 35-day default retention, cross-account role may write but not delete.

resource "aws_s3_bucket" "this" {
  bucket              = var.bucket_name
  object_lock_enabled = true
  tags                = var.tags
}

resource "aws_s3_bucket_object_lock_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.retention_days
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

# Monthly fulls kept 12 months; everything else expires after the lock period.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    id     = "monthly-fulls"
    status = "Enabled"
    filter { prefix = "prod/monthly/" }
    transition {
      days          = 35
      storage_class = "GLACIER_IR"
    }
    expiration { days = 365 }
  }
  rule {
    id     = "daily"
    status = "Enabled"
    filter { prefix = "prod/daily/" }
    expiration { days = var.retention_days + 1 }
    noncurrent_version_expiration { noncurrent_days = 1 }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "ProdClusterWriteNoDelete"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:AbortMultipartUpload"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = var.writer_role_arns
    }
  }

  statement {
    sid       = "DenyDeleteAndLockChanges"
    effect    = "Deny"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutBucketObjectLockConfiguration", "s3:BypassGovernanceRetention"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = var.writer_role_arns
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json
}

# Cross-region copy (also Object Lock) so backups survive a region loss.
resource "aws_s3_bucket_replication_configuration" "this" {
  count  = var.replica_bucket_arn == "" ? 0 : 1
  bucket = aws_s3_bucket.this.id
  role   = var.replication_role_arn

  rule {
    id     = "to-dr-region"
    status = "Enabled"
    filter {}
    delete_marker_replication { status = "Disabled" }
    source_selection_criteria {
      sse_kms_encrypted_objects { status = "Enabled" }
    }
    destination {
      bucket = var.replica_bucket_arn
      encryption_configuration { replica_kms_key_id = var.replica_kms_key_arn }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}
