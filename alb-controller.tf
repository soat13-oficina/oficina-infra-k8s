# AWS Load Balancer Controller: transforma os Ingress dos servicos em UM ALB por ambiente (ADR 0008 do
# oficina-app). Cada servico publica um Ingress com alb.ingress.kubernetes.io/group.name: oficina-<env>
# e o controller junta os tres no mesmo balanceador (IngressGroup).
#
# Por que nao ingress-nginx: o projeto foi aposentado pelo Kubernetes (sem correcoes de seguranca desde
# marco de 2026). E por que nao um NLB por servico: seriam seis balanceadores e seis hostnames a copiar.
#
# O ALB e os security groups que o controller cria NAO sao do Terraform. Antes do destroy da plataforma e
# preciso apagar os Ingress (o job de destroy faz isso) - senao o destroy da VPC trava em dependencias orfas.
#
# Versao do chart e politica IAM sao FIXADAS JUNTAS (ver var.alb_controller_chart_version).

data "aws_iam_policy_document" "alb_controller_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    # So o ServiceAccount do controller, em kube-system.
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# Politica oficial do projeto (kubernetes-sigs/aws-load-balancer-controller, docs/install/iam_policy.json),
# copiada sem alteracao da tag que casa com o chart.
resource "aws_iam_policy" "alb_controller" {
  name        = "${var.cluster_name}-aws-load-balancer-controller"
  description = "Politica oficial do AWS Load Balancer Controller (ALB, target groups, security groups)."
  policy      = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_trust.json
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

resource "helm_release" "alb_controller" {
  count = var.alb_controller_enabled ? 1 : 0

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_chart_version
  namespace  = "kube-system"

  # O node group precisa existir antes; a role e a politica, antes do primeiro reconcile.
  depends_on = [module.eks, aws_iam_role_policy_attachment.alb_controller]

  values = [
    yamlencode({
      clusterName = module.eks.cluster_name
      region      = var.aws_region
      vpcId       = module.vpc.vpc_id

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
        }
      }

      # Uma replica basta no desafio (o padrao sao duas) e o cluster e apertado: a eleicao de lider
      # volta a ter sentido se alguem subir replicaCount.
      replicaCount = 1

      resources = {
        requests = { cpu = "50m", memory = "100Mi" }
        limits   = { memory = "200Mi" }
      }
    })
  ]
}
