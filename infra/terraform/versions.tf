terraform {
  required_version = ">= 1.7.0" # removed blocks

  # State is local, like julia-perf's. Add a remote S3 backend with locking
  # here (and run `terraform init -migrate-state`) if more than one person
  # ever applies.

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

# Credentials come from the environment: run everything here with
# AWS_PROFILE=ci-timing, the role that cannot touch julia-perf's resources
# (docs/database-migration.md, "Protecting julia-perf's database").
provider "aws" {
  region = var.aws_region

  # Applied to every resource; per-resource `tags` only add a Name on top.
  default_tags {
    tags = local.common_tags
  }
}
