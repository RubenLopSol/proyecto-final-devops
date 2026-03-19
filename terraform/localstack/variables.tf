variable "bucket_name" {
  description = "Nombre del bucket S3 para los backups de Velero"
  type        = string
  default     = "openpanel-velero-backups"
}

variable "aws_region" {
  description = "Región de AWS (LocalStack)"
  type        = string
  default     = "us-east-1"
}

variable "retention_days" {
  description = "Días de retención de los backups"
  type        = number
  default     = 30
}
