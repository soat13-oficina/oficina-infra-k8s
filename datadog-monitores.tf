# Monitors da Datadog (ADR 0003).
#
# Cobrem os quatro sinais que a tarefa pede alerta: latencia das APIs, CPU/memoria no
# Kubernetes, healthcheck/uptime e falhas no processamento de ordens de servico.
#
# UM AMBIENTE SO (var.datadog_ambiente_monitorado, default prd). Duplicar tudo em hml
# dobraria o numero de monitors para vigiar um ambiente onde ninguem esta de plantao e que
# nem sempre esta no ar. O dashboard, esse sim, alterna entre ambientes.
#
# O QUE NAO ESTA AQUI, DE PROPOSITO: RegraDeNegocioException. Ela vira 4xx e e uso normal
# da API - cliente inexistente, transicao invalida de OS. Alertar nela acorda alguem por
# usuario digitando errado. Erro que importa e 5xx, e esse tem monitor.
#
# TAGS DE FILTRO - por que cada consulta usa uma diferente:
#   ambiente:<env>     metricas de negocio; tag aplicada pela PROPRIA aplicacao
#                      (MetricasCommonTagsConfig), garantida mesmo se o agent nao ler os
#                      labels do pod
#   env:<env>          APM; vem de DD_ENV no container
#   kube_namespace:*   metricas de Kubernetes; vem do kubelet/kube-state-metrics, que nao
#                      conhecem "ambiente" nem "env"

