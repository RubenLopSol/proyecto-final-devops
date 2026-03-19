output "bucket_name" {
  description = "Nombre del bucket S3 de backups"
  value       = aws_s3_bucket.velero_backups.id
}

output "bucket_arn" {
  description = "ARN del bucket S3 de backups"
  value       = aws_s3_bucket.velero_backups.arn
}

output "velero_role_arn" {
  description = "ARN del IAM Role para Velero — usar en la instalación de Velero con IRSA"
  value       = aws_iam_role.velero.arn
}

output "velero_install_command" {
  description = "Comando de instalación de Velero con el IAM Role generado"
  value       = <<-EOT
    velero install \
      --provider aws \
      --plugins velero/velero-plugin-for-aws:v1.8.0 \
      --bucket ${aws_s3_bucket.velero_backups.id} \
      --backup-location-config region=${var.aws_region} \
      --use-volume-snapshots=false \
      --sa-annotations iam.amazonaws.com/role=${aws_iam_role.velero.arn}
  EOT
}
