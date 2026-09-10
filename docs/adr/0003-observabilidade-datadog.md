# ADR 0003 — Observabilidade com Datadog

- **Status:** Aceito
- **Data:** 2026-09-09
- **Contexto:** Tech Challenge SOAT 13 — Fase 3

## Contexto

A tarefa de Monitoramento e Observabilidade pede latência das APIs, CPU/memória
no Kubernetes, healthchecks e uptime, alertas para falhas no processamento de
ordens de serviço, logs estruturados em JSON com correlação entre requisições e
dashboards com volume diário de OS, tempo médio de execução por status
(Diagnóstico, Execução, Finalização) e erros nas integrações. A escolha da
ferramenta é livre entre **Datadog** e **New Relic**.

Três fatos do código pesaram na decisão:

1. `SituacaoOrdemDeServico` já mapeia os status internos para as seis situações
   de negócio (`RECEBIDA`, `DIAGNOSTICO`, `AGUARDANDO_APROVACAO`, `EXECUCAO`,
   `FINALIZADA`, `ENTREGUE`). A taxonomia pedida pelo enunciado já existe.
2. Sete casos de uso já publicavam `StatusOrdemDeServicoAlterado` via
   `ApplicationEventPublisher`. Existe **um** ponto de instrumentação para todo o
   ciclo de vida da OS.
3. O `ENTRYPOINT` do `Dockerfile` é `exec java $JAVA_OPTS -jar app.jar` —
   acrescentar um `-javaagent` é uma variável de ambiente, não uma mudança
   estrutural de imagem.

Também pesou o que **não** existia: nenhum MDC, nenhum correlation id, nenhum
logging estruturado, e `management.endpoints.web.exposure.include: health`.

## Decisão

**Datadog**, com as responsabilidades divididas assim:

| Item da tarefa | Como | Onde |
|---|---|---|
| Latência das APIs | `dd-java-agent` (autoinstrumentação, zero código) | `oficina-app` — `Dockerfile` + `JAVA_OPTS` |
| CPU/memória no Kubernetes | Datadog Agent (DaemonSet) + kube-state-metrics | `oficina-infra-k8s/datadog.tf` |
| Healthcheck e uptime | `/actuator/health/{liveness,readiness}` já existentes + `kubernetes_state.container.ready` | ambos |
| Logs JSON + correlação | Structured logging nativo do Spring Boot 4 (ECS) + `DD_LOGS_INJECTION` + MDC próprio | `oficina-app` |
| Métricas de negócio | `@EventListener` sobre os eventos de domínio | `oficina-app` |
| Dashboards e alertas | Iterados via MCP, exportados para Terraform | `oficina-infra-k8s` |

### Métricas de negócio saem de eventos, não dos casos de uso

`MetricasOrdemServicoListener` e `MetricasNotificacaoListener` são os **únicos**
pontos do código que conhecem Micrometer. Nenhum caso de uso foi tocado para
ganhar métrica — eles só publicam eventos de domínio, como já faziam para
notificar o cliente.

Isso exigiu fechar três lacunas reais:

- **`situacao_alterada_em` (migration V19).** `iniciadaEm` / `finalizadaEm` /
  `entregueEm` não permitem derivar quanto tempo a OS ficou *em Diagnóstico* ou
  *em Execução*, ainda mais porque `finalizadaEm` é escrito por três caminhos
  diferentes (`concluirServico`, `recusarOrcamento`, `finalizar`). A coluna é
  atualizada só quando a **situação** muda — `DIAGNOSTICO_EM_ANDAMENTO →
  DIAGNOSTICO_CONCLUIDO` são dois status dentro de "Diagnóstico" e não reiniciam
  o relógio.
- **`FinalizarOrdemDeServicoService` não publicava evento.** A transição
  `ORCAMENTO_GERADO → OS_FINALIZADA` era invisível — e não só para métrica: o
  cliente também não era notificado dela.
- **Criação de OS não era contável.** `OS_ABERTA` é estado inicial, não
  transição. Contar `RECEBIDA → DIAGNOSTICO` subcontaria toda ordem que nunca
  virou diagnóstico. Daí o evento `OrdemDeServicoCriada`, separado do de
  transição — reaproveitar o de transição dispararia notificação ao cliente na
  criação, comportamento que a aplicação não tem.

### Métricas via OpenMetrics, não via DogStatsD

