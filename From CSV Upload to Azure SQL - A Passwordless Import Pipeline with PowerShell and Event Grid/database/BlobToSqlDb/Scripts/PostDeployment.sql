/*
Post-deployment script. Runs after every publish, so it must be idempotent.

Creates the database user for the Function App's user-assigned managed identity and
adds it to [app_importer]. WITH SID/TYPE creates the user without a Microsoft Graph
lookup, so a service principal can run this without the SQL server needing Directory Readers.

SqlCmd variables (set by sqlpackage /v:):
  IdentityName      name of the user-assigned managed identity
  IdentityClientId  its client ID
*/
IF N'$(IdentityName)' = N'' OR N'$(IdentityClientId)' = N''
    THROW 50000, N'SqlCmd variables IdentityName and IdentityClientId are required.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE [name] = N'$(IdentityName)')
BEGIN
    DECLARE @clientId UNIQUEIDENTIFIER = N'$(IdentityClientId)';
    DECLARE @sid NVARCHAR (MAX) = CONVERT (VARCHAR (MAX), CONVERT (VARBINARY (16), @clientId), 1);
    DECLARE @cmd NVARCHAR (MAX) = N'CREATE USER ' + QUOTENAME(N'$(IdentityName)') + N' WITH SID = ' + @sid + N', TYPE = E;';
    EXEC (@cmd);
    PRINT N'Created user $(IdentityName).';
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members AS rm
    JOIN sys.database_principals AS r ON r.principal_id = rm.role_principal_id
    JOIN sys.database_principals AS m ON m.principal_id = rm.member_principal_id
    WHERE r.[name] = N'app_importer' AND m.[name] = N'$(IdentityName)')
BEGIN
    ALTER ROLE [app_importer] ADD MEMBER [$(IdentityName)];
    PRINT N'Added $(IdentityName) to app_importer.';
END;
GO

-- Earlier versions of this project used db_datareader/db_datawriter. Remove those memberships.
IF IS_ROLEMEMBER(N'db_datawriter', N'$(IdentityName)') = 1
    ALTER ROLE [db_datawriter] DROP MEMBER [$(IdentityName)];
IF IS_ROLEMEMBER(N'db_datareader', N'$(IdentityName)') = 1
    ALTER ROLE [db_datareader] DROP MEMBER [$(IdentityName)];
GO
