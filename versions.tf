terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Backend parcial: bucket e region vem de backend.hcl (nao versionado).
  #   terraform init -backend-config=backend.hcl
  # A key e fixa e EXCLUSIVA deste repositorio: o repo de banco
  # (oficina-infra-database) le estes outputs via terraform_remote_state
  # apontando exatamente para esta key.
  backend "s3" {
    key          = "oficina/infra-k8s.tfstate"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Layer     = "platform"
      ManagedBy = "terraform"
      Repo      = "oficina-infra-k8s"
    }
  }
}
