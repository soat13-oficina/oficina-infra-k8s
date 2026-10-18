# Monitors da Saga, da mensageria e do pagamento (Fase 4, PLANO-FASE-4.md secao 12).
#
# Diferente de datadog-monitores.tf, que vigia cada servico por dentro (5xx, CPU, replicas), estes vigiam o
# que acontece ENTRE os servicos: uma ordem que nao anda, uma mensagem que nao chega, um pagamento que o
# Mercado Pago aprovou e a Saga nao soube. Sao do sistema, nao de um servico - um monitor so cada, agrupado
# por servico/fila quando faz sentido.
#
# As metricas vem do OpenMetrics do Datadog Agent (anotacao ad.datadoghq.com/<servico>.checks de cada
# Deployment) e so existem depois que os servicos sobem com a Fase 4. Nomes e tags: oficina.saga.* e
# oficina.outbox.* no OS; oficina.pagamento.* no Billing; oficina.estoque.* na Execution;
# oficina.mensageria.* nos tres. Valores de tag chegam em MINUSCULAS na Datadog (resultado:falha_compensacao).
#
# Filtro por `ambiente`: tag aplicada pela propria aplicacao (MetricasCommonTagsConfig), a mesma dos
# monitors de negocio do OS.

# --- 1. Mensagem na DLQ -------------------------------------------------------------
#
# Qualquer valor acima de zero e incidente: a DLQ so recebe o que nao tem como ser processado (fora do
# contrato, sem manipulador, ou cinco falhas seguidas). A ordem daquela mensagem NAO anda ate alguem olhar.
resource "datadog_monitor" "dlq_com_mensagem" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][saga] Mensagem na DLQ (${var.datadog_ambiente_monitorado})"
  type = "query alert"

  query = "max(last_5m):max:oficina.mensageria.dlq.mensagens{ambiente:${var.datadog_ambiente_monitorado}} by {service,fila} > 0"

  message = <<-EOT
    {{#is_alert}}
    A DLQ de `{{fila.name}}` ({{service.name}}) tem {{value}} mensagem(ns).

    **Impacto:** a ordem de servico dona da mensagem ficou parada: o comando ou o evento nunca sera
    processado. Compensacao automatica nao ajuda - a Saga espera uma resposta que nao vai chegar.

    **Onde olhar:** o atributo `erro` da mensagem na DLQ (console do SQS, "Poll for messages") diz se foi
    contrato (schema), tipo desconhecido ou excecao repetida. Logs do servico com `@message_id` da mensagem.
    Depois de corrigir a causa, "Start DLQ redrive" devolve as mensagens a fila original.
    {{/is_alert}}
    {{#is_recovery}}
    DLQ de `{{fila.name}}` vazia de novo.
    {{/is_recovery}}${local.datadog_notificacao}
  EOT

  priority = 1

  monitor_thresholds {
    critical = 0
  }

  notify_no_data    = false
  renotify_interval = 30
  include_tags      = true

  tags = concat(local.datadog_tags, ["signal:saga"])
}

# --- 2. Saga presa ------------------------------------------------------------------
#
# oficina.saga.presas conta as Sagas nao finalizadas com o prazo vencido. O agendador as trata em segundos
# (reenvia o comando ou compensa); se o numero continua acima de zero por 10 minutos, o agendador nao esta
# rodando, o outbox travou ou a compensacao esta falhando.
resource "datadog_monitor" "saga_presa" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][saga] Saga com prazo vencido que nao anda (${var.datadog_ambiente_monitorado})"
  type = "query alert"

  query = "min(last_10m):min:oficina.saga.presas{ambiente:${var.datadog_ambiente_monitorado}} > 0"

  message = <<-EOT
    {{#is_alert}}
    {{value}} saga(s) de ordem de servico estao com o prazo vencido ha mais de 10 minutos.

    **Impacto:** ordens paradas num passo (decisao, reserva, pagamento ou confirmacao de compensacao).

    **Onde olhar:** `GET /sagas/{ordemServicoId}` mostra o passo e o historico; o outbox do OS
    (`oficina.outbox.pendentes`) e a DLQ do os-saga-replies dizem se a resposta se perdeu.
    {{/is_alert}}
    {{#is_recovery}}
    Nenhuma saga com prazo vencido.
    {{/is_recovery}}${local.datadog_notificacao}
  EOT

  priority = 2

  monitor_thresholds {
    critical = 0
  }

  notify_no_data    = false
  renotify_interval = 60
  include_tags      = true

  tags = concat(local.datadog_tags, ["signal:saga"])
}

# --- 3. Compensacao esgotada --------------------------------------------------------
#
# FALHA_COMPENSACAO e o unico estado da Saga que exige acao manual: as confirmacoes das compensacoes nao
# chegaram depois de todas as tentativas (estorno nao confirmado, reserva nao liberada).
resource "datadog_monitor" "falha_compensacao" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][saga] Compensacao esgotada: acao manual necessaria (${var.datadog_ambiente_monitorado})"
  type = "query alert"

  query = "sum(last_15m):sum:oficina.saga.finalizadas.count{ambiente:${var.datadog_ambiente_monitorado},resultado:falha_compensacao}.as_count() > 0"

  message = <<-EOT
    {{#is_alert}}
    Uma saga terminou em FALHA_COMPENSACAO.

    **Impacto:** dinheiro ou estoque pode ter ficado para tras - por exemplo um pagamento aprovado sem
    estorno confirmado, ou pecas reservadas para uma ordem cancelada.

    **Onde olhar:** `GET /sagas/{ordemServicoId}`, o ultimo passo registrado diz qual confirmacao faltou;
    conferir o pagamento no Mercado Pago e a reserva na Execution e resolver na mao.
    {{/is_alert}}
    {{#is_recovery}}
    Sem novas falhas de compensacao.
    {{/is_recovery}}${local.datadog_notificacao}
  EOT

  priority = 1

  monitor_thresholds {
    critical = 0
  }

  notify_no_data    = false
  renotify_interval = 120
  include_tags      = true

  tags = concat(local.datadog_tags, ["signal:saga"])
}

# --- 4. Compensacoes acima do normal ------------------------------------------------
#
# Taxa, e nao contagem: poucas ordens compensadas num dia calmo e rotina (cliente recusa, pagamento nao
# sai); metade das ordens compensando e sinal de problema sistemico (Billing recusando tudo, estoque zerado).
# A janela de 1 hora e o piso de 5 ordens evitam alarme com amostra pequena.
resource "datadog_monitor" "compensacoes_acima_do_normal" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][saga] Taxa de compensacao acima do normal (${var.datadog_ambiente_monitorado})"
  type = "query alert"

  query = join("", [
    "sum(last_1h):sum:oficina.saga.compensacoes.count{ambiente:${var.datadog_ambiente_monitorado}}.as_count() / ",
    "(sum:oficina.saga.iniciadas.count{ambiente:${var.datadog_ambiente_monitorado}}.as_count() + 5)",
    " > 0.5",
  ])

  message = <<-EOT
    {{#is_alert}}
    {{value}} das ordens abertas na ultima hora entraram em compensacao.
    {{/is_alert}}
    {{#is_warning}}
    Compensacoes subindo: {{value}} das ordens abertas na ultima hora.
    {{/is_warning}}

    **Impacto:** a maioria das ordens nao chega a execucao. Em geral e uma causa so.

    **Onde olhar:** no dashboard, "Compensacoes por motivo": PAGAMENTO_RECUSADO aponta para o gateway,
    ORCAMENTO_RECUSADO para preco/prazo, FALHA_EXECUCAO para a oficina, reserva falhando para o estoque.${local.datadog_notificacao}
  EOT

  priority = 3

  monitor_thresholds {
    critical = 0.5
    warning  = 0.3
  }

  notify_no_data = false
  include_tags   = true

  tags = concat(local.datadog_tags, ["signal:saga"])
}

# --- 5. Outbox parado ---------------------------------------------------------------
#
# O publicador roda a cada poucos segundos: uma mensagem pendente ha mais de 5 minutos, em todas as
# amostras da janela, significa transporte (SQS) inacessivel, permissao faltando na role ou publicador
# sem a trava. Por servico, porque cada um tem o proprio outbox.
resource "datadog_monitor" "outbox_parado" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][saga] Outbox com mensagem parada ha mais de 5 minutos (${var.datadog_ambiente_monitorado})"
  type = "query alert"

  query = "min(last_5m):min:oficina.outbox.idade.maxima{ambiente:${var.datadog_ambiente_monitorado}} by {service} > 300"

  message = <<-EOT
    {{#is_alert}}
    O outbox de `{{service.name}}` tem mensagem pendente ha {{value}}s.

    **Impacto:** o servico mudou o estado local mas o evento/comando nao saiu: a Saga do outro lado nao
    sabe. E o inicio de uma ordem parada.

    **Onde olhar:** logs do servico com "Falha ao enviar mensagem do outbox" (erro do SQS: permissao,
    fila inexistente, rede) e o gauge `oficina.outbox.pendentes`. Pendente nao some sozinho com o SQS fora.
    {{/is_alert}}
    {{#is_recovery}}
    Outbox de `{{service.name}}` drenado.
    {{/is_recovery}}${local.datadog_notificacao}
  EOT

  priority = 2

  monitor_thresholds {
    critical = 300
    warning  = 120
  }

  notify_no_data    = false
  renotify_interval = 30
  include_tags      = true

  tags = concat(local.datadog_tags, ["signal:saga"])
}

# --- 6. Outbox esgotado -------------------------------------------------------------
#
# Mensagem que gastou as tentativas e nao sera mais enviada: o equivalente a uma DLQ do lado de quem envia,
# e pior que ela porque ninguem a ve na fila. Na Execution o contador vale desde a subida do pod.
resource "datadog_monitor" "outbox_esgotado" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][saga] Mensagem do outbox esgotou as tentativas (${var.datadog_ambiente_monitorado})"
  type = "query alert"

  query = "max(last_15m):max:oficina.outbox.esgotadas{ambiente:${var.datadog_ambiente_monitorado}} by {service} > 0"

  message = <<-EOT
    {{#is_alert}}
    `{{service.name}}` tem {{value}} mensagem(ns) do outbox que esgotaram as tentativas de envio.

    **Impacto:** a mensagem nao sera mais enviada sozinha. A ordem dona dela fica parada ate a Saga
    reenviar o comando (prazo) ou alguem agir.

    **Onde olhar:** logs "Mensagem do outbox esgotou as tentativas" com `messageId` e `tipo`; no OS e no
    Billing a linha segue em `outbox_mensagens` (publicada_em nula, tentativas no maximo); na Execution, o item
    OUTBOX# da tabela execution-controle tem `esgotada = true` e `ultimoErro`.
    {{/is_alert}}
    {{#is_recovery}}
    Sem mensagens esgotadas.
    {{/is_recovery}}${local.datadog_notificacao}
  EOT

  priority = 2

  monitor_thresholds {
    critical = 0
  }

  notify_no_data    = false
  renotify_interval = 60
  include_tags      = true

  tags = concat(local.datadog_tags, ["signal:saga"])
}

# --- 7. Webhook do Mercado Pago recusado --------------------------------------------
#
# O Billing recusa (401) a notificacao cuja assinatura nao confere, ou todas, se o segredo estiver vazio.
# O cliente pode ter pago e a Saga so descobre quando a cobranca expira. Qualquer recusa merece um olhar:
# em operacao normal o Mercado Pago sempre assina corretamente.
resource "datadog_monitor" "webhook_mercadopago_recusado" {
  count = local.datadog_api_habilitada ? 1 : 0

  name = "[oficina][oficina-billing-service] Webhook do Mercado Pago recusado (${var.datadog_ambiente_monitorado})"
  type = "query alert"

  query = "sum(last_15m):sum:oficina.pagamento.webhook.rejeitados.count{ambiente:${var.datadog_ambiente_monitorado}}.as_count() > 0"

  message = <<-EOT
    {{#is_alert}}
    O Billing recusou {{value}} notificacao(oes) do Mercado Pago nos ultimos 15 minutos.

    **Impacto:** um pagamento aprovado pode nao ter chegado a Saga; a ordem fica em AGUARDANDO_PAGAMENTO
    ate a cobranca expirar (o Billing consulta o provedor antes de expirar, o que limita o estrago).

    **Onde olhar:** segredo `oficina/<env>/mercadopago` (campo `webhook_secret` preenchido e igual ao do
    painel do Mercado Pago), relogio do pod (a assinatura tem tolerancia de 5 minutos) e a rota
    `POST /webhooks/mercadopago` do API Gateway, que nao pode ter authorizer.
    {{/is_alert}}
    {{#is_recovery}}
    Webhooks do Mercado Pago sendo aceitos.
    {{/is_recovery}}${local.datadog_notificacao}
  EOT

  priority = 2

  monitor_thresholds {
    critical = 0
  }

  notify_no_data    = false
  renotify_interval = 60
  include_tags      = true

  tags = concat(local.datadog_tags, ["signal:pagamento", "service:oficina-billing-service"])
}
