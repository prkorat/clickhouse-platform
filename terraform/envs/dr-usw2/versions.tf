terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }

  # State lives in a separate account; DynamoDB lock prevents concurrent applies.
  backend "s3" {
    bucket         = "example-tfstate-data-platform"
    key            = "clickhouse/dr-usw2/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tfstate-lock"
    encrypt        = true
    kms_key_id     = "alias/tfstate"
  }
}

provider "aws" {
  region = var.region

  # CI assumes this role via GitHub OIDC; humans never apply to prod.
  assume_role {
    role_arn     = "arn:aws:iam::111122223333:role/terraform-clickhouse-apply"
    session_name = "terraform-clickhouse"
  }

  default_tags {
    tags = {
      Repository = "clickhouse-platform"
    }
  }
}
