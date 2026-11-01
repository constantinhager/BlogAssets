-- DAB gets exactly what the API exposes: the schema app, nothing else.
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE ON SCHEMA::[app] TO [dab_api];
GO

-- DAB reads table, key and foreign key metadata at startup.
GRANT VIEW DEFINITION ON SCHEMA::[app] TO [dab_api];
GO
