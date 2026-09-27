# Progress

- 2026-09-25: Initialized Memory Bank and started documenting missing parameter help for New-GitHubDeploymentIdentity.ps1.
- 2026-09-25: Completed parameter help coverage for New-GitHubDeploymentIdentity.ps1 and moved the script help block ahead of #Requires.
- 2026-09-25: Added comment-based help and structured helper-function param blocks in New-GitHubDeploymentIdentity.ps1, and made Add-RoleAssignmentIfMissing an advanced function with ShouldProcess support.
- 2026-09-25: Moved the helper-function help blocks inside the functions in New-GitHubDeploymentIdentity.ps1 to match the preferred local PowerShell style.
- 2026-09-25: Investigated infra/main.tf; no static Terraform errors were present locally, but Terraform is not installed in this environment and the likely runtime risk is Flex host storage access via system-assigned identity before RBAC propagation.
- 2026-09-25: Added infra/blob-to-sql-infrastructure.svg as a repository-specific infrastructure diagram image derived from the Terraform, workflow, and README architecture.
- 2026-09-25: Rebuilt infra/blob-to-sql-infrastructure.svg with embedded official Azure Architecture Icons (V23) as <symbol> defs, a numbered data-path layout, and fixed text overflow and oversized arrowheads.
- 2026-09-25: Completed parameter help for scripts/Publish-Database.ps1 (all nine parameters) and moved its help block ahead of #Requires.
- 2026-09-25: Project copied into the BlogAssets repository as the folder for the blog post "From CSV Upload to Azure SQL - A Passwordless Import Pipeline with PowerShell and Event Grid"; the diagram moved to assets/. The GitHub workflow does not run from this subfolder.
- 2026-09-25: Moved the workflow to BlogAssets/.github/workflows/csv-upload-to-azure-sql.yml (paths filter + working-directory on this folder, environment csv-upload-to-azure-sql); setup script default -Environment changed to match; README embeds assets/blob-to-sql-infrastructure.svg.