A aplicação expõe `/actuator/prometheus` e o Datadog Agent o raspa por
autodiscovery (anotação `ad.datadoghq.com/oficina-api.checks` no pod). O motivo é
o cronograma: o trial de 14 dias só é ativado perto da demo, e um formato aberto
mantém as métricas de negócio verificáveis com um `curl` durante todo o
desenvolvimento, sem conta na Datadog.

O check OpenMetrics **exige** um `namespace` e o prepende a tudo que raspa, então
as métricas nascem no código como `os.criadas` e chegam ao Datadog como
`oficina.os.criadas`.

### O actuator sobe numa porta própria em nuvem

`service.yaml` é `type: LoadBalancer` e provisiona um **NLB público**: tudo que
responde na 8080 está na internet. Em hml e prd o management vai para a **8081**,
porta que de propósito **não** consta no `Service`. Probes (kubelet) e o Datadog
Agent falam com o IP do pod diretamente e não dependem do `Service` para
alcançá-la. Localmente nada muda: continua tudo na 8080.

### Alertas: o que não alertar

`RegraDeNegocioException` é 4xx e uso normal da API — alertar nela acordaria
alguém à toa. Os três sinais que valem:

1. `oficina.notificacoes.falhas` — notificação que esgotou as 5 tentativas. É o
   único estado terminal de erro que significa perda real de entrega: falha
   transiente ainda será reprocessada, e "sem e-mail cadastrado" é cadastro
   incompleto, não incidente.
2. 5xx no APM.
3. Erros de SES e do webhook de orçamento.

### Nomes de métrica: mapeamento explícito no check, não convenção

Entre o código e o Datadog o nome muda três vezes, e cada etapa é imposta por uma
ferramenta diferente: o Micrometer troca `.` por `_` e acrescenta sufixo de tipo
(`os.criadas` → `os_criadas_total`; o *timer* vira a summary
`os_tempo_na_situacao_seconds`); o check OpenMetrics v2 exige o counter **sem** `_total` e
devolve tudo com `.count`/`.sum`; e o `namespace` obrigatório prepende `oficina.`.

A lista de `metrics` da anotação passou a usar **mapeamento explícito**
(`{"os_criadas": "os.criadas"}`). Sem ele havia um erro silencioso e um risco:

- a entrada `os_tempo_na_situacao` **não casa** com a família real, que é
  `os_tempo_na_situacao_seconds` — o tempo médio por status, item explícito da tarefa,
  simplesmente não chegaria;
- os demais chegariam como `oficina.os_criadas.count`, e não com o nome de negócio.

Os nomes finais (`oficina.os.criadas.count`, `oficina.os.tempo_na_situacao.sum`, …) foram
**verificados contra a saída real** de `/actuator/prometheus`, com a aplicação rodando e
uma OS transitando de situação — não deduzidos da documentação.

### Um nome de serviço só, em todos os sinais

`spring.application.name` passou de `oficina` para `oficina-api`. Esse valor vai para o
campo `service.name` do log ECS, enquanto APM (`DD_SERVICE`), o label
`tags.datadoghq.com/service` do pod e o `Service` do Kubernetes sempre disseram
`oficina-api`. Divergência ali coloca o log da aplicação sob outro serviço no Datadog e
desfaz a correlação log ↔ trace, que é o item mais visível da entrega.

### Dashboards e monitors como código, com o JSON em arquivo

O dashboard é um `datadog_dashboard_json` que lê `datadog/dashboard-oficina.json`, e não
blocos de widget em HCL. O JSON é o mesmo formato que a API devolve: iterar o layout na UI
durante a demo e trazer o resultado de volta é copiar e colar, enquanto o HCL tipado
exigiria uma tradução manual a cada ajuste — e é nessa tradução que o dashboard versionado
começa a divergir do que está no ar. O preço é que o Terraform não valida o conteúdo: erro
de schema só aparece no `apply`.

Os monitors, esses sim, são recursos tipados: são poucos, mudam pouco e ganham em ser
revisáveis linha a linha no PR. Todas as oito consultas foram validadas pelo
`validate_monitor_definition` do MCP da Datadog antes do commit.

### Monitors em um ambiente só; dashboard nos dois

Os monitors cobrem `var.datadog_ambiente_monitorado` (padrão `prd`). Duplicá-los em
homologação dobraria a quantidade de alertas para vigiar um ambiente onde ninguém está de
plantão e que nem sempre está no ar. O dashboard alterna entre ambientes por *template
variable*.

