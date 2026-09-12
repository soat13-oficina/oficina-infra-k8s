# Dashboard da Datadog (ADR 0003).
#
# JSON EM ARQUIVO SEPARADO, e nao widget a widget em HCL. Dois motivos:
#
#   1. E o mesmo formato que a API devolve. Iterar o layout na UI ou pelo MCP durante a
#      demo e trazer o resultado de volta para o repositorio e copiar e colar - com HCL
#      tipado seria uma traducao manual a cada ajuste, e e nessa traducao que o dashboard
#      versionado passa a divergir do que esta no ar.
#   2. Diff legivel. Mover um widget muda uma linha de layout, e nao um bloco inteiro.
#
# O preco e que o Terraform nao valida o conteudo: erro de schema so aparece no apply.
#
# datadog-dashboards/dashboard-oficina.json cobre os tres itens que a tarefa pede em dashboard
# (volume diario de OS, tempo medio por status, erros nas integracoes) e mais latencia,
# CPU/memoria e uptime, para que a demo inteira caiba numa tela so.
resource "datadog_dashboard_json" "oficina" {
  count = local.datadog_api_habilitada ? 1 : 0

  dashboard = templatefile("${path.module}/datadog-dashboards/dashboard-oficina.json", {
    # O widget de SLO referencia o objeto por ID, que so existe depois do apply. E a unica
    # coisa que o JSON nao consegue trazer pronta do repositorio.
    slo_id = datadog_service_level_objective.disponibilidade_api[0].id

    # Marcador da linha de alvo no grafico de latencia: mesma variavel que define o limiar
    # do monitor, para que grafico e alerta nunca discordem.
    alvo_p95 = var.datadog_latencia_p95_segundos
  })
}
