# Column definition for the CSV import.
# Column = CSV header name = SQL column name (dbo.ImportedRecord). Keep database/BlobToSqlDb/dbo/Tables/ImportedRecord.sql in sync.
# Type   = String | Int | Decimal | DateTime
$script:ImportSchema = @(
	[PSCustomObject]@{ Column = 'MeasuredAt'; Type = 'DateTime'; Required = $true }
	[PSCustomObject]@{ Column = 'DeviceId'; Type = 'String'; Required = $true; MaxLength = 100 }
	[PSCustomObject]@{ Column = 'Value'; Type = 'Decimal'; Required = $true }
)
