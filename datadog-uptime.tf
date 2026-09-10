# Uptime: teste sintetico HTTP + SLO de disponibilidade (ADR 0003).
#
# Item "healthchecks e uptime" pelo lado de FORA. Os probes do Kubernetes respondem
# "o pod acha que esta bem"; o teste sintetico responde "um cliente na internet consegue
# usar a API", que e pergunta diferente - passa por NLB, Service, kube-proxy e Security
# Group, e qualquer um deles pode estar quebrado com todos os pods Ready.
#
# POR QUE O ALVO NAO E /actuator/health/liveness. Em nuvem o actuator sobe na 8081, porta
# que de proposito NAO consta no Service (que e type: LoadBalancer e publica um NLB na
# internet - expor /actuator/prometheus ali publicaria volume de OS e latencias). Um teste
# sintetico roda de fora e so alcanca a 8080. /v3/api-docs e o endpoint publico
# (permitAll em SecurityConfig) mais barato que ainda exercita Tomcat + Spring MVC de
# ponta a ponta; a saude do BANCO continua coberta pelo readinessProbe, e a queda dele
# aparece no monitor de replicas prontas.
resource "datadog_synthetics_test" "uptime_api" {
  count = local.datadog_uptime_habilitado ? 1 : 0

  name    = "[oficina][${var.datadog_ambiente_monitorado}] Uptime da API"
  type    = "api"
  subtype = "http"
  status  = "live"

  # Duas regioes: Sao Paulo (mais perto do usuario real) e N. Virginia (mesma regiao do
  # cluster). Com min_location_failed = 2, uma unica regiao com problema de rede propria
  # nao gera alerta - so a falha nas duas conta.
  locations = ["aws:sa-east-1", "aws:us-east-1"]

  request_definition {
    method = "GET"
    url    = "${var.app_public_url}/v3/api-docs"
    # Acima do timeoutSeconds: 3 dos probes: aqui o tempo inclui a travessia da internet.
    timeout = 10
  }

  assertion {
    type     = "statusCode"
    operator = "is"
    target   = "200"
  }

  assertion {
    type     = "responseTime"
    operator = "lessThan"
    target   = "5000"
  }

  options_list {
    # 5 min: dentro do free tier de execucoes e suficiente para um SLO de 7/30 dias.
    tick_every = 300

    # Falha precisa persistir 5 min para virar alerta: descarta o rolling update, em que o
    # NLB leva alguns segundos para tirar o pod antigo do balanceamento.
    min_failure_duration = 300
    min_location_failed  = 2

    retry {
      count    = 2
      interval = 5000
    }

    monitor_name     = "[oficina][${var.datadog_ambiente_monitorado}] API inacessivel pela internet"
    monitor_priority = 1
  }

  message = <<-EOT
    A API nao esta respondendo 200 em ${var.app_public_url}/v3/api-docs a partir de duas regioes.

    **Impacto:** indisponibilidade externa. Diferente do monitor de replicas prontas, este
    falha mesmo com todos os pods Ready - o problema esta entre a internet e o pod: NLB,
    Service, Security Group ou DNS.

    **Onde olhar:** confira primeiro se os pods estao Ready (se estiverem, o problema e de
    rede, nao de aplicacao) e depois se o NLB do Service continua existindo - ele e criado
    pelo Kubernetes, FORA do Terraform, e um `kubectl delete -k` o remove junto.${local.datadog_notificacao}
  EOT

  tags = concat(local.datadog_tags, ["signal:uptime"])
}

# --- SLO de disponibilidade ---------------------------------------------------------
#
# Traduz os dois lados do healthcheck num numero unico e comparavel no tempo, com error
# budget. Baseado em MONITOR (e nao em metrica) porque os sinais ja existem como monitor e
# nao ha metrica unica que represente "a API estava utilizavel".
#
# O SLO cobre o monitor de replicas sempre, e soma o sintetico quando ha URL publica
# configurada - assim ele nasce valido no primeiro apply, antes mesmo de a aplicacao ter
# sido publicada, em vez de quebrar o dashboard que o referencia.
resource "datadog_service_level_objective" "disponibilidade_api" {
  count = local.datadog_api_habilitada ? 1 : 0

  name        = "[oficina][${var.datadog_ambiente_monitorado}] Disponibilidade da API"
  type        = "monitor"
  description = "Percentual do tempo em que a API esteve com todas as replicas prontas e acessivel pela internet."

  monitor_ids = concat(
    [datadog_monitor.replicas_prontas[0].id],
    local.datadog_uptime_habilitado ? [datadog_synthetics_test.uptime_api[0].monitor_id] : [],
  )

  # 99% em 30 dias = ~7h de orcamento de erro por mes. Alvo deliberadamente honesto para
  # um cluster de 2 nodes com rolling update sem PodDisruptionBudget: prometer 99,9% aqui
  # seria queimar o budget na primeira janela de manutencao.
  thresholds {
    timeframe = "7d"
    target    = 99
    warning   = 99.5
  }

  thresholds {
    timeframe = "30d"
    target    = 99
    warning   = 99.5
  }

  tags = concat(local.datadog_tags, ["signal:uptime"])
}
