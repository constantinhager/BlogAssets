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

## License

Licensed under the [MIT License](LICENSE).

## See also

- [the-itguy.de](https://the-itguy.de) - the blog these assets accompany
