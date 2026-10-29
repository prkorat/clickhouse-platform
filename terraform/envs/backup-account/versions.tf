terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  backend "s3" {
    bucket         = "example-tfstate-data-platform"
    key            = "clickhouse/backup-account/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tfstate-lock"
    encrypt        = true
    kms_key_id     = "alias/tfstate"
  }
}

provider "aws" {
  region = "us-east-1"
  assume_role {
    role_arn     = "arn:aws:iam::777788889999:role/terraform-backup-apply"
    session_name = "terraform-clickhouse-backup"
  }
}

provider "aws" {
  alias  = "dr"
  region = "us-west-2"
  assume_role {
    role_arn     = "arn:aws:iam::777788889999:role/terraform-backup-apply"
    session_name = "terraform-clickhouse-backup"
  }
}
