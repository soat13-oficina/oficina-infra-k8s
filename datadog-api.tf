# Provider da API da Datadog - dashboards, monitors, synthetics e SLO (ADR 0003).
#
# DUAS CREDENCIAIS, E NAO UMA. O Agent (datadog.tf) precisa so da API key: ela identifica
# a ORGANIZACAO e serve para ENVIAR telemetria. Criar dashboard, monitor ou teste sintetico
# e ESCRITA na API de configuracao e exige tambem uma APPLICATION key, que identifica o
# USUARIO que assina a chamada e carrega os escopos (dashboards_write, monitors_write,
# synthetics_write, slos_write).
#
# Consequencia pratica: so a API key liga o agent e nao cria nenhum monitor; so a app key
# nao faz nada. Por isso o gate abaixo e separado do gate do helm_release.
#
#   terraform apply -var="datadog_api_key=$DD_API_KEY" -var="datadog_app_key=$DD_APP_KEY"
#
locals {
  # Agent no cluster: mesma condicao ja usada pelo helm_release em datadog.tf.
  datadog_agent_habilitado = var.datadog_enabled && var.datadog_api_key != ""

  # Configuracao via API: exige as duas chaves. Sem app key, tudo que este arquivo e os
  # datadog-*.tf vizinhos declaram fica com count = 0 e o apply segue normalmente.
  datadog_api_habilitada = local.datadog_agent_habilitado && var.datadog_app_key != ""

  # Teste sintetico depende ainda do endereco publico do NLB, que nasce com o Service do
  # Kubernetes (fora do Terraform) e so e conhecido depois do primeiro deploy da aplicacao.
  datadog_uptime_habilitado = local.datadog_api_habilitada && var.app_public_url != ""

  # Sufixo de destino das notificacoes. Vazio = monitor criado sem @mention: ele muda de
  # estado e aparece no Datadog, mas nao acorda ninguem. E o default de proposito - handle
  # invalido faz o create do monitor FALHAR, e nao apenas nao notificar.
  datadog_notificacao = var.datadog_alerta_destino == "" ? "" : "\n\n${var.datadog_alerta_destino}"

  # Tags comuns a todo objeto criado aqui. "terraform:true" e o marcador que separa o que e
  # versionado do que alguem criou clicando na UI durante a demo.
  datadog_tags = [
    "service:oficina-api",
    "env:${var.datadog_ambiente_monitorado}",
    "project:${var.project}",
    "terraform:true",
  ]

  # Namespace do ambiente monitorado pelos monitors de Kubernetes. Os namespaces sao
  # oficina-hml e oficina-prd (var.app_namespaces) e o sufixo casa com o nome do ambiente.
  datadog_kube_namespace = "${var.project}-${var.datadog_ambiente_monitorado}"
}

# validate = false quando nao ha chave: sem isso o provider tenta autenticar na Datadog em
# TODO plan/apply - inclusive no `terraform validate` do CI, que roda sem secret nenhum - e
# falha antes de olhar para os recursos, mesmo com todos eles em count = 0.
provider "datadog" {
  api_key  = var.datadog_api_key
  app_key  = var.datadog_app_key
  api_url  = "https://api.${var.datadog_site}/"
  validate = local.datadog_api_habilitada
}
