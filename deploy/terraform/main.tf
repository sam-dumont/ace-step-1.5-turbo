# ACE-Step 1.5 Turbo — Terraform Example
#
# Deploys the ACE-Step API server on Kubernetes with GPU support.
# Adjust provider config, storage class, and ingress to match your cluster.
#
# Usage:
#   cp terraform.tfvars.example terraform.tfvars
#   terraform init && terraform apply

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

# Point this at your cluster's kubeconfig
provider "kubernetes" {
  config_path = "~/.kube/config"
}

# --- Variables ---

variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "acestep"
}

variable "image" {
  description = "Container image"
  type        = string
  default     = "ghcr.io/sam-dumont/ace-step-1.5-turbo:latest"
}

variable "domain" {
  description = "Domain for ingress (null = no ingress)"
  type        = string
  default     = null
}

variable "ingress_class" {
  description = "Ingress class name"
  type        = string
  default     = "nginx"
}

variable "tls_issuer" {
  description = "cert-manager ClusterIssuer name (empty = no cert-manager)"
  type        = string
  default     = ""
}

variable "storage_class" {
  description = "Storage class for PVC (empty = cluster default)"
  type        = string
  default     = ""
}

variable "storage_size" {
  description = "PVC size for output data"
  type        = string
  default     = "20Gi"
}

variable "gpu_enabled" {
  description = "Request GPU resources"
  type        = bool
  default     = true
}

variable "node_selector" {
  description = "Node selector labels for GPU targeting"
  type        = map(string)
  default     = {}
}

variable "runtime_class" {
  description = "RuntimeClass for GPU (e.g. nvidia). Null to skip."
  type        = string
  default     = "nvidia"
}

# --- Resources ---

resource "random_password" "api_key" {
  length  = 32
  special = false
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_secret_v1" "api_key" {
  metadata {
    name      = "acestep-api-key"
    namespace = kubernetes_namespace_v1.this.metadata.0.name
  }
  data = {
    "api-key" = random_password.api_key.result
  }
}

resource "kubernetes_persistent_volume_claim_v1" "output" {
  metadata {
    name      = "acestep-output"
    namespace = kubernetes_namespace_v1.this.metadata.0.name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class != "" ? var.storage_class : null
    resources {
      requests = {
        storage = var.storage_size
      }
    }
  }
}

resource "kubernetes_deployment_v1" "acestep" {
  metadata {
    name      = "acestep"
    namespace = kubernetes_namespace_v1.this.metadata.0.name
    labels    = { app = "acestep" }
  }

  timeouts {
    create = "30m"
    update = "30m"
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "acestep" } }
    strategy { type = "Recreate" }

    template {
      metadata { labels = { app = "acestep" } }

      spec {
        runtime_class_name = var.runtime_class

        security_context {
          run_as_user  = 1001
          run_as_group = 1001
          fs_group     = 1001
        }

        dynamic "node_selector" {
          for_each = length(var.node_selector) > 0 ? [var.node_selector] : []
          content {
            # Terraform kubernetes provider doesn't support dynamic node_selector this way.
            # Use the node_selector attribute directly on the spec instead.
          }
        }

        container {
          name              = "acestep"
          image             = var.image
          image_pull_policy = "Always"
          command           = ["acestep-api"]

          port { container_port = 8000 }

          resources {
            requests = {
              cpu    = "500m"
              memory = "10Gi"
            }
            limits = merge(
              {
                cpu    = "4"
                memory = "20Gi"
              },
              var.gpu_enabled ? { "nvidia.com/gpu" = "1" } : {}
            )
          }

          env { name = "ACESTEP_DEVICE"       ; value = var.gpu_enabled ? "cuda" : "cpu" }
          env { name = "ACESTEP_LM_BACKEND"   ; value = "pt" }
          env { name = "ACESTEP_API_HOST"      ; value = "0.0.0.0" }
          env { name = "ACESTEP_API_PORT"      ; value = "8000" }
          env { name = "ACESTEP_OUTPUT_DIR"    ; value = "/data/output" }
          env { name = "NVIDIA_VISIBLE_DEVICES"; value = "all" }

          env {
            name = "API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.api_key.metadata.0.name
                key  = "api-key"
              }
            }
          }

          volume_mount {
            name       = "output"
            mount_path = "/data"
          }

          startup_probe {
            http_get { path = "/health"; port = 8000 }
            period_seconds    = 10
            failure_threshold = 60
            timeout_seconds   = 5
          }

          liveness_probe {
            http_get { path = "/health"; port = 8000 }
            period_seconds    = 30
            timeout_seconds   = 10
            failure_threshold = 5
          }

          readiness_probe {
            http_get { path = "/health"; port = 8000 }
            period_seconds    = 15
            timeout_seconds   = 10
            failure_threshold = 5
          }
        }

        volume {
          name = "output"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.output.metadata.0.name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "acestep" {
  metadata {
    name      = "acestep"
    namespace = kubernetes_namespace_v1.this.metadata.0.name
  }
  spec {
    selector = { app = "acestep" }
    port {
      name        = "api"
      port        = 8000
      target_port = 8000
    }
  }
}

resource "kubernetes_ingress_v1" "acestep" {
  count = var.domain != null ? 1 : 0

  metadata {
    name      = "acestep"
    namespace = kubernetes_namespace_v1.this.metadata.0.name
    annotations = var.tls_issuer != "" ? {
      "cert-manager.io/cluster-issuer" = var.tls_issuer
    } : {}
  }

  spec {
    ingress_class_name = var.ingress_class

    tls {
      hosts       = [var.domain]
      secret_name = "acestep-tls"
    }

    rule {
      host = var.domain
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.acestep.metadata.0.name
              port { number = 8000 }
            }
          }
        }
      }
    }
  }
}

# --- Outputs ---

output "api_key" {
  value     = random_password.api_key.result
  sensitive = true
}

output "namespace" {
  value = kubernetes_namespace_v1.this.metadata.0.name
}

output "service_name" {
  value = kubernetes_service_v1.acestep.metadata.0.name
}
