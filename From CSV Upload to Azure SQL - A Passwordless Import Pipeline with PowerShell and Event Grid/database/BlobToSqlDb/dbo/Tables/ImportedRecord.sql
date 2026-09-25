-- Target table for the SQL output binding of Import-CsvBlob.
-- Columns must match $script:ImportSchema in BlobToSql/internal/scripts/schema.ps1.
-- The binding does a MERGE on the primary key, so re-processing a file updates
-- the same rows instead of duplicating them.
CREATE TABLE [dbo].[ImportedRecord]
(
    [SourceBlob]  NVARCHAR (400)  NOT NULL,
    [RowNumber]   INT             NOT NULL,
    [MeasuredAt]  DATETIME2 (3)   NOT NULL,
    [DeviceId]    NVARCHAR (100)  NOT NULL,
    [Value]       DECIMAL (18, 4) NOT NULL,
    [ImportedAt]  DATETIME2 (3)   NOT NULL,
    CONSTRAINT [PK_ImportedRecord] PRIMARY KEY CLUSTERED ([SourceBlob] ASC, [RowNumber] ASC)
);
