resource "aws_ecr_repository" "app" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  # Permite terraform destroy mesmo com imagens no repositorio (demo).
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "keep_last_20" {
  repository = aws_ecr_repository.app.name

  # 20 (e nao 10, como na fase anterior): com dois ambientes publicando no
  # mesmo repositorio, 10 imagens cobriam poucos deploys e havia risco de
  # expirar a tag em uso em producao enquanto homologacao empurrava versoes.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Mantem apenas as 20 imagens mais recentes"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
