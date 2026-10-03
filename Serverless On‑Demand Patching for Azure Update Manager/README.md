# AzureUpdateManagerAutomation

Drive **Azure Update Manager** through HTTP calls to an **Azure Function** (PowerShell, Flex Consumption).
The functions use plain **ARM REST API** calls with the Function App's **Managed Identity** - no Az module, no secret.
Everything is deployed with **Terraform** and **GitHub Actions** (OIDC).

![Architecture](docs/architecture.png)

## Endpoints

| Endpoint | Method | What it does |
|---|---|---|
| `/api/Start-UpdateAssessment` | POST | "Check for updates" on all machines with a tag (`assessPatches`) |
| `/api/Start-OneTimeUpdate` | POST | One-time update on all machines with a tag (`installPatches`). Excluded KBs come from Azure Table Storage |
| `/api/New-UpdateMaintenanceConfiguration` | POST | Create/update a maintenance configuration (scheduled patching), optional dynamic scope by tag |
| `/api/Get-UpdateMaintenanceConfiguration` | GET/POST | List maintenance configurations incl. dynamic scopes |
| `/api/Get-UpdateManagerMachine` | GET/POST | List all Azure VMs + Arc-enabled servers with their latest assessment |

Parameters go into the JSON body or the query string (lists: JSON array or comma separated).
Auth level: `function` (send `x-functions-key`).

## Exclusion table (`UpdateExclusions`)

| PartitionKey | RowKey | Title | Reason | Enabled | ExpiresOn |
|---|---|---|---|---|---|
| `Global` | `KB5034439` | ... | ... | `true` | optional |
| `Wave1` | `KB890830` | ... | ... | `true` | optional |

`Global` applies to every run. Any other partition applies to machines whose tag value matches it.
`Enabled = false` or a past `ExpiresOn` disables a row without deleting it.

## Repository layout

```
.github/workflows/deploy.yml     plan -> build -> apply -> deploy
docs/architecture.png            architecture picture (docs/architecture.py renders it)
function-app/                    generated with PSModuleDevelopment's AzureFunction template
  build/                         template build (FlexConsumption = $true in build.config.psd1)
  function/                      host.json, profile.ps1, requirements.psd1
  UpdateManagerAutomation/
    functions/httpTrigger/       one file = one HTTP endpoint
    internal/functions/          REST helpers (token, ARM, Resource Graph, Table Storage)
infra/                           Terraform (RG, VNet+NAT, sample VM, storage+table, Flex Function App, custom role)
scripts/
  New-GitHubOidcDeploymentIdentity.ps1   one-time bootstrap: Entra app + federated credentials + tfstate storage + RBAC
  Invoke-UpdateManagerFunction.ps1       test client
```

## Getting started

1. Create the GitHub repository and push this code.
2. Bootstrap (once, as subscription Owner):
   ```powershell
   Connect-AzAccount
   ./scripts/New-GitHubOidcDeploymentIdentity.ps1 -GitHubOrganization <org> -GitHubRepository AzureUpdateManagerAutomation -ConfigureGitHub
   ```
3. Run the workflow (push to `main` or *Run workflow*). It plans, builds `Function.zip`, applies Terraform and deploys the code.
4. Call it:
   ```powershell
   ./scripts/Invoke-UpdateManagerFunction.ps1 -FunctionAppName <name> -ResourceGroupName rg-aum-automation `
       -Endpoint Start-OneTimeUpdate -Parameters @{ TagName = 'UpdateGroup'; TagValue = 'Wave1' }
   ```

## Local build

```powershell
./function-app/build/build.ps1   # creates function-app/Function.zip
```

The workflow builds on `ubuntu-latest`. Flex Consumption runs on Linux, where paths are case-sensitive.
That is why the template folder `function/modules` was renamed to `function/Modules`: the build saves the bundled modules to `Modules`, and the Functions host only loads `<app root>/Modules`.
