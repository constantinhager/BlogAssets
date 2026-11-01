CREATE TABLE [app].[Events]
(
    [EventId]      INT           IDENTITY (1, 1) NOT NULL,
    [Title]        NVARCHAR(200) NOT NULL,
    [EventDate]    DATETIME2(0)  NOT NULL,
    [Location]     NVARCHAR(200) NOT NULL,
    [IsOnline]     BIT           NOT NULL CONSTRAINT [DF_Events_IsOnline] DEFAULT (0),
    [MaxAttendees] INT           NULL,
    [CreatedAt]    DATETIME2(0)  NOT NULL CONSTRAINT [DF_Events_CreatedAt] DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT [PK_Events] PRIMARY KEY CLUSTERED ([EventId] ASC)
);
