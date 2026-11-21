# Contract tests.
#
# infra/contracts/README.md promises that every cloud exposes the same four concepts:
# an internal URL, a public URL, a queryable log destination, and a workload identity.
# The native names differ per provider (internal_url / app_urls / urls, log_group_name /
# log_analytics_workspace_id / ...), so these tests assert the *behaviour* of the mapping
# rather than a name: an internal service must be reachable over http, the public one over
# https, every app must get its own identity, and every app must have a log destination.
#
# The providers are mocked, so this runs with no cloud credentials and in a few seconds.
# It is the test that keeps the contract table honest: rename an output, or stop creating
# one identity per app, and the build goes red instead of the documentation going stale.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      name = "eu-west-1"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/showcase-dev-gateway-task"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      name = "/ecs/showcase-dev/gateway"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/showcase-dev-gateway-tg/0123456789abcdef"
    }
  }

  mock_resource "aws_ecs_service" {
    defaults = {
      name = "showcase-dev-gateway"
    }
  }

  # The provider validates the shape of every ARN it is handed, so a randomly generated
  # mock string fails at apply. These defaults are the minimum that makes the mock
  # realistic: the module passes them straight back into other resources.
  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:eu-west-1:123456789012:task-definition/showcase-dev-gateway:1"
    }
  }

  mock_resource "aws_service_discovery_service" {
    defaults = {
      arn = "arn:aws:servicediscovery:eu-west-1:123456789012:service/srv-0123456789abcdef"
    }
  }
}

mock_provider "azurerm" {
  mock_resource "azurerm_container_app" {
    defaults = {
      # The module reads the FQDN the platform assigned, so the mock has to have one.
      ingress = { fqdn = "showcase-dev-gateway.internal.azurecontainerapps.io" }
    }
  }

  mock_resource "azurerm_container_app_environment" {
    defaults = {
      id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-showcase-dev/providers/Microsoft.App/managedEnvironments/showcase-dev-cae"
      default_domain    = "mock.azurecontainerapps.io"
      static_ip_address = "203.0.113.10"
    }
  }

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-showcase-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mock"
      principal_id = "00000000-0000-0000-0000-000000000001"
    }
  }

  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-showcase-dev/providers/Microsoft.OperationalInsights/workspaces/showcase-dev-logs"
    }
  }
}

mock_provider "google" {
  mock_resource "google_cloud_run_v2_service" {
    defaults = {
      name = "mock-service"
      uri  = "https://mock-service-abc123-ew.a.run.app"
    }
  }
}

# --- AWS -------------------------------------------------------------------------------

run "aws_service_satisfies_the_contract" {
  command = apply

  module {
    source = "../../infra/modules/aws/service"
  }

  variables {
    name                             = "gateway"
    name_prefix                      = "showcase-dev"
    cluster_arn                      = "arn:aws:ecs:eu-west-1:123456789012:cluster/showcase-dev"
    cluster_name                     = "showcase-dev"
    image                            = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/showcase-dev/gateway:1.0.0"
    private_subnet_ids               = ["subnet-0a", "subnet-0b"]
    security_group_ids               = ["sg-0a"]
    execution_role_arn               = "arn:aws:iam::123456789012:role/showcase-dev-execution"
    create_target_group              = true
    vpc_id                           = "vpc-0a"
    alb_listener_arn                 = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:listener/app/showcase/0123/4567"
    service_discovery_namespace_id   = "ns-0a"
    service_discovery_namespace_name = "showcase.local"
    environment_variables            = { ENVIRONMENT = "dev" }
  }

  assert {
    condition     = output.internal_url == "http://gateway.showcase.local:8000"
    error_message = "The contract's internal URL must be the Cloud Map name other services call."
  }

  assert {
    condition     = output.log_group_name != null && output.log_group_name != ""
    error_message = "The contract's log destination (log_group_name) is missing."
  }

  assert {
    condition     = output.task_role_arn != null && startswith(output.task_role_arn, "arn:aws:iam::")
    error_message = "The contract's workload identity (task_role_arn) is missing."
  }

  assert {
    condition     = output.target_group_arn != null
    error_message = "A public service must expose a target group so the ALB can reach it."
  }
}

