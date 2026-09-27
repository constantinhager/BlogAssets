# BlogAssets

Supporting scripts and other assets referenced from my blog posts on
[the-itguy.de](https://the-itguy.de). Each subfolder corresponds to one blog
post and contains the files needed to follow along with it.

## Repository structure

Assets are grouped by blog post, one folder per post:

- [Uploading VM Service Reports to SharePoint with a Managed Identity](<Uploading VM Service Reports to SharePoint with a Managed Identity>) -
  PowerShell scripts that export the Windows services running on a virtual
  machine and upload the report to a SharePoint document library through
  Microsoft Graph, authenticating with a managed identity instead of a
  client secret or certificate.
  - `Set-SharePointPermissionForManagedIdentity.ps1` - one-time setup script
    run by an administrator to grant the managed identity the
    `Sites.Selected` Microsoft Graph permission and a role on the target
    SharePoint site.
  - `Export-ServicesToSharePoint.ps1` - script run on the virtual machine
    itself to collect the service report and upload it to SharePoint.
- [From CSV Upload to Azure SQL - A Passwordless Import Pipeline with PowerShell and Event Grid](<From CSV Upload to Azure SQL - A Passwordless Import Pipeline with PowerShell and Event Grid>) -
  a complete project that imports CSV files uploaded to Blob Storage into
  Azure SQL. Event Grid triggers a PowerShell function on Flex Consumption,
  which upserts the rows through a SQL output binding. All authentication
  uses managed identities and GitHub OIDC, with no keys or passwords.
  - `BlobToSql/`, `build/`, `function/` - the PowerShell function app and its
    build.
  - `infra/` - Terraform for the Azure resources.
  - `database/` - SQL database project, deployed as a dacpac.
  - `scripts/` - one-time GitHub/Azure setup and database publish.
  - `assets/blob-to-sql-infrastructure.svg` - architecture diagram.
  - [`.github/workflows/csv-upload-to-azure-sql.yml`](.github/workflows/csv-upload-to-azure-sql.yml) -
    CI/CD pipeline in the repository root. It only runs on changes to this
    folder.

Workflows must live in `.github/workflows/` at the repository root, where
GitHub does not allow subfolders. Each workflow file is therefore named after
its blog post, and its `paths` filter limits it to that post's folder.

## License

Licensed under the [MIT License](LICENSE).

## See also

- [the-itguy.de](https://the-itguy.de) - the blog these assets accompany
