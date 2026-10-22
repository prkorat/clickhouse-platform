# Dedicated BACKUP account (design doc Section 7.1). Production admins have no access here, so a
# compromised prod account cannot delete recovery points. Primary bucket + cross-region copy, both Object Lock.

resource "aws_kms_key" "backup" {
  description             = "ClickHouse backups"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_key" "backup_dr" {
  provider                = aws.dr
  description             = "ClickHouse backups (DR region copy)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

module "backup_dr_region" {
  source = "../../modules/backup_vault"
  providers = {
    aws = aws.dr
  }
  bucket_name      = "ch-backup-prod-usw2"
  kms_key_arn      = aws_kms_key.backup_dr.arn
  writer_role_arns = var.dr_writer_role_arns
}

module "backup_primary" {
  source               = "../../modules/backup_vault"
  bucket_name          = "ch-backup-prod-use1"
  kms_key_arn          = aws_kms_key.backup.arn
  writer_role_arns     = var.prod_writer_role_arns
  replica_bucket_arn   = module.backup_dr_region.bucket_arn
  replica_kms_key_arn  = aws_kms_key.backup_dr.arn
  replication_role_arn = var.replication_role_arn
}
