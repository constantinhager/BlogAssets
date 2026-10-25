# Automatic Credential Rotation for Entra ID Apps

An Azure Function (PowerShell, scaffolded with the PSModuleDevelopment `AzureFunction` template) that

- checks the client secrets and certificates of all app registrations once a day,
- writes one row per app and credential type into a **renewal state table** (Azure Table Storage),
- reports by mail which ones expire soon - **it renews nothing on its own**,
- renews a secret or certificate only when an admin sets its **RenewalState** in the table to **Renewable**,
- stores the new credential in Azure Key Vault (`app-<appId>-secret`, `app-<appId>-cert`),
- copies the public part of existing certificates to Key Vault (`app-<appId>-pub-<thumbprint>`).

No secret anywhere. Every Graph call - home tenant and customer tenants - goes through one multi-tenant app registration (the "rotation app"). It has no secret: its federated identity credential trusts the user-assigned managed identity of the Function App. The managed identity itself only talks to Key Vault and the state table. GitHub Actions deploys with OIDC.

Blog post: [docs/jekyll-post-entra-credential-rotation-en.md](docs/jekyll-post-entra-credential-rotation-en.md)

![Architecture](docs/architecture.png)

## Functions

| Function | Trigger | What it does |
|---|---|---|
| `Invoke-AppCredentialCheck` | Timer, daily 05:00 UTC | Check all apps, update the state table, mail the report - renews nothing |
| `Invoke-AppCredentialRenewalQueue` | Timer, every 15 minutes | Renew every row with RenewalState = Renewable, write the result back |
| `Get-AppCredentialReport` | HTTP GET, function key | Read-only report of all credentials with decision and RenewalState |

## The renewal state table

Table `CredentialRenewals` in the Function App's storage account. One row per app and credential type:
`PartitionKey` = tenant ID, `RowKey` = `<appId>_<Secret|Certificate|OtherKey>`.

| Column | Written by | Meaning |
|---|---|---|
| `DisplayName`, `AppId`, `CredentialType`, `ExpiresOn` | check | The credential (newest one per app and type) |
| `CheckResult`, `Reason` | check | `Ok`, `ApprovalRequired`, `Excluded`, `Stale`, `Unsupported` |
| **`RenewalState`** | **you** / check / queue | see below |
| `Force` | you | `true` renews apps with the exclude tag too |
| `Comment` | you | Free text, e.g. change number |
| `RenewalStartedOn`, `RenewedOn`, `NewExpiresOn`, `VaultObject`, `RenewalMessage` | queue | Result of the renewal |

| RenewalState | Set by | Meaning |
|---|---|---|
| `None` | check | Nothing to do |
| `Pending` | check | Expires within the threshold, waits for you |
| **`Renewable`** | **you** | Approved - renewed within 15 minutes |
| `InProgress` | queue | Being renewed (back to `Failed` if interrupted for more than 60 minutes) |
| `Renewed` | queue | Done, see `NewExpiresOn` |
| `Failed` | queue | See `RenewalMessage`; set `Renewable` again to retry |
| `Declined` | you | Don't renew, no reminders |

Edit the rows in the Azure portal (storage account -> Storage browser -> Tables), in Azure Storage Explorer, or with `scripts/Set-SecretRotationState.ps1`. Values are case-insensitive; unknown values are reported in the daily mail and left alone.

## Layout

```
function-app/   PSModuleDevelopment AzureFunction template - module SecretRotation, build, offline tests
infra/          Terraform (azurerm 5.x): identity, Key Vault, Flex Consumption Function App, monitoring
scripts/        bootstrap, rotation app, Exchange scope, state + report clients, import, cleanup
docs/           blog post and architecture diagram (SVG/PNG + generator)
```

The workflow `.github/workflows/entra-credential-rotation.yml` belongs in the root of the repository.

## Rollout

