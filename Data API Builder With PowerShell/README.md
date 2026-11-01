# Data API Builder with PowerShell

Sample for the blog post *Azure SQL as a REST and GraphQL API - Data API builder, PowerShell and not a single secret* on [the-itguy.de](https://the-itguy.de).

Data API builder (DAB) 2.1.5 runs in Azure Container Apps and exposes a small Azure SQL database (S0) as REST and GraphQL. The database schema is an SDK-style SQL database project, built with `dotnet build` and deployed with SqlPackage. Nothing in this sample uses a secret:

| Who | To what | How |
|---|---|---|
| GitHub Actions | Azure, Entra ID, ACR, Azure SQL (SqlPackage `/AccessToken`) | Federated credential (OIDC) |
| DAB container | Azure Container Registry | User-assigned managed identity (AcrPull) |
| DAB container | Azure SQL | Same managed identity, `Authentication=Active Directory Managed Identity` |
| PowerShell | DAB | Entra ID access token (`Get-AzAccessToken`), app roles in the `roles` claim |

```
├── .github/workflows/data-api-builder.yml   # validate + build dacpac + plan -> apply -> database -> container
├── dab/                                     # Dockerfile + dab-config.json
├── database/                                # SQL database project (Microsoft.Build.Sql) -> .dacpac
├── docs/architecture.png
├── infra/                                   # Terraform (azurerm 5.x, azuread 3.x)
└── scripts/
    ├── New-DabGitHubOidcIdentity.ps1        # one-time bootstrap
    ├── Publish-DabDatabase.ps1              # SqlPackage publish with an Entra token
    ├── Grant-DabApiRole.ps1                 # assign 'reader' / 'writer' (admin)
    ├── Test-DabApi.ps1                      # the PowerShell client
    └── Remove-DabDeployment.ps1             # cleanup
```

## Database project

```powershell
dotnet build ./database/MeetupDb.sqlproj --configuration Release   # -> database/bin/Release/MeetupDb.dacpac
dotnet tool install --global microsoft.sqlpackage
```

## Quick start

```powershell
# 1. Bootstrap (once, as an admin)
Connect-AzAccount -Tenant <tenant-id> -Subscription <subscription-id>
./scripts/New-DabGitHubOidcIdentity.ps1 -GitHubOrganization <org> -GitHubRepository <repo> -ConfigureGitHub

# 2. Push to main - the pipeline deploys everything

# 3. Give yourself access (as an admin)
./scripts/Grant-DabApiRole.ps1 -ApiClientId <api_client_id> -Role writer -UserPrincipalName you@contoso.com

# 4. Call the API
Connect-AzAccount -Tenant <tenant-id>
./scripts/Test-DabApi.ps1 -ApiUrl <api_url> -ApiClientId <api_client_id> -IncludeWrite
```

The workflow expects the sample in the folder `Data API Builder with PowerShell`. If it's the root of your repository, set `PROJECT_DIR: .` and adjust the `paths` filters.
