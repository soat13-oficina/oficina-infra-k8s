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

output "oidc_provider" {
  description = "Emissor OIDC do cluster SEM o https:// - a chave das condicoes (<emissor>:sub, <emissor>:aud) da trust policy das roles IRSA dos servicos."
  value       = module.eks.oidc_provider
}

output "configure_kubectl" {
  description = "Comando para apontar o kubectl para o cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "alb_controller_role_arn" {
  description = "ARN da IAM Role (IRSA) do AWS Load Balancer Controller."
  value       = aws_iam_role.alb_controller.arn
}

output "app_namespaces" {
  description = "Namespaces de aplicacao previstos nesta plataforma (um por ambiente)."
  value       = var.app_namespaces
}

# --- Observabilidade ---------------------------------------------------------------
# Nao sao consumidos por outros repositorios: existem para que o apply termine imprimindo
# os links da entrega, em vez de mandar procurar na UI.
#
# one(recurso[*].attr) em vez de "condicao ? recurso[0].attr : null": os locals de
# habilitacao derivam de var.datadog_api_key, que e sensitive, e o Terraform recusa output
# que apenas TOQUE num valor sensivel - mesmo so na condicao do ternario. O splat devolve o
# unico elemento quando count = 1 e null quando count = 0, sem passar pela chave.

output "datadog_dashboard_url" {
  description = "URL do dashboard da Datadog. null quando o stack de observabilidade esta desligado."
  value       = one(datadog_dashboard_json.oficina[*].url)
}

output "datadog_monitores" {
  description = "ID de cada monitor criado, para conferir a entrega sem abrir a UI. Os por servico saem como mapa servico => id; todos vazios/null com o stack desligado."
  value = {
    notificacao_falha_definitiva = one(datadog_monitor.notificacao_falha_definitiva[*].id)
    api_erro_5xx                 = { for servico, monitor in datadog_monitor.api_erro_5xx : servico => monitor.id }
    api_latencia_p95             = { for servico, monitor in datadog_monitor.api_latencia_p95 : servico => monitor.id }
    pod_memoria                  = { for servico, monitor in datadog_monitor.pod_memoria : servico => monitor.id }
    pod_cpu                      = { for servico, monitor in datadog_monitor.pod_cpu : servico => monitor.id }
    replicas_prontas             = { for servico, monitor in datadog_monitor.replicas_prontas : servico => monitor.id }
    crashloop                    = one(datadog_monitor.crashloop[*].id)
    erros_integracao             = one(datadog_monitor.erros_integracao[*].id)
  }
}

output "datadog_synthetic_uptime_id" {
  description = "ID publico do teste sintetico de uptime. null enquanto var.app_public_url nao for preenchida."
  value       = one(datadog_synthetics_test.uptime_api[*].id)
}