São **dois** seletores, e não um, porque as fontes não compartilham tag: métrica de
negócio traz `ambiente` (aplicada pela própria aplicação, garantida mesmo se o agent não
ler os labels do pod), o APM traz `env` (de `DD_ENV`) e o kube-state-metrics só conhece
`kube_namespace`. Um seletor único dependeria de tagging que nenhuma das três garante.

### Uptime externo aponta para `/v3/api-docs`, não para o actuator

O plano original previa o teste sintético contra `/actuator/health/liveness`. Não é
possível: em nuvem o actuator responde na 8081, porta deliberadamente ausente do `Service`
— um teste sintético roda de fora e só alcança a 8080. `/v3/api-docs` é o endpoint público
(`permitAll`) mais barato que ainda exercita Tomcat e Spring MVC de ponta a ponta.

A saúde do banco não fica descoberta: ela continua no `readinessProbe` (grupo `readiness =
readinessState,db`), e sua queda aparece no monitor de réplicas prontas. Os dois sinais
respondem a perguntas diferentes — "o pod acha que está bem" e "um cliente na internet
consegue usar a API" — e alimentam juntos o SLO de disponibilidade.

### O stack é opt-in por chave

Sem `var.datadog_api_key` o `helm_release` não é criado (`count = 0`) e o `apply`
segue idêntico ao de hoje. O free tier cobre métricas de infra mas **não** cobre
APM nem logs, que são o miolo da entrega; o caminho é o trial de 14 dias, ativado
perto da demo.

São **duas** chaves, e não uma. A API key identifica a organização e serve para *enviar*
telemetria — é tudo que o Agent precisa. Dashboard, monitor, teste sintético e SLO são
**escrita na API de configuração** e exigem também uma *application key*, que identifica o
usuário que assina a chamada. Daí dois gates independentes: só a API key sobe o agent sem
criar monitor nenhum; `var.datadog_app_key` liga o resto.

O `provider "datadog"` recebe `validate = false` enquanto as chaves estão vazias. Sem isso
ele tenta autenticar em todo `plan` — inclusive no `terraform validate` do CI, que roda sem
secret — e falha antes de olhar para recursos que estão todos em `count = 0`.

O teste sintético tem um terceiro gate, `var.app_public_url`: o NLB é criado pelo `Service`
do Kubernetes, **fora** do Terraform, e só existe depois do primeiro deploy da aplicação.

### `t3.small` → `t3.medium`

O DaemonSet roda em **todo** node, e o agent vive no namespace dele — **fora** das
`ResourceQuota` de `oficina-hml` e `oficina-prd`. Não há cota que o segure. Um
`t3.small` tem ~1,5 GiB alocáveis; produção já pede 2×384Mi e agent +
trace-agent pedem ~288Mi. Não cabe. Além do `t3.medium`, todos os containers do
chart recebem `requests`/`limits` explícitos, e process-agent, orchestrator
explorer e network monitoring ficam desligados.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| **New Relic** | Equivalente em capacidade e com free tier mais generoso (100 GB/mês, incluindo APM). Perde no ferramental: o MCP oficial da Datadog fecha o ciclo de autoria — validar definição de monitor, consultar métricas e locations, e exportar o JSON do dashboard pronto para o Terraform — sem sair do editor. |
| **Widgets em HCL tipado** (`datadog_dashboard`) | Ganharia validação de schema no `terraform validate`. Perde no round-trip: o dashboard iterado na UI volta como JSON, e traduzir isso para blocos HCL a cada ajuste é exatamente onde o versionado passa a divergir do que está no ar. |
| **Monitors espelhados em hml** | Dobraria a quantidade de alertas para vigiar um ambiente sem plantão e frequentemente fora do ar. Homologação continua coberta pelo dashboard, que alterna por template variable. |
| **Teste sintético contra `/actuator/health/liveness`** | Era o plano original e é impossível: o actuator responde na 8081, fora do `Service`, e um teste sintético roda de fora do cluster. Publicar o actuator no NLB para viabilizá-lo exporia volume de OS e latências na internet. |
| **Um seletor de ambiente só no dashboard** | Exigiria que métrica de negócio, APM e kube-state-metrics compartilhassem uma tag. Só `ambiente` e `env` são garantidos, e nenhum dos dois alcança o kube-state-metrics. |
| **Prometheus + Grafana auto-hospedados** | Sem custo de licença, mas exige provisionar, dimensionar e manter o próprio armazenamento de séries num cluster de 2 nodes — e não entrega APM nem correlação log↔trace sem somar Tempo e Loki. Vira uma segunda entrega. |
| **DogStatsD em vez de OpenMetrics** | Mais idiomático na Datadog e melhor em distribuições e percentis, mas acopla o desenvolvimento à existência de um agent: sem conta ativa, nenhuma métrica de negócio seria verificável até a véspera da demo. |
| **Tabela de histórico de status** (em vez da coluna `situacao_alterada_em`) | Permitiria analytics no próprio banco, mas é uma tabela nova, com escrita a cada transição, para responder a uma pergunta que o dashboard já responde. |
| **Injetar `MeterRegistry` nos casos de uso** | Menos arquivos, mas espalha Micrometer por sete serviços e mistura observabilidade com regra de negócio — justamente onde o código já tinha um ponto único de extensão. |
| **Deixar o actuator na 8080 com `permitAll`** | Um passo a menos, mas publicaria volume de OS, latências e nomes de endpoints num NLB aberto à internet. |

