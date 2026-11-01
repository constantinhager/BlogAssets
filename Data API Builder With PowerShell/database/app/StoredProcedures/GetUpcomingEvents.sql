-- Upcoming events with their number of sessions.
-- Exposed by Data API builder as GET /api/UpcomingEvents and GraphQL executeUpcomingEvents.
CREATE PROCEDURE [app].[GetUpcomingEvents]
    @Days INT = 90
AS
BEGIN
    SET NOCOUNT ON;

    IF @Days IS NULL OR @Days < 1 OR @Days > 365
        THROW 50001, N'@Days must be between 1 and 365.', 1;

    SELECT e.[EventId],
           e.[Title],
           e.[EventDate],
           e.[Location],
           e.[IsOnline],
           [SessionCount] = COUNT(s.[SessionId])
    FROM [app].[Events] AS e
    LEFT JOIN [app].[Sessions] AS s ON s.[EventId] = e.[EventId]
    WHERE e.[EventDate] >= SYSUTCDATETIME()
      AND e.[EventDate] <  DATEADD(DAY, @Days, SYSUTCDATETIME())
    GROUP BY e.[EventId], e.[Title], e.[EventDate], e.[Location], e.[IsOnline]
    ORDER BY e.[EventDate];
END;
