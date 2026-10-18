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
  description = "Maximo de nodes no managed node group - teto para o crescimento dos HPAs. 5 (e nao 4) porque sao tres servicos por ambiente: com os dois ambientes no pico do HPA os requests chegam a ~3,9 vCPU e ~6 GiB (PLANO-FASE-4.md, secao 9.4) e a margem acaba em 4 nodes t3.medium. Em repouso, 2 nodes bastam; o teto so custa quando o HPA o usa."
  type        = number
  default     = 5
}

variable "node_desired_size" {
  description = "Quantidade desejada de nodes no managed node group."
  type        = number
  default     = 2
}

# A segregacao homologacao/producao acontece por namespace (plataforma
# compartilhada - ver docs/adr/0002-plataforma-compartilhada.md). Esta lista e o
# contrato de nomes com os repositorios dos servicos e com o job de destroy, que limpa
# os Ingress desses namespaces antes de remover a plataforma.
variable "app_namespaces" {
  description = "Namespaces do cluster que hospedam os servicos, um por ambiente."
  type        = list(string)
  default     = ["oficina-hml", "oficina-prd"]
}

# --- Exposicao (AWS Load Balancer Controller) -----------------------------------------
# Ver alb-controller.tf e docs/adr/0008-exposicao-e-roteamento.md do oficina-app.

variable "alb_controller_enabled" {
  description = "Instala o AWS Load Balancer Controller (Helm). DESLIGUE no PRIMEIRO apply de um cluster novo, pelo mesmo motivo de datadog_enabled: o provider helm se configura a partir do module.eks e, enquanto o cluster nao existe, endpoint e CA sao desconhecidos no plan. Sem o controller, os Ingress dos servicos sao aceitos pelo cluster mas nenhum ALB nasce."
  type        = bool
  default     = true
}

variable "alb_controller_chart_version" {
  description = "Versao do chart eks/aws-load-balancer-controller. FIXADA junto com a politica IAM de policies/aws-load-balancer-controller-iam-policy.json (baixada da mesma tag do projeto): trocar uma sem a outra deixa o controller sem permissao para uma API nova. Ao subir a versao, baixe a politica da tag correspondente em kubernetes-sigs/aws-load-balancer-controller/docs/install/iam_policy.json."
  type        = string
  default     = "3.5.0"
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

variable "servicos" {
  description = "Servicos monitorados: o nome e o DD_SERVICE (unified service tagging) E o nome do Deployment, que coincidem. Cada um ganha seus monitors de erro 5xx, latencia, CPU, memoria e replicas. O OS Service ainda se chama oficina-api; vira oficina-os-service no rename (docs/arquitetura/convencoes-de-nomes.md do oficina-app) - troque aqui no mesmo dia."
  type        = list(string)
  default     = ["oficina-api", "oficina-billing-service", "oficina-execution-service"]
}

variable "app_public_url" {
  description = "URL publica do sistema, sem barra final: o invoke_url do API Gateway (output api_gateway_url de oficina-lambda-auth, ex.: https://abc123.execute-api.us-east-1.amazonaws.com) ou o ALB. Vazia (padrao) desliga o teste sintetico de uptime. Nasce fora desta camada, entao so e conhecida depois do deploy: preencher no apply seguinte."
  type        = string
  default     = ""
}
