output "bucket_name" {
  description = "Nombre del bucket S3 creado"
  value       = aws_s3_bucket.velero_backups.id
}

output "bucket_arn" {
  description = "ARN del bucket S3"
  value       = aws_s3_bucket.velero_backups.arn
}

output "velero_iam_user" {
  description = "Usuario IAM creado para Velero"
  value       = aws_iam_user.velero.name
}

output "velero_access_key_id" {
  description = "Access Key ID para Velero (equivale al aws_access_key_id en velero-credentials)"
  value       = aws_iam_access_key.velero.id
}

output "velero_secret_access_key" {
  description = "Secret Access Key para Velero"
  value       = aws_iam_access_key.velero.secret
  sensitive   = true
}
