variable "bucket_name" {
  description = "Nombre del bucket S3 para los backups de Velero"
  type        = string
  default     = "openpanel-velero-backups"
}

variable "aws_region" {
  description = "Región de AWS donde se crearán los recursos"
  type        = string
  default     = "us-east-1"
}

variable "retention_days" {
  description = "Días de retención de los objetos en S3 antes de ser eliminados automáticamente"
  type        = number
  default     = 30
}

variable "velero_namespace" {
  description = "Namespace de Kubernetes donde está instalado Velero"
  type        = string
  default     = "velero"
}

variable "velero_service_account" {
  description = "Nombre del ServiceAccount de Velero en Kubernetes"
  type        = string
  default     = "velero"
}

variable "eks_cluster_name" {
  description = "Nombre del clúster EKS (usado para el OIDC provider de IRSA)"
  type        = string
  default     = "openpanel"
}
