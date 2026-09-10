terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Instala o Datadog Agent no cluster (datadog.tf). A partir do 3.x a conexao com o
    # Kubernetes e um ATRIBUTO (kubernetes = { ... }), nao mais um bloco aninhado - com
    # "~> 2.0" o provider block de datadog.tf nao parseia.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    # Dashboards, monitors, synthetics e SLO (datadog-*.tf). Note que este provider fala
    # com a API da Datadog, e nao com o cluster: ele funciona - e e planejado - mesmo com o
    # EKS inteiro fora do ar, o que e justamente o que se quer de um monitor.
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.0"
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
