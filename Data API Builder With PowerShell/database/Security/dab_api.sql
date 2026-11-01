-- The role of the Data API builder identity. The user itself is created in the
-- post-deployment script, because its SID comes from a deployment variable.
CREATE ROLE [dab_api]
    AUTHORIZATION [dbo];
