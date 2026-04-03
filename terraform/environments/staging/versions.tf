terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # No remote backend for staging — local state is intentional.
  # Staging runs on Minikube with LocalStack emulating AWS locally.
  # State stays on the developer's machine and is gitignored.
  # For production remote state management see ../prod/versions.tf.
}
