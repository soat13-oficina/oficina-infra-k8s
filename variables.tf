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
  description = "Tipo de instancia dos worker nodes."
  type        = string
  default     = "t3.small"
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
