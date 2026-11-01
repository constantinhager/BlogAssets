# The API's identity in Entra ID. DAB validates tokens issued for this app.
#
# The pipeline creates it with Application.ReadWrite.OwnedBy: it can only manage
# applications it owns, so it is listed as owner of the app and the service principal.
# Assigning users to app roles needs AppRoleAssignment.ReadWrite.All - the pipeline doesn't
# get that. scripts/Grant-DabApiRole.ps1 does it, run by an admin.

locals {
  # Well-known first-party client IDs. Pre-authorizing them means Get-AzAccessToken and
  # az account get-access-token can request a token for this API without a consent prompt.
  azure_powershell_client_id = "1950a258-227b-4e31-a9cf-717495945fc2"
  azure_cli_client_id        = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
}

resource "random_uuid" "scope_access" {}
resource "random_uuid" "role_reader" {}
resource "random_uuid" "role_writer" {}

resource "azuread_application" "api" {
  display_name     = "${var.api_display_name} (${local.suffix})"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]

  api {
    # v2 tokens: iss = https://login.microsoftonline.com/<tenant>/v2.0, aud = client ID.
    # DAB's EntraID provider expects exactly that.
    requested_access_token_version = 2

    oauth2_permission_scope {
      id                         = random_uuid.scope_access.result
      value                      = "Data.Access"
      type                       = "User"
      enabled                    = true
      admin_consent_display_name = "Access the meetup data API"
      admin_consent_description  = "Allows the app to call the meetup data API as the signed-in user."
      user_consent_display_name  = "Access the meetup data API"
      user_consent_description   = "Allows the app to call the meetup data API on your behalf."
    }
  }

  # The roles claim. "reader" only opens the door (assignment is required, see below).
  # "writer" maps to the DAB role "writer" - selected with the X-MS-API-ROLE header.
  app_role {
    id                   = random_uuid.role_reader.result
    value                = "reader"
    display_name         = "Reader"
    description          = "Read events and sessions."
    allowed_member_types = ["User", "Application"]
    enabled              = true
  }

  app_role {
    id                   = random_uuid.role_writer.result
    value                = "writer"
    display_name         = "Writer"
    description          = "Create, change and delete events and sessions."
    allowed_member_types = ["User", "Application"]
    enabled              = true
  }

  lifecycle {
    # Managed by azuread_application_identifier_uri - the URI contains the app's own client ID.
    ignore_changes = [identifier_uris]
  }
}

resource "azuread_application_identifier_uri" "api" {
  application_id = azuread_application.api.id
  identifier_uri = "api://${azuread_application.api.client_id}"
}

resource "azuread_service_principal" "api" {
  client_id = azuread_application.api.client_id
  owners    = [data.azuread_client_config.current.object_id]

  # Only users, groups and apps with an app role assignment get a token for this API.
  app_role_assignment_required = true
}

resource "azuread_application_pre_authorized" "azure_powershell" {
  application_id       = azuread_application.api.id
  authorized_client_id = local.azure_powershell_client_id
  permission_ids       = [random_uuid.scope_access.result]
}

resource "azuread_application_pre_authorized" "azure_cli" {
  application_id       = azuread_application.api.id
  authorized_client_id = local.azure_cli_client_id
  permission_ids       = [random_uuid.scope_access.result]
}