# --- Azure -----------------------------------------------------------------------------

run "azure_container_apps_satisfies_the_contract" {
  command = apply

  module {
    source = "../../infra/modules/azure/container_apps"
  }

  variables {
    project                  = "showcase"
    environment              = "dev"
    resource_group_name      = "rg-showcase-dev"
    infrastructure_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-showcase-dev/providers/Microsoft.Network/virtualNetworks/vnet-showcase-dev/subnets/snet-apps"
    registry_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-showcase-dev/providers/Microsoft.ContainerRegistry/registries/showcasedev"
    registry_login_server    = "showcasedev.azurecr.io"
    key_vault_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-showcase-dev/providers/Microsoft.KeyVault/vaults/showcase-dev-kv"

    apps = {
      auth = {
        image        = "showcasedev.azurecr.io/auth:1.0.0"
        cpu          = 0.5
        memory       = "1Gi"
        min_replicas = 0
        max_replicas = 3
        external     = false
        target_port  = 8000
        env          = {}
        secrets      = {}
        upstreams    = {}
      }
      gateway = {
        image        = "showcasedev.azurecr.io/gateway:1.0.0"
        cpu          = 0.5
        memory       = "1Gi"
        min_replicas = 1
        max_replicas = 10
        external     = true
        target_port  = 8000
        env          = {}
        secrets      = {}
        upstreams    = { AUTH_SERVICE_URL = "auth" }
      }
    }
  }

  assert {
    condition     = length(output.app_urls) == 2
    error_message = "Every app must expose a URL, internal or public."
  }

  assert {
    condition     = startswith(output.app_urls["gateway"], "https://")
    error_message = "The public app must be reachable over HTTPS: platform ingress terminates TLS."
  }

  assert {
    condition     = startswith(output.app_urls["auth"], "http://")
    error_message = "An internal app must not be exposed over HTTPS from outside the environment."
  }

  assert {
    condition     = length(output.identity_ids) == 2
    error_message = "The contract requires one workload identity per app, not one per environment."
  }

  assert {
    condition     = output.log_analytics_workspace_id != null
    error_message = "The contract's log destination is missing."
  }
}

# --- GCP -------------------------------------------------------------------------------

run "gcp_cloud_run_satisfies_the_contract" {
  command = apply

  module {
    source = "../../infra/modules/gcp/cloud_run"
  }

  variables {
    project          = "showcase-demo"
    region           = "europe-west1"
    connector_id     = "projects/showcase-demo/locations/europe-west1/connectors/showcase-dev"
    internal_callers = ["serviceAccount:sa-gateway@showcase-demo.iam.gserviceaccount.com"]

    services = {
      auth = {
        image           = "europe-west1-docker.pkg.dev/showcase-demo/services/auth:1.0.0"
        cpu             = 0.5
        memory          = "512Mi"
        min_instances   = 0
        max_instances   = 3
        port            = 8000
        public          = false
        concurrency     = 80
        service_account = "sa-auth@showcase-demo.iam.gserviceaccount.com"
        env             = {}
        secret_env      = {}
        upstreams       = {}
      }
      gateway = {
        image           = "europe-west1-docker.pkg.dev/showcase-demo/services/gateway:1.0.0"
        cpu             = 0.5
        memory          = "512Mi"
        min_instances   = 1
        max_instances   = 10
        port            = 8000
        public          = true
        concurrency     = 80
        service_account = "sa-gateway@showcase-demo.iam.gserviceaccount.com"
        env             = {}
        secret_env      = {}
        upstreams       = { AUTH_SERVICE_URL = "auth" }
      }
    }
  }

  assert {
    condition     = length(output.urls) == 2
    error_message = "Every service must expose a URI, internal or public."
  }

  assert {
    condition     = can(regex("^https://", output.urls["gateway"]))
    error_message = "The gateway must be reachable over the platform's managed HTTPS endpoint."
  }

  assert {
    condition     = can(regex("^https://", output.urls["auth"]))
    error_message = "Cloud Run serves every revision over https, including the internal one; the URI must be a URL, not a hostname."
  }

  assert {
    condition     = length(output.service_names) == 2
    error_message = "Every service must report its resource name for IAM and log queries."
  }
}
