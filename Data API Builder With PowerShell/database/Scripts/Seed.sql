/*
    Sample data. Runs only when app.Events is empty.
    Dates are relative to the deployment, so there are always upcoming events.
    All names and addresses are fictional.
*/

IF NOT EXISTS (SELECT 1 FROM [app].[Events])
BEGIN
    DECLARE @now DATETIME2(0) = DATEADD(HOUR, 18, CAST(CAST(SYSUTCDATETIME() AS DATE) AS DATETIME2(0)));

    INSERT INTO [app].[Events] ([Title], [EventDate], [Location], [IsOnline], [MaxAttendees])
    VALUES (N'PowerShell Meetup - Secretless Azure',    DATEADD(DAY, -30, @now), N'Altötting',       0, 60),
           (N'PowerShell Meetup - Data APIs',           DATEADD(DAY,  14, @now), N'Burghausen',      0, 60),
           (N'Online Session - Terraform and OIDC',     DATEADD(DAY,  28, @now), N'Microsoft Teams', 1, NULL),
           (N'PowerShell Meetup - Dev Containers',      DATEADD(DAY,  56, @now), N'Mühldorf am Inn', 0, 50),
           (N'Online Session - Entra ID for Scripters', DATEADD(DAY, 120, @now), N'Microsoft Teams', 1, NULL);

    INSERT INTO [app].[Sessions] ([EventId], [Title], [Speaker], [SpeakerEmail], [Level], [DurationMinutes])
    SELECT e.[EventId], s.[Title], s.[Speaker], s.[SpeakerEmail], s.[Level], s.[DurationMinutes]
    FROM (VALUES
            (N'PowerShell Meetup - Secretless Azure',    N'Managed identities everywhere',            N'Erika Musterfrau', N'erika@example.com', 200, 45),
            (N'PowerShell Meetup - Secretless Azure',    N'Federated credentials explained',          N'Max Mustermann',   N'max@example.com',   300, 45),
            (N'PowerShell Meetup - Data APIs',           N'Data API builder in 45 minutes',           N'Max Mustermann',   N'max@example.com',   200, 45),
            (N'PowerShell Meetup - Data APIs',           N'REST and GraphQL from PowerShell',         N'Erika Musterfrau', N'erika@example.com', 300, 45),
            (N'PowerShell Meetup - Data APIs',           N'Lightning talk: Invoke-RestMethod tricks', N'Jane Doe',         N'jane@example.com',  100, 15),
            (N'Online Session - Terraform and OIDC',     N'GitHub Actions without secrets',           N'Jane Doe',         N'jane@example.com',  300, 60),
            (N'PowerShell Meetup - Dev Containers',      N'Your PowerShell toolbox in a container',   N'John Doe',         N'john@example.com',  200, 45),
            (N'Online Session - Entra ID for Scripters', N'App roles, scopes and tokens',             N'Erika Musterfrau', N'erika@example.com', 400, 60)
         ) AS s ([EventTitle], [Title], [Speaker], [SpeakerEmail], [Level], [DurationMinutes])
    JOIN [app].[Events] AS e ON e.[Title] = s.[EventTitle];

    PRINT N'Inserted sample data.';
END;
