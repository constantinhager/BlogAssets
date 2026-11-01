CREATE TABLE [app].[Sessions]
(
    [SessionId]       INT           IDENTITY (1, 1) NOT NULL,
    [EventId]         INT           NOT NULL,
    [Title]           NVARCHAR(200) NOT NULL,
    [Speaker]         NVARCHAR(100) NOT NULL,
    [SpeakerEmail]    NVARCHAR(256) NULL,
    [Level]           SMALLINT      NOT NULL CONSTRAINT [DF_Sessions_Level] DEFAULT (200),
    [DurationMinutes] INT           NOT NULL CONSTRAINT [DF_Sessions_Duration] DEFAULT (45),
    CONSTRAINT [PK_Sessions] PRIMARY KEY CLUSTERED ([SessionId] ASC),
    CONSTRAINT [FK_Sessions_Events] FOREIGN KEY ([EventId]) REFERENCES [app].[Events] ([EventId]) ON DELETE CASCADE,
    CONSTRAINT [CK_Sessions_Level] CHECK ([Level] IN (100, 200, 300, 400)),
    CONSTRAINT [CK_Sessions_Duration] CHECK ([DurationMinutes] BETWEEN 5 AND 480)
);
