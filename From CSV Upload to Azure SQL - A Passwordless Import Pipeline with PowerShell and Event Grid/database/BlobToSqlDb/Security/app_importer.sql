-- Least-privilege role for the Function App's SQL identity.
-- MERGE (SQL output binding) needs SELECT, INSERT and UPDATE on the target table.
-- The member (the managed identity) is added in Scripts\PostDeployment.sql,
-- because its name and client ID differ per environment.
CREATE ROLE [app_importer] AUTHORIZATION [dbo];
GO

GRANT SELECT, INSERT, UPDATE ON OBJECT::[dbo].[ImportedRecord] TO [app_importer];
GO
