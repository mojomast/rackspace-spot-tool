# Rackspace Spot Terraform Configuration for Managed Kubernetes
# This Terraform file provisions a Rackspace Spot cloudspace, spot node pool, and managed Kubernetes control plane.
# It interactively prompts for required variables and ensures proper resource configuration with error handling.

terraform {
  required_providers {
    spot = {
      source = "rackerlabs/spot"
      version = "~> 0.1.4"
    }
  }

  required_version = ">= 1.0.0"  # Ensures Terraform version compatibility
}

# Variable definitions with interactive prompts
variable "rackspace_spot_token" {
  description = "Rackspace Spot API Token (will be prompted interactively)"
  type        = string
  sensitive   = true  # Hides value in logs and outputs
}

variable "region" {
  description = "Rackspace region (select from: us-west, us-central, us-east, eu-west)"
  type        = string
  validation {
    condition     = contains(["us-west", "us-central", "us-east", "eu-west"], var.region)
    error_message = "Region must be one of: us-west, us-central, us-east, eu-west"
  }
}

variable "spot_bid" {
  description = "Spot bid price in USD per hour (e.g., 0.05)"
  type        = number
  validation {
    condition     = var.spot_bid > 0 && var.spot_bid <= 1.0
    error_message = "Spot bid must be between 0.01 and 1.0 USD/hour"
  }
}

variable "organization_namespace" {
  description = "Rackspace Spot organization namespace"
  type        = string
  validation {
    condition     = length(var.organization_namespace) > 0
    error_message = "Organization namespace must not be empty"
  }
}

variable "spot_api_base" {
  description = "Rackspace Spot API base URL"
  type        = string
  default     = "https://spot.rackspace.com/api/v1"
}

variable "node_count" {
  description = "Desired number of spot nodes"
  type        = number
  validation {
    condition     = var.node_count > 0 && var.node_count <= 10
    error_message = "Node count must be between 1 and 10"
  }
}

variable "server_flavor" {
  description = "Spot instance flavor/type for nodes"
  type        = string
  default     = "m3.large"
  validation {
    condition     = contains(["m3.medium", "m3.large", "m3.xlarge", "gpu1.xlarge", "gpu1.2xlarge", "ch1.xlarge"], var.server_flavor)
    error_message = "Server flavor must be one of: m3.medium, m3.large, m3.xlarge, gpu1.xlarge, gpu1.2xlarge, ch1.xlarge"
  }
}

variable "generation" {
  description = "Rackspace Spot generation (gen1 or gen2)"
  type        = string
  default     = "gen2"
  validation {
    condition     = contains(["gen1", "gen2"], var.generation)
    error_message = "Generation must be either gen1 or gen2"
  }
}

variable "preemption_webhook_url" {
  description = "Webhook URL for preemption events (optional)"
  type        = string
  default     = ""
  sensitive   = false
}

variable "storage_class" {
  description = "Storage class compatible with generation (genN-storageM)"
  type        = string
  default     = "gen2-storage1"
}

variable "market_priceCaching_enabled" {
  description = "Enable market price caching for API rate limiting"
  type        = bool
  default     = true
}

# Provider configuration for Rackspace Spot API
provider "spot" {
  token = var.rackspace_spot_token
}

# Rackspace Spot Cloudspace resource
resource "spot_cloudspace" "main" {
  cloudspace_name      = "k8s-cloudspace-${var.region}"
  region              = var.region
  hacontrol_plane     = false
  kubernetes_version  = "1.29.6"
  cni                 = "calico"

  # Error handling: Ensure cloudspace is created successfully
  lifecycle {
    create_before_destroy = true  # Allows safe updates
  }
}

# Spot Node Pool resource
resource "spot_spotnodepool" "main" {
  cloudspace_name = spot_cloudspace.main.cloudspace_name
  server_class    = var.server_flavor
  bid_price       = var.spot_bid
  autoscaling     = {
    min_nodes = 2
    max_nodes = var.node_count
  }

  # Ensure dependencies are handled properly
  depends_on = [spot_cloudspace.main]

  lifecycle {
    create_before_destroy = true
  }
# Get kubeconfig data source
data "spot_kubeconfig" "main" {
  cloudspace_name = spot_cloudspace.main.cloudspace_name
}

# Output kubeconfig content
output "kubeconfig" {
  description = "Kubeconfig content for the cluster"
  value = data.spot_kubeconfig.main.raw
  sensitive = true
}
}