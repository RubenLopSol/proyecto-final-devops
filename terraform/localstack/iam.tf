# =============================================================================
# IAM para Velero — versión LocalStack
# En AWS real se usaría IRSA (IAM Role + OIDC de EKS).
# En LocalStack se usa IAM User + Access Key, que es equivalente funcionalmente.
# =============================================================================

resource "aws_iam_policy" "velero_s3" {
  name        = "velero-s3-policy"
  description = "Permisos mínimos para que Velero gestione backups en S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "VeleroS3BucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = "${aws_s3_bucket.velero_backups.arn}/*"
      },
      {
        Sid    = "VeleroS3ListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.velero_backups.arn
      }
    ]
  })
}

resource "aws_iam_user" "velero" {
  name = "velero-backup-user"

  tags = {
    Project   = "openpanel"
    ManagedBy = "terraform"
  }
}

resource "aws_iam_user_policy_attachment" "velero_s3" {
  user       = aws_iam_user.velero.name
  policy_arn = aws_iam_policy.velero_s3.arn
}

resource "aws_iam_access_key" "velero" {
  user = aws_iam_user.velero.name
}
