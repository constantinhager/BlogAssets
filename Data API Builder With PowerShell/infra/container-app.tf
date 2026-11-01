resource "azurerm_container_app_environment" "this" {
  name                       = local.names.environment
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  logs_destination           = "log-analytics" # azurerm 5.x: required to use log_analytics_workspace_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = var.tags
}

locals {
  # No password, no key: Microsoft.Data.SqlClient gets a token for the user-assigned
  # managed identity whose client ID is in "User Id".
  dab_connection_string = join(";", [
    "Server=tcp:${azurerm_mssql_server.this.fully_qualified_domain_name},1433",
    "Database=${azurerm_mssql_database.this.name}",
    "Authentication=Active Directory Managed Identity",
    "User Id=${azurerm_user_assigned_identity.dab.client_id}",
    "Encrypt=True",
    "TrustServerCertificate=False",
    "Connect Timeout=30",
  ])
}

resource "azurerm_container_app" "dab" {
  name                         = local.names.container_app
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.dab.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.dab.id
  }

  ingress {
    external_enabled           = true
    target_port                = 5000
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0
    max_replicas = 2

    http_scale_rule {
      name                = "http"
      concurrent_requests = "20"
    }

    container {
      name   = "dab"
      image  = var.bootstrap_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "ASPNETCORE_HTTP_PORTS"
        value = "5000"
      }

      # Plain values, no secrets - none of them is confidential.
      env {
        name  = "DAB_CONNECTION_STRING"
        value = local.dab_connection_string
      }

      env {
        name  = "DAB_JWT_AUDIENCE"
        value = azuread_application.api.client_id
      }

      env {
        name  = "DAB_JWT_ISSUER"
        value = "https://login.microsoftonline.com/${local.tenant_id}/v2.0"
      }

      # "/" is DAB's anonymous basic health endpoint. It answers as soon as the process runs,
      # before the metadata is loaded (other paths return 503 until then).
      startup_probe {
        transport               = "HTTP"
        port                    = 5000
        path                    = "/"
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 30
      }

      liveness_probe {
        transport        = "HTTP"
        port             = 5000
        path             = "/"
        interval_seconds = 30
        timeout          = 5
      }
    }
  }

  lifecycle {
    # The pipeline deploys the image (az containerapp update --image). Terraform owns everything else.
    ignore_changes = [template[0].container[0].image]
  }

  tags = var.tags

  depends_on = [azurerm_role_assignment.dab_acr_pull]
}
