# Observabilidade: Datadog Agent no cluster (ADR 0003).
#
# OPT-IN POR CHAVE. Sem var.datadog_api_key nada aqui e criado - o count zera e o
# terraform apply segue como antes. E deliberado: o free tier da Datadog cobre metricas
# de infra, mas NAO cobre APM nem logs, que sao o miolo desta entrega. O caminho e o trial
# de 14 dias, ativado perto da demo; ate la o codigo fica versionado e inerte, em vez de
# queimar dias de trial durante o desenvolvimento.
#
#   terraform apply -var="datadog_api_key=$DD_API_KEY"

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    # Token do EKS expira em ~15 min: resolvido a cada execucao em vez de guardado no state.
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

resource "helm_release" "datadog" {
  count = var.datadog_api_key == "" ? 0 : 1

  name             = "datadog"
  repository       = "https://helm.datadoghq.com"
  chart            = "datadog"
  version          = var.datadog_chart_version
  namespace        = "datadog"
  create_namespace = true

  # O node group precisa existir antes: o DaemonSet nao tem onde rodar num cluster
  # sem worker nodes e o release ficaria preso no timeout.
  depends_on = [module.eks]

  values = [
    yamlencode({
      datadog = {
        clusterName = var.cluster_name
        site        = var.datadog_site

        # Logs: coleta o stdout de todos os containers. E o que traz o JSON estruturado
        # da aplicacao (LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs) com dd.trace_id no MDC,
        # fechando a correlacao log <-> trace.
        logs = {
          enabled             = true
          containerCollectAll = true
        }

        # APM. portEnabled abre a 8126 no host: e assim que o dd-java-agent do pod
        # alcanca o agent, via DD_AGENT_HOST=status.hostIP (k8s/base/deployment.yaml
        # no repo da aplicacao).
        apm = {
          portEnabled = true
        }

        # CPU/memoria de pods e nodes.
        kubeStateMetricsEnabled = true

        # --- Desligado de proposito -------------------------------------------------
        # Nada disso e usado nesta entrega e tudo custa RAM num cluster de 2 nodes.
        # O agent roda no namespace dele, FORA das ResourceQuota de oficina-hml e
        # oficina-prd, entao nao ha cota que o segure: o unico freio e este.
        processAgent = {
          enabled             = false
          containerCollection = false
        }
        orchestratorExplorer = {
          enabled = false
        }
        networkMonitoring = {
          enabled = false
        }
      }

      # Limites explicitos no DaemonSet. Sem eles o agent e Burstable e disputa memoria
      # com a aplicacao no mesmo node.
      agents = {
        containers = {
          agent = {
            resources = {
              requests = { cpu = "100m", memory = "192Mi" }
              limits   = { cpu = "300m", memory = "384Mi" }
            }
          }
          traceAgent = {
            resources = {
              requests = { cpu = "50m", memory = "96Mi" }
              limits   = { cpu = "200m", memory = "256Mi" }
            }
          }
        }
      }

      clusterAgent = {
        enabled  = true
        replicas = 1
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "300m", memory = "256Mi" }
        }
        # Custom metrics para HPA: o HPA da aplicacao usa metrics-server (CPU), nao a
        # Datadog. Ligar isso so acrescentaria carga.
        metricsProvider = {
          enabled = false
        }
      }
    }),

    # A chave vive num values SEPARADO de proposito: como var.datadog_api_key e sensitive,
    # o Terraform redige o elemento inteiro da lista que a contem. Mantendo-a isolada, o
    # restante dos values continua legivel no plan.
    yamlencode({
      datadog = {
        apiKey = var.datadog_api_key
      }
    })
  ]
}
