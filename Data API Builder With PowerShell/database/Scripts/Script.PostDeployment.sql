/*
    Post-deployment script. SqlPackage runs it after every publish, so everything
    in here must be idempotent.

    SQLCMD variables (set by scripts/Publish-DabDatabase.ps1):
      $(DabIdentityName)      display name of the user-assigned managed identity
      $(DabIdentityClientId)  its client (application) ID - NOT the principal/object ID
*/

:r .\DabUser.sql
GO

:r .\Seed.sql
GO
