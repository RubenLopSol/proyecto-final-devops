# =============================================================================
# IAM Role y Policy para Velero (permisos mínimos sobre el bucket de backups)
# =============================================================================

# Obtener el OIDC provider del clúster EKS para IRSA
data "aws_eks_cluster" "openpanel" {
  name = var.eks_cluster_name
}

data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.openpanel.identity[0].oidc[0].issuer
}

# Policy document: permite a Velero operar sobre el bucket S3
data "aws_iam_policy_document" "velero_s3" {
  statement {
    sid    = "VeleroS3BucketAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]

    resources = ["${aws_s3_bucket.velero_backups.arn}/*"]
  }

  statement {
    sid    = "VeleroS3ListBucket"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]

    resources = [aws_s3_bucket.velero_backups.arn]
  }
}

# Trust policy: solo el ServiceAccount de Velero en EKS puede asumir este role (IRSA)
data "aws_iam_policy_document" "velero_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.velero_namespace}:${var.velero_service_account}"]
    }
  }
}

resource "aws_iam_role" "velero" {
  name               = "velero-${var.eks_cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.velero_assume_role.json

  tags = {
    Project   = "openpanel"
    ManagedBy = "terraform"
  }
}

resource "aws_iam_policy" "velero_s3" {
  name        = "velero-s3-${var.eks_cluster_name}"
  description = "Permisos mínimos para que Velero gestione backups en S3"
  policy      = data.aws_iam_policy_document.velero_s3.json
}

resource "aws_iam_role_policy_attachment" "velero_s3" {
  role       = aws_iam_role.velero.name
  policy_arn = aws_iam_policy.velero_s3.arn
}
