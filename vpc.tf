data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Rede da plataforma. Vive NESTE repositorio (e nao no repo de banco) porque o
# cluster tem o ciclo de vida mais longo e o maior numero de dependentes; o
# repo do banco consome vpc_id / database_subnet_group_name /
# node_security_group_id via terraform_remote_state.
# Ver docs/adr/0001-separacao-dos-states.md.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs              = local.azs
  private_subnets  = [cidrsubnet(var.vpc_cidr, 8, 1), cidrsubnet(var.vpc_cidr, 8, 2)]
  public_subnets   = [cidrsubnet(var.vpc_cidr, 8, 101), cidrsubnet(var.vpc_cidr, 8, 102)]
  database_subnets = [cidrsubnet(var.vpc_cidr, 8, 201), cidrsubnet(var.vpc_cidr, 8, 202)]

  create_database_subnet_group = true

  # NAT unico (em vez de um por AZ) corta o custo pela metade; suficiente
  # para o desafio - em producao seria um por AZ para alta disponibilidade.
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Tags que o Kubernetes usa para descobrir em quais subnets criar
  # LoadBalancers (o Service da API e type LoadBalancer / NLB publico,
  # alvo do API Gateway - ver repo oficina-lambda-auth).
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}