1. `Connect-AzAccount; ./scripts/New-GitHubOidcDeploymentIdentity.ps1 -GitHubOrganization <org> -GitHubRepository <repo> -ConfigureGitHub`
2. Rotation app, step 1 (Global Admin / Privileged Role Admin): `$app = ./scripts/New-SecretRotationApp.ps1 -HomeTenantId <tenant>` - creates the app and consents in the home tenant.
3. Create the Entra ID group that will approve renewals and may import existing secrets into Key Vault with `./scripts/New-SecretRotationGroup.ps1 -DisplayName <group name> -Owner <owner> -tfvarsPath <path to infra/production.tfvars>`
4. Copy `infra/production.tfvars.example` to `infra/production.tfvars`, set `rotation_app_id = $app.RotationAppId`, push.
5. Rotation app, step 2, right after the deployment: `./scripts/New-SecretRotationApp.ps1 -HomeTenantId <tenant> -ManagedIdentityPrincipalId <output from github action>` - adds the federated identity credential.
6. In a **new** PowerShell session (Az.Storage from step 1 loads an older `Microsoft.OData.Core` that ExchangeOnlineManagement can't use): `./scripts/Set-SecretRotationMailScope.ps1 -Organization <tenant>.onmicrosoft.com -SenderAddress <mailbox> -RotationAppId <RotationAppId> -RotationServicePrincipalId <HomeServicePrincipalId> -CreateSharedMailbox` - take the IDs from `$app` of step 2.
7. Customer tenants: an admin of each tenant opens `$app.CustomerConsentUrl` (with the tenant ID), then add the tenant to `customer_tenant_ids`. The URL needs the reply URL that step 2 registers (`https://entra.microsoft.com/` by default) - for an app created before, run step 2 again to add it, otherwise the consent fails with AADSTS500113.
8. Tag apps that someone else takes care of with `SecretRotation:Exclude`.

## Daily use

The mail lists every credential that waits for approval with its table row. Approve one by setting `RenewalState` to `Renewable` - in the portal, or:

```powershell
./scripts/Set-SecretRotationState.ps1 -StorageAccountName <account> -TenantId <tenant> -AppId <app id> -CredentialType Secret -State Renewable -Comment 'Change 4711'
```

Look at everything that expires within 60 days:

```powershell
./scripts/Invoke-SecretRotationReport.ps1 -FunctionAppName <name> -ResourceGroupName <rg> -State Expiring -ThresholdDays 60
```

## App settings

| Setting | Default | Meaning |
|---|---|---|
| `SR_HOME_TENANT_ID` | - | Tenant of the managed identity |
| `SR_MANAGED_IDENTITY_CLIENT_ID` | - | Client ID of the user-assigned identity |
| `SR_ROTATION_APP_ID` | - (required) | Client ID of the multi-tenant rotation app - all Graph calls use it |
| `SR_CUSTOMER_TENANT_IDS` | empty | Customer tenants in addition to the home tenant |
| `SR_KEYVAULT_NAME` | - | Key Vault for new credentials |
| `SR_STATE_STORAGE_ACCOUNT` | - (required) | Storage account of the renewal state table |
| `SR_STATE_TABLE` | `CredentialRenewals` | Name of the renewal state table |
| `SR_THRESHOLD_DAYS` | `30` | Report as `ApprovalRequired` when the newest credential expires within this many days |
| `SR_EXPIRED_GRACE_DAYS` | `7` | Longer expired = `Stale` |
| `SR_SECRET_VALIDITY_DAYS` | `180` | Lifetime of new secrets |
| `SR_CERT_VALIDITY_MONTHS` | `12` | Lifetime of new certificates |
| `SR_CERT_EXPORTABLE` | `true` | Private key exportable from Key Vault |
| `SR_EXCLUDE_TAG` | `SecretRotation:Exclude` | App tag: only reported; renewal needs `Force = true` in the row |
| `SR_BACKUP_PUBLIC_CERTS` | `true` | Copy public certificates to Key Vault |
| `SR_MAIL_SENDER` / `SR_MAIL_RECIPIENTS` | empty | Mail report |

## Tests

```powershell
./function-app/tests/Test-SecretRotation.ps1
```

Offline - Graph, Key Vault and Table Storage are replaced with an in-memory fake.

## Cleanup

```powershell
./scripts/Remove-SecretRotationDeployment.ps1 -ResourceGroupName <rg> -RotationAppId <app id> -Organization <tenant>.onmicrosoft.com -WhatIf
```

The Key Vault is soft-deleted, not purged.
