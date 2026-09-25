# Blob Triggered Functions

Each function placed under this folder will be registered as a blob-trigger function endpoint on build.
Trigger path, connection, source (EventGrid) and the optional SQL output binding are configured in `build/build.config.psd1` > `BlobTrigger`.

The command can declare `-InputBlob` ([byte[]]), `-BlobName` ([string]) and `-TriggerMetadata`. Whatever it returns is pushed to the SQL output binding.
