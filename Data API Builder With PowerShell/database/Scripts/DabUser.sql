/*
    Database user for the Data API builder managed identity - without Microsoft Graph.

    Why SID + TYPE = E instead of FROM EXTERNAL PROVIDER?
    FROM EXTERNAL PROVIDER resolves the name in Microsoft Entra ID. When a service principal
    (the GitHub Actions identity) runs it, the SQL server's own identity needs Graph read
    permissions or Directory Readers. With an explicit SID the server doesn't look anything up.
    For service principals and managed identities the SID is the client ID as binary(16).

    Why here and not as a model object?
    The SID differs per environment and comes from Terraform. SqlPackage leaves users that are
    not in the model alone (DropObjectsNotInSource = False), so the user survives every publish.
*/

IF N'$(DabIdentityName)' = N'' OR N'$(DabIdentityClientId)' = N''
    THROW 50000, N'Set the SQLCMD variables DabIdentityName and DabIdentityClientId.', 1;

DECLARE @name SYSNAME = N'$(DabIdentityName)';
DECLARE @clientId UNIQUEIDENTIFIER = '$(DabIdentityClientId)';
DECLARE @sid VARBINARY(16) = CONVERT(VARBINARY(16), @clientId);

DECLARE @existingSid VARBINARY(85), @existingType CHAR(1);
SELECT @existingSid = [sid], @existingType = [type]
FROM sys.database_principals
WHERE [name] = @name;

IF @existingSid IS NULL
BEGIN
    DECLARE @cmd NVARCHAR(MAX) =
        N'CREATE USER ' + QUOTENAME(@name) +
        N' WITH SID = ' + CONVERT(NVARCHAR(34), @sid, 1) + N', TYPE = E;';
    EXEC (@cmd);
    PRINT N'Created user ' + @name + N'.';
END
ELSE IF @existingSid <> @sid OR @existingType <> 'E'
BEGIN
    -- Same name, different identity: the managed identity was probably recreated.
    -- Fail loudly instead of silently keeping access for the old one.
    DECLARE @msg NVARCHAR(400) = N'User ' + @name + N' exists with a different SID or type. Drop it and publish again.';
    THROW 50002, @msg, 1;
END;

IF IS_ROLEMEMBER(N'dab_api', @name) = 0
BEGIN
    DECLARE @addMember NVARCHAR(MAX) = N'ALTER ROLE [dab_api] ADD MEMBER ' + QUOTENAME(@name) + N';';
    EXEC (@addMember);
    PRINT N'Added ' + @name + N' to dab_api.';
END;
