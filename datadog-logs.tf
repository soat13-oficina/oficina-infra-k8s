# Pipeline de logs dos servicos (ADR 0003).
#
# Os servicos logam em JSON no formato ECS (Elastic Common Schema; LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs
# nos deployments). O ECS guarda o nivel em log.level e a excecao em error.type / error.stack_trace,
# nomes que a Datadog NAO le por padrao (ela procura status/level e error.kind/error.stack). Sem este
# pipeline todo log chega como info, inclusive os ERROR: o filtro status:error do Log Explorer volta
# vazio na demo e o Error Tracking nao agrupa as excecoes.
#
# Precisa da permissao logs_write_pipelines na application key (DATADOG_APP_KEY), alem das de
# dashboard/monitor/synthetic/SLO. Chave criada sem escopo herda as permissoes do usuario (admin cobre).
#
# Por que nao ha datadog_logs_index aqui: o volume e cortado na ORIGEM - nivel de log nos servicos
# (logging.level no application.yml) e coleta restrita aos namespaces da aplicacao (datadog.tf). O que
# chega ao indice main ja e so o que interessa; exclusion filter nele so esconderia o que foi enviado.
# Alem disso o indice main ja nasce com a organizacao e o provider nao o cria nem o remove: gerencia-lo
# exigiria um bloco import so para isso.
resource "datadog_logs_custom_pipeline" "servicos" {
  count = local.datadog_api_habilitada ? 1 : 0

  name       = "[oficina] Servicos Spring Boot (ECS)"
  is_enabled = true

  filter {
    query = "service:(${join(" OR ", var.servicos)})"
  }

  processor {
    status_remapper {
      name       = "Nivel do log (log.level) -> status"
      is_enabled = true
      sources    = ["log.level"]
    }
  }

  processor {
    attribute_remapper {
      name                 = "Tipo da excecao (error.type) -> error.kind"
      is_enabled           = true
      sources              = ["error.type"]
      source_type          = "attribute"
      target               = "error.kind"
      target_type          = "attribute"
      preserve_source      = false
      override_on_conflict = false
    }
  }

  processor {
    attribute_remapper {
      name                 = "Stack trace (error.stack_trace) -> error.stack"
      is_enabled           = true
      sources              = ["error.stack_trace"]
      source_type          = "attribute"
      target               = "error.stack"
      target_type          = "attribute"
      preserve_source      = false
      override_on_conflict = false
    }
  }
}
