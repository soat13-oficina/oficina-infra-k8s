# ADR 0001 — Separação dos states do Terraform e sentido da dependência

- **Status:** Aceito
- **Data:** 2026-09-02
- **Contexto:** Tech Challenge SOAT 13 — Fase 3

## Contexto

A Fase 2 mantinha VPC, EKS, ECR, RDS e IAM em **um único state** do Terraform
(`infra/aws` do monorepo). A Fase 3 exige quatro repositórios separados, dois
deles de infraestrutura:

- `oficina-infra-k8s` — infraestrutura Kubernetes;
- `oficina-infra-database` — banco de dados gerenciado.

Isso obriga a quebrar o state em dois. O problema é que os recursos são
acoplados: o RDS precisa de `vpc_id`, do *DB subnet group* e do
`node_security_group_id` do EKS para liberar a porta 5432 apenas para os
worker nodes.

## Decisão

1. **A rede (VPC, subnets, NAT, DB subnet group) fica no repositório de
   Kubernetes**, junto do cluster.
2. **A dependência é unidirecional:** `oficina-infra-database` lê os outputs de
   `oficina-infra-k8s` via `terraform_remote_state`, apontando para a mesma
   bucket S3 e a key `oficina/infra-k8s.tfstate`. A plataforma **nunca** lê o
   state do banco.
3. Os outputs de `oficina-infra-k8s` são tratados como **API pública versionada**:
   remover ou renomear um output é uma mudança quebrável, e o arquivo
   `outputs.tf` documenta isso explicitamente.
4. A ordem de provisionamento passa a ser explícita e documentada:
   `infra-k8s` → `infra-database` → `lambda-auth` → `app`.
   A ordem de destruição é a inversa.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| **Quinto repositório só para a rede** | O enunciado fixa quatro repositórios. Além disso, a rede tem exatamente o mesmo ciclo de vida do cluster — separá-la criaria um state a mais sem nenhum ganho de autonomia. |
| **Rede no repositório do banco** | Inverteria a dependência: o cluster tem mais dependentes (aplicação, IRSA, LoadBalancers) e é o componente com ciclo de vida mais longo. Quem tem mais dependentes deve ser a base, não o consumidor. |
| **Duplicar a rede nos dois repos** | Duas VPCs; o RDS deixaria de ser alcançável pelos pods sem *peering*. Inviável. |
| **Descoberta por `data source` com filtro de tag** (`aws_vpc` por `Name`) | Funciona, mas o acoplamento fica implícito e silencioso: um rename de tag quebra o `apply` com erro obscuro em vez de erro de contrato. O `terraform_remote_state` deixa a dependência explícita no código. |

## Consequências

**Positivas**
- Ciclos de vida independentes: mexer no tamanho do RDS não roda `plan` sobre o cluster inteiro (`apply` de ~15 min vira ~2 min).
- Blast radius menor: um `destroy` acidental no repo do banco não leva a rede junto.
- Permissões podem ser segregadas por repositório no futuro (credencial do repo de banco não precisa de permissão sobre EKS).

**Negativas / mitigações**
- **Ordem de apply passa a importar.** Mitigação: documentada no README de cada repositório e validada no pipeline do banco, que falha com mensagem clara se o state da plataforma não existir.
- **`terraform_remote_state` exige leitura da bucket de state.** A credencial do repositório de banco precisa de `s3:GetObject` na key da plataforma.
- **`destroy` da plataforma com o banco de pé deixa recursos órfãos.** Mitigação: aviso explícito no job de destroy e no README.