## Consequências

**Positivas**

- Um `@EventListener` cobre o ciclo de vida inteiro da OS; nenhum caso de uso
  conhece observabilidade.
- Duas lacunas de negócio (Finalização sem evento, criação não contável) foram
  corrigidas de verdade — a de Finalização também restaura a notificação ao
  cliente.
- Métricas verificáveis localmente com `curl localhost:8080/actuator/prometheus`,
  sem conta na Datadog.
- `terraform apply` sem chave continua funcionando exatamente como antes.

**Negativas / mitigações**

- **Custo de nodes sobe** (`t3.small` → `t3.medium`, ~2× o preço dos nodes). É o
  preço de rodar um agent por node; mitigado desligando o que não é usado.
- **A troca de `instance_types` recria o managed node group.** `instance_types` é
  `ForceNew` no provider AWS: o apply que muda `t3.small` → `t3.medium` destrói e
  recria o node group, com reagendamento de todos os pods e alguns minutos de
  indisponibilidade. Não é um efeito colateral escondido — é o custo de caber o
  agent, e deve ser feito numa janela combinada, não junto de um deploy de
  aplicação.
- **Cluster novo exige dois `apply`.** O provider `helm` se configura a partir de
  `module.eks`; num apply que cria o cluster do zero esses valores ainda são
  desconhecidos no plan, e o provider falha ao inicializar o client
  (`Kubernetes cluster unreachable`) **antes de criar qualquer coisa** — não é um
  erro do qual se saia repetindo a execução. O interruptor é
  `var.datadog_enabled` (input `datadog: off` no `workflow_dispatch`), e não a
  presença da chave: com `DATADOG_API_KEY` como secret de **organização** ela já
  chega preenchida no bootstrap e não serviria de gate. Com o cluster no ar — o
  estado normal — um apply basta. Detalhado em `datadog.tf`.
- **Janela de 14 dias.** Ativar o trial perto da entrega, e não no início do
  desenvolvimento; o Terraform fica versionado e inerte até lá.
- **Nomes de métrica divergem entre Prometheus e Datadog**
  (`os_criadas_total` × `oficina.os.criadas.count`), efeito do `namespace` obrigatório do
  check somado ao sufixo de tipo. O mapeamento explícito na anotação torna o resultado
  determinístico, mas é mais uma tradução para manter: **acrescentar métrica de negócio
  exige acrescentar a entrada correspondente lá**, senão ela não é raspada. Registrado no
  Javadoc dos listeners, na anotação do pod e em `oficina-app/docs/observabilidade.md`.

- **O JSON do dashboard não é validado pelo Terraform.** Erro de schema aparece só no
  `apply`, e não no `validate` do CI. É o custo do round-trip com a UI.

- **As consultas de APM e de Kubernetes só puderam ser validadas quanto à sintaxe.** O
  MCP confirma que a definição do monitor é válida, não que a métrica existe — a
  organização ainda não recebeu telemetria. A conferência de que `trace.servlet.request` e
  `kubernetes.*` estão populados fica para o primeiro dia de trial, e está na checklist de
  ativação do README.
- **Uma porta a mais para manter.** `MANAGEMENT_SERVER_PORT` fica no
  `deployment.yaml` base, e não no `app.env` do overlay, para que não seja
  removida sem que se veja que os probes dependem dela.
