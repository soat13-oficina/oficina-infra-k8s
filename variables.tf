variable "project" {
  description = "Nome do projeto, usado em tags e como prefixo de recursos."
  type        = string
  default     = "oficina"
}

variable "aws_region" {
  description = "Regiao AWS onde a plataforma sera provisionada."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Nome do cluster EKS. Tambem usado como prefixo dos demais recursos."
  type        = string
  default     = "oficina"
}

variable "kubernetes_version" {
  description = "Versao do Kubernetes no EKS. Mantenha uma versao em standard support - versoes antigas caem em extended support e o control plane custa 6x mais."
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "CIDR da VPC da plataforma."
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_type" {
  description = "Tipo de instancia dos worker nodes. t3.medium (e nao t3.small) porque o DaemonSet do Datadog roda em TODO node e o t3.small nao cabe: ~1.5 GiB alocaveis contra 2x384Mi so de producao mais ~288Mi de agent+trace-agent, sem contar coredns e kube-proxy."
  type        = string
  default     = "t3.medium"
}

variable "node_min_size" {
  description = "Minimo de nodes no managed node group."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximo de nodes no managed node group - teto para o crescimento do HPA da aplicacao."
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Quantidade desejada de nodes no managed node group."
  type        = number
  default     = 2
}

variable "ecr_repository_name" {
  description = "Nome do repositorio ECR das imagens da aplicacao."
  type        = string
  default     = "oficina"
}

# A segregacao homologacao/producao acontece por namespace (plataforma
# compartilhada - ver docs/adr/0002-plataforma-compartilhada.md). Esta lista
# define quais ServiceAccounts podem assumir a IAM Role de SES via IRSA.
variable "app_namespaces" {
  description = "Namespaces do cluster que hospedam a aplicacao, um por ambiente."
  type        = list(string)
  default     = ["oficina-hml", "oficina-prd"]
}

variable "app_service_account" {
  description = "Nome do ServiceAccount da aplicacao dentro de cada namespace (deve casar com os manifestos do repo da aplicacao)."
  type        = string
  default     = "oficina-api"
}

# --- Observabilidade (Datadog) ------------------------------------------------------
# Ver datadog.tf e docs/adr/0003-observabilidade-datadog.md.

variable "datadog_api_key" {
  description = "API key da Datadog. Vazio (padrao) DESLIGA todo o stack de observabilidade - o helm_release nao e criado. Preencher so quando o trial de 14 dias for ativado, perto da demo."
  type        = string
  default     = ""
  sensitive   = true
}

variable "datadog_enabled" {
  description = "Liga o Datadog Agent. DESLIGUE no PRIMEIRO apply de um cluster novo: o provider helm se configura a partir do module.eks e, enquanto o cluster nao existe, o endpoint e o CA sao desconhecidos no plan. Existe separado de datadog_api_key porque, com a chave vindo de um secret de ORGANIZACAO, ela ja esta presente no apply de bootstrap e nao serve mais como interruptor."
  type        = bool
  default     = true
}

variable "datadog_site" {
  description = "Site da conta Datadog. datadoghq.com e o padrao (US1); contas na UE usam datadoghq.eu e enviar para o site errado faz o agent autenticar em vazio."
  type        = string
  default     = "datadoghq.com"
}

variable "datadog_chart_version" {
  description = "Versao do chart Helm do Datadog. Fixada para que dois applies do mesmo commit instalem a mesma coisa."
  type        = string
  default     = "3.244.0"
}

variable "datadog_app_key" {
  description = "APPLICATION key da Datadog. Credencial DIFERENTE da API key: a API key envia telemetria (Agent), a app key assina a escrita na API de configuracao e e o que cria dashboards, monitors, synthetics e SLO. Vazia (padrao) desliga so esses recursos - o Agent continua subindo com a API key. Escopos necessarios: dashboards_write, monitors_write, synthetics_write, slos_write."
  type        = string
  default     = ""
  sensitive   = true
}

variable "datadog_ambiente_monitorado" {
  description = "Ambiente coberto pelos monitors e pelo teste sintetico. So UM: alertar em dois ambientes gera ruido sem ninguem de plantao, e o dashboard ja alterna entre eles pelo template variable. Define tambem o namespace observado (oficina-<ambiente>). Vale hml enquanto so esse ambiente estiver provisionado - monitor sobre namespace vazio nao coleta nada; volte para prd quando producao subir."
  type        = string
  default     = "hml"

  validation {
    condition     = contains(["hml", "prd"], var.datadog_ambiente_monitorado)
    error_message = "datadog_ambiente_monitorado deve ser hml ou prd (os namespaces existentes em var.app_namespaces)."
  }
}

variable "datadog_alerta_destino" {
  description = "Destino das notificacoes dos monitors, no formato de @mention da Datadog (@email@dominio.com, @slack-canal, @pagerduty-servico). Vazio (padrao) cria os monitors SEM notificacao: eles disparam e ficam visiveis na UI, mas nao acordam ninguem - preferivel a um handle invalido, que faz o create do monitor falhar."
  type        = string
  default     = ""
}

variable "datadog_latencia_p95_segundos" {
  description = "Alvo de latencia p95 das APIs, em segundos, usado pelo monitor de latencia (warning na metade do valor). Nao ha SLA formal no desafio: 2s e o limiar a partir do qual a experiencia degrada de forma perceptivel numa API de cadastro."
  type        = number
  default     = 2
}

variable "app_public_url" {
  description = "URL publica da aplicacao (NLB criado pelo Service do Kubernetes), sem barra final - ex.: http://k8s-oficina-abc123.elb.us-east-1.amazonaws.com. Vazia (padrao) desliga o teste sintetico de uptime. O endereco nasce FORA do Terraform, com o Service, entao so e conhecido apos o primeiro deploy da aplicacao: preencher no apply seguinte."
  type        = string
  default     = ""
}
