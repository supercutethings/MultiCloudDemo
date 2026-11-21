variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "cluster_name" {
  description = "Globally unique within the account/region; also used for autoscaler discovery tags."
  type        = string
}

variable "kubernetes_version" {
  description = "Pin the minor version. Upgrades are a decision, not a Tuesday surprise."
  type        = string
  default     = "1.30"
}

variable "private_subnet_ids" {
  description = "Private subnets across at least three AZs; the control plane ENIs live here."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Keep the API endpoint public but CIDR-restricted, or false for a fully private cluster."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "Who may reach the public API endpoint. Tighten to your office/VPN egress."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_log_types" {
  description = "All five control-plane log types: api, audit, authenticator, controllerManager, scheduler."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t4g.medium"]
}

variable "node_min_size" {
  description = "Keep at one node per AZ so a zone loss cannot take the whole pool."
  type        = number
  default     = 3
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  description = "The ceiling for a traffic spike. Also a hard cap on the bill."
  type        = number
  default     = 12
}

variable "enable_spot_pool" {
  description = "Extra tainted Spot pool for interruptible work."
  type        = bool
  default     = false
}

variable "spot_instance_types" {
  type    = list(string)
  default = ["t4g.medium", "t3.medium", "t3a.medium"]
}

variable "spot_desired_size" {
  type    = number
  default = 1
}

variable "spot_max_size" {
  type    = number
  default = 6
}

variable "secret_arns" {
  description = "Secrets the external-secrets controller may read; everything else is denied."
  type        = list(string)
  default     = []
}

variable "kms_decrypt_key_arns" {
  description = "KMS keys needed to decrypt those secrets."
  type        = list(string)
  default     = []
}

variable "irsa_roles" {
  description = "Service accounts that receive an IRSA role, keyed by role name."
  type = map(object({
    namespace       = string
    service_account = string
  }))

  default = {
    ebs-csi = {
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
    }
    cluster-autoscaler = {
      namespace       = "kube-system"
      service_account = "cluster-autoscaler"
    }
    alb-controller = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
    external-secrets = {
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
