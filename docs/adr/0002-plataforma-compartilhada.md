# ADR 0002 — Plataforma compartilhada e segregação de ambientes por namespace

- **Status:** Aceito
- **Data:** 2026-09-02
- **Contexto:** Tech Challenge SOAT 13 — Fase 3

## Contexto

O enunciado exige **deploy automático das branches de homologação e produção**.
Isso implica dois ambientes distintos. A forma canônica em AWS seria dois
conjuntos completos de infraestrutura (duas VPCs, dois clusters EKS, dois RDS),
tipicamente via *workspaces* do Terraform.

O custo do ambiente atual é de aproximadamente **US$ 0,23/hora (~US$ 5,50/dia)**,
dominado pelo control plane do EKS (US$ 0,10/h), pelo NAT Gateway (US$ 0,045/h) e
pelos nodes. Duplicar tudo dobraria esse valor e o tempo de provisionamento
(~15–20 min por ambiente), num projeto acadêmico custeado pelo grupo.

## Decisão

**Plataforma compartilhada, ambientes segregados nas camadas de cima:**

| Camada | Segregação hml × prd |
|---|---|
| Rede (VPC, subnets, NAT) | **Compartilhada** — uma só |
| Cluster EKS | **Compartilhado** — um só |
| ECR | **Compartilhado** — um repositório, tags por commit |
| **Banco de dados (RDS)** | **Separado** — uma instância por ambiente (`terraform workspace` no repo `oficina-infra-database`) |
| **Aplicação (Kubernetes)** | **Separada** — namespaces `oficina-hml` e `oficina-prd`, com Deployment, Service, ConfigMap, Secret e HPA próprios |
| **Lambda + API Gateway** | **Separados** — stages/funções por ambiente |

Consequências para o CI/CD:

- `oficina-infra-k8s` (esta camada) faz `apply` **apenas** na `master`. Com um
  único state, dois branches aplicando concorrentemente disputariam o mesmo
  *lock*; `homologacao` roda `plan`.
- `oficina-infra-database`, `oficina-lambda-auth` e `oficina-app` fazem **deploy
  automático nas duas branches**: `homologacao` → ambiente de homologação,
  `master` → produção. É aí que o requisito do enunciado é cumprido.

O isolamento entre ambientes é garantido por:
- **Namespaces distintos** com `ResourceQuota` e `LimitRange` próprios;
- **Bancos de dados fisicamente distintos** (instâncias RDS separadas), que é
  onde mora o dado e onde um vazamento entre ambientes de fato dói;
- **Secrets e ConfigMaps por namespace** — credenciais de homologação não são
  legíveis a partir de produção sem RBAC explícito.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| **Dois ambientes completos (workspaces em todas as camadas)** | Isolamento real e mais fiel a produção, mas ~US$ 11/dia e 2× o tempo de `apply`. Custo desproporcional ao ganho num projeto de avaliação. |
| **Um único ambiente (só produção)** | Descumpre literalmente o requisito de deploy automático da branch de homologação. |
| **Dois node groups no mesmo cluster, um por ambiente** | Isola compute, mas dobra o custo dos nodes sem isolar o control plane nem a rede — paga-se quase o preço do isolamento real sem obtê-lo. |
| **Um RDS com dois databases lógicos** | Mais barato (~US$ 0,017/h a menos), mas exigiria o provider `postgresql` no Terraform ou um `null_resource` com `psql`, e um incidente de disco/CPU derrubaria os dois ambientes juntos. O delta de custo não justifica. |

## Consequências

**Positivas**
- Custo previsível, próximo ao da Fase 2 (~US$ 6,30/dia com os dois RDS).
- Um só `apply` de plataforma para manter, revisar e demonstrar.
- Provisionamento inicial completo em ~20 min, e não ~40.

**Negativas / mitigações**
- **Ruído entre ambientes (*noisy neighbour*):** um pod de homologação pode consumir CPU do nó que roda produção. Mitigação: `requests`/`limits` obrigatórios nos manifestos e `ResourceQuota` por namespace, com a cota de homologação menor.
- **Falha do control plane derruba os dois ambientes.** Aceito explicitamente: é um ambiente de avaliação, não de produção com SLA.
- **A camada de plataforma não tem "deploy automático de homologação".** Compensado nas outras três camadas; a divergência em relação ao texto do enunciado está registrada aqui e no README, e é deliberada.
