# Contrato publico desta camada. Os repositorios oficina-infra-database,
# oficina-lambda-auth e oficina-app consomem estes outputs via
# terraform_remote_state (ou via AWS CLI, no caso do deploy da aplicacao).
# Remover/renomear um output aqui QUEBRA os repos consumidores - trate esta
# lista como API versionada.

output "aws_region" {
  description = "Regiao AWS da plataforma."
  value       = var.aws_region
}

output "vpc_id" {
  description = "ID da VPC da plataforma."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR da VPC, util para regras de seguranca nos repos consumidores."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Subnets privadas (worker nodes do EKS)."
  value       = module.vpc.private_subnets
}

output "database_subnet_ids" {
  description = "Subnets dedicadas a banco de dados."
  value       = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  description = "Nome do DB subnet group - consumido pelo repo oficina-infra-database."
  value       = module.vpc.database_subnet_group_name
}

output "cluster_name" {
  description = "Nome do cluster EKS."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint da API do cluster EKS."
  value       = module.eks.cluster_endpoint
}

output "node_security_group_id" {
  description = "Security group dos worker nodes - consumido pelo repo oficina-infra-database para liberar o acesso ao PostgreSQL."
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN do OIDC provider do cluster, para novas roles IRSA."
  value       = module.eks.oidc_provider_arn
}

output "configure_kubectl" {
  description = "Comando para apontar o kubectl para o cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_url" {
  description = "URL do repositorio ECR para push/pull das imagens da aplicacao."
  value       = aws_ecr_repository.app.repository_url
}

output "ses_role_arn" {
  description = "ARN da IAM Role (IRSA) com permissao ses:SendEmail, anotada no ServiceAccount da aplicacao."
  value       = aws_iam_role.ses_send_email.arn
}

output "app_namespaces" {
  description = "Namespaces de aplicacao previstos nesta plataforma (um por ambiente)."
  value       = var.app_namespaces
}