# --- 1. Falha no processamento de ordens de servico ---------------------------------
#
# Item "alertas para falhas no processamento de ordens de servico".
#
# oficina.notificacoes.falhas.count so incrementa quando a notificacao esgotou as 5
# tentativas (notificacao.reprocessamento.max-tentativas). Falha transiente ainda sera
# reprocessada e "cliente sem e-mail" e cadastro incompleto: nenhuma das duas chega aqui.
# Chegar aqui significa que um cliente NAO foi avisado e ninguem vai tentar de novo -
# por isso o limiar e > 0, e nao uma taxa.
resource "datadog_monitor" "notificacao_falha_definitiva" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][${var.datadog_ambiente_monitorado}] Notificacao de OS falhou definitivamente"
  type = "query alert"

  query = "sum(last_15m):sum:oficina.notificacoes.falhas.count{ambiente:${var.datadog_ambiente_monitorado}}.as_count() > 0"

  message = <<-EOT
    {{#is_alert}}
    Uma ou mais notificacoes de ordem de servico esgotaram as 5 tentativas de reprocessamento.

    **Impacto:** o cliente NAO foi avisado da mudanca de status e nao havera nova tentativa automatica.

    **Onde olhar:** logs de `service:oficina-api` com `@log.logger:br.com.oficina.notificacao.*`,
    filtrando pelo `@numero_ordem_servico` para reconstruir o rastro da ordem.
    Causas tipicas: credencial/limite do Amazon SES ou remetente nao verificado.
    {{/is_alert}}
    {{#is_recovery}}
    Sem novas falhas definitivas de notificacao na ultima janela.
    {{/is_recovery}}${local.datadog_notificacao}
  EOT

  priority = 2

  monitor_thresholds {
    critical = 0
  }

  # notify_no_data = false: contador que so incrementa em erro passa a maior parte do tempo
  # sem emitir ponto nenhum. "Sem dados" aqui e a operacao normal, nao um problema.
  notify_no_data    = false
  renotify_interval = 60
  include_tags      = true

  tags = concat(local.datadog_tags, ["signal:negocio"])
}

# --- 2. Erro 5xx nas APIs -----------------------------------------------------------
#
# Taxa, e nao contagem absoluta: 10 erros em 100 requisicoes e incidente, 10 em 100.000 e
# ruido de rede. trace.servlet.request vem do dd-java-agent (autoinstrumentacao), sem
# nenhuma linha de codigo na aplicacao.
resource "datadog_monitor" "api_erro_5xx" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][${var.datadog_ambiente_monitorado}] Taxa de erro 5xx na API acima do aceitavel"
  type = "query alert"

  query = join("", [
    "sum(last_10m):100 * ( ",
    "sum:trace.servlet.request.errors{service:oficina-api,env:${var.datadog_ambiente_monitorado}}.as_count() / ",
    "sum:trace.servlet.request.hits{service:oficina-api,env:${var.datadog_ambiente_monitorado}}.as_count()",
    " ) > 5",
  ])

  message = <<-EOT
    {{#is_alert}}
    {{value}}% das requisicoes da API estao retornando 5xx nos ultimos 10 minutos.
    {{/is_alert}}
    {{#is_warning}}
    Erros 5xx subindo: {{value}}% das requisicoes nos ultimos 10 minutos.
    {{/is_warning}}

    **Impacto:** falha de servidor - o cliente nao consegue concluir a operacao. Diferente de
    4xx, que na oficina e regra de negocio (transicao invalida de OS, cadastro duplicado) e
    NAO gera alerta.

    **Onde olhar:** APM > Error Tracking do `service:oficina-api`; do trace, pule para o log
    pelo `dd.trace_id` (DD_LOGS_INJECTION ja injeta no MDC).${local.datadog_notificacao}
  EOT

  priority = 1

  monitor_thresholds {
    critical = 5
    warning  = 2
  }

  notify_no_data    = false
  renotify_interval = 30
  include_tags      = true

  tags = concat(local.datadog_tags, ["signal:api"])
}

# --- 3. Latencia das APIs -----------------------------------------------------------
#
# Item "latencia das APIs". p95 e nao media: a media esconde justamente a cauda que o
# usuario sente. O alvo e var.datadog_latencia_p95_segundos, com warning na metade.
resource "datadog_monitor" "api_latencia_p95" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][${var.datadog_ambiente_monitorado}] Latencia p95 da API acima do alvo"
  type = "query alert"

  query = "avg(last_10m):p95:trace.servlet.request{service:oficina-api,env:${var.datadog_ambiente_monitorado}} > ${var.datadog_latencia_p95_segundos}"

  message = <<-EOT
    {{#is_alert}}
    O p95 de latencia da API esta em {{value}}s, acima do alvo de ${var.datadog_latencia_p95_segundos}s.
    {{/is_alert}}
    {{#is_warning}}
    Latencia p95 subindo: {{value}}s.
    {{/is_warning}}

    **Impacto:** 5% das requisicoes estao mais lentas que o alvo. Como o readinessProbe tem
    `timeoutSeconds: 3`, latencia sustentada acaba tirando pods do balanceamento e vira
    indisponibilidade.

    **Onde olhar:** no dashboard "Oficina", o widget de endpoints mais lentos separa problema
    de rota (uma so `resource_name` lenta) de problema de recurso (todas lentas juntas -
    conferir CPU/memoria e o painel do RDS).${local.datadog_notificacao}
  EOT

  priority = 3

  monitor_thresholds {
    critical = var.datadog_latencia_p95_segundos
    warning  = var.datadog_latencia_p95_segundos / 2
  }

  notify_no_data = false
  include_tags   = true

  tags = concat(local.datadog_tags, ["signal:api"])
}

# --- 4. Memoria do pod perto do limite ----------------------------------------------
#
# Item "CPU e memoria no Kubernetes". Percentual do LIMITE, nao valor absoluto: 700Mi e
# saudavel num limite de 1Gi e OOMKill iminente num de 768Mi (que e o de producao).
# Aplicacao Java estoura o limite antes de degradar - o container e morto pelo kernel,
# sem aviso e sem stack trace.
resource "datadog_monitor" "pod_memoria" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][${var.datadog_ambiente_monitorado}] Memoria do pod perto do limite"
  type = "query alert"

  query = join("", [
    "avg(last_15m):100 * ( ",
    "avg:kubernetes.memory.usage{kube_namespace:${local.datadog_kube_namespace},kube_deployment:oficina-api} by {pod_name} / ",
    "avg:kubernetes.memory.limits{kube_namespace:${local.datadog_kube_namespace},kube_deployment:oficina-api} by {pod_name}",
    " ) > 90",
  ])

  message = <<-EOT
    {{#is_alert}}
    O pod {{pod_name.name}} esta usando {{value}}% do limite de memoria.
    {{/is_alert}}
    {{#is_warning}}
    Memoria do pod {{pod_name.name}} em {{value}}% do limite.
    {{/is_warning}}

    **Impacto:** ultrapassar o limite e OOMKill imediato pelo kernel - requisicoes em voo se
    perdem e o pod reinicia. Nao ha degradacao gradual.

    **Onde olhar:** o heap segue `-XX:MaxRAMPercentage=75.0`, entao subida sustentada e
    vazamento ou carga real, nao ajuste de JVM. Confira tambem a ResourceQuota do namespace
    antes de aumentar o limite: hml tem teto de 2Gi e prd de 4Gi.${local.datadog_notificacao}
  EOT

  priority = 2

  monitor_thresholds {
    critical = 90
    warning  = 80
  }

  notify_no_data    = false
  renotify_interval = 60
  include_tags      = true

  tags = concat(local.datadog_tags, ["signal:infra"])
}

# --- 5. CPU do pod perto do limite --------------------------------------------------
#
# kubernetes.cpu.usage.total vem em NANOCORES e kubernetes.cpu.limits em cores: sem o
# / 1000000000 a conta da um percentual bilhoes de vezes maior e o monitor dispara sozinho.
resource "datadog_monitor" "pod_cpu" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][${var.datadog_ambiente_monitorado}] CPU do pod perto do limite"
  type = "query alert"

  query = join("", [
    "avg(last_15m):100 * ( ",
    "avg:kubernetes.cpu.usage.total{kube_namespace:${local.datadog_kube_namespace},kube_deployment:oficina-api} by {pod_name} / 1000000000 / ",
    "avg:kubernetes.cpu.limits{kube_namespace:${local.datadog_kube_namespace},kube_deployment:oficina-api} by {pod_name}",
    " ) > 90",
  ])

  message = <<-EOT
    {{#is_alert}}
    O pod {{pod_name.name}} esta consumindo {{value}}% do limite de CPU.
    {{/is_alert}}
    {{#is_warning}}
    CPU do pod {{pod_name.name}} em {{value}}% do limite.
    {{/is_warning}}

    **Impacto:** CPU nao mata o container como a memoria - ele e THROTTLED. O efeito aparece
    como latencia, entao este alerta costuma vir junto do de p95.

    **Onde olhar:** se o HPA ja esta no maximo de replicas, o gargalo e o node group
    (var.node_max_size).${local.datadog_notificacao}
  EOT

  priority = 3

  monitor_thresholds {
    critical = 90
    warning  = 80
  }

  notify_no_data = false
  include_tags   = true

  tags = concat(local.datadog_tags, ["signal:infra"])
}

# --- 6. Healthcheck: replicas prontas abaixo do desejado ----------------------------
#
# Item "healthchecks e uptime", pelo lado de DENTRO do cluster. E o proprio
# readinessProbe (/actuator/health/readiness, que inclui o banco) traduzido em alerta:
# pod que nao responde ao probe sai do balanceamento e deixa de contar como ready.
# Cobre um caso que o teste sintetico externo NAO cobre: com 2 replicas, uma fora do ar
# ainda devolve 200 no NLB, mas a capacidade caiu pela metade.
resource "datadog_monitor" "replicas_prontas" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][${var.datadog_ambiente_monitorado}] Replicas da API abaixo do desejado"
  type = "query alert"

  query = join("", [
    "max(last_5m):",
    "sum:kubernetes_state.deployment.replicas_desired{kube_deployment:oficina-api,kube_namespace:${local.datadog_kube_namespace}} - ",
    "sum:kubernetes_state.deployment.replicas_ready{kube_deployment:oficina-api,kube_namespace:${local.datadog_kube_namespace}}",
    " >= 1",
  ])

  message = <<-EOT
    {{#is_alert}}
    {{value}} replica(s) da API fora do ar ou sem passar no readinessProbe.
    {{/is_alert}}
    {{#is_no_data}}
    Sem dados de kube-state-metrics ha 30 minutos: ou o Datadog Agent caiu, ou o Deployment
    nao existe mais. Nos dois casos a observabilidade do cluster esta cega.
    {{/is_no_data}}

    **Impacto:** capacidade reduzida. O readinessProbe inclui o banco (grupo readiness =
    readinessState,db), entao um RDS inacessivel derruba TODAS as replicas de uma vez.

    **Onde olhar:** `kubectl -n ${local.datadog_kube_namespace} describe pod` para o motivo do
    probe, e o painel de CPU/memoria para descartar OOMKill.${local.datadog_notificacao}
  EOT

  priority = 1

  monitor_thresholds {
    critical = 1
  }

  # Unico monitor com notify_no_data ligado: aqui "sem dados" e sintoma real. Se o agent ou
  # o cluster-agent morrerem, todo o resto simplesmente para de alertar em silencio.
  notify_no_data    = true
  no_data_timeframe = 30
  renotify_interval = 30
  include_tags      = true

  tags = concat(local.datadog_tags, ["signal:infra"])
}

# --- 7. CrashLoopBackOff ------------------------------------------------------------
#
# Complementa o monitor 6: pod em CrashLoop reinicia rapido o bastante para que a contagem
# de replicas prontas oscile e a janela de 5 minutos as vezes nao pegue.
resource "datadog_monitor" "crashloop" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][${var.datadog_ambiente_monitorado}] Container em CrashLoopBackOff"
  type = "query alert"

  query = "max(last_10m):max:kubernetes_state.container.status_report.count.waiting{kube_namespace:${local.datadog_kube_namespace},reason:crashloopbackoff} by {kube_container_name} >= 1"

  message = <<-EOT
    {{#is_alert}}
    O container {{kube_container_name.name}} esta em CrashLoopBackOff.
    {{/is_alert}}

    **Impacto:** o pod nunca fica pronto. Se atingir todas as replicas, a API sai do ar.

    **Onde olhar:** `kubectl -n ${local.datadog_kube_namespace} logs <pod> --previous`.
    Causas tipicas nesta aplicacao: migration do Flyway falhando no boot, secret ausente
    (oficina-db-credentials / oficina-app-secrets) e OOMKill durante a subida - o startupProbe
    da 150s de folga, entao timeout de boot raramente e a causa.${local.datadog_notificacao}
  EOT

  priority = 1

  monitor_thresholds {
    critical = 1
  }

  notify_no_data    = false
  renotify_interval = 30
  include_tags      = true

  tags = concat(local.datadog_tags, ["signal:infra"])
}

# --- 8. Erros nas integracoes -------------------------------------------------------
#
# Item "erros e falhas nas integracoes" pelo lado do ALERTA (o dashboard tem o widget).
# Monitor de LOG, e nao de metrica: as integracoes desta aplicacao sao o Amazon SES e o
# webhook de decisao de orcamento, e nem toda falha delas vira 5xx - o envio de e-mail e
# assincrono (@Async) e o webhook responde antes do processamento terminar.
#
# O filtro por logger cobre os dois modulos que falam com o mundo externo. A dupla
# (status:error OR @log.level:ERROR) e proposital: `status` e o atributo reservado da
# Datadog, `@log.level` e o campo cru do formato ECS emitido pelo Spring Boot 4 - a busca
# funciona tenha ou nao o remapeamento sido aplicado ao indice.
resource "datadog_monitor" "erros_integracao" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][${var.datadog_ambiente_monitorado}] Erros nas integracoes (SES / webhook de orcamento)"
  type = "log alert"

  query = join("", [
    "logs(\"service:oficina-api env:${var.datadog_ambiente_monitorado} ",
    "(status:error OR @log.level:ERROR) ",
    "@log.logger:(br.com.oficina.notificacao.* OR br.com.oficina.orcamento.*)\")",
    ".index(\"*\").rollup(\"count\").last(\"15m\") > 3",
  ])

  message = <<-EOT
    {{#is_alert}}
    {{value}} erros de integracao nos ultimos 15 minutos.
    {{/is_alert}}
    {{#is_warning}}
    Erros de integracao aparecendo: {{value}} nos ultimos 15 minutos.
    {{/is_warning}}

    **Impacto:** e o alerta ANTECEDENTE ao de notificacao definitiva - aqui a falha ainda
    sera reprocessada (ate 5 tentativas). Se este disparar e nada for feito, o proximo a
    disparar e o de "notificacao falhou definitivamente", ai sim com cliente sem aviso.

    **Onde olhar:** o `@correlation_id` do log liga todas as linhas da mesma requisicao,
    inclusive as do envio assincrono - o TaskDecorator de AsyncConfig propaga o MDC para o
    pool de threads.${local.datadog_notificacao}
  EOT

  priority = 2

  monitor_thresholds {
    critical = 3
    warning  = 1
  }

  notify_no_data     = false
  renotify_interval  = 60
  include_tags       = true
  enable_logs_sample = true

  tags = concat(local.datadog_tags, ["signal:integracao"])
}
