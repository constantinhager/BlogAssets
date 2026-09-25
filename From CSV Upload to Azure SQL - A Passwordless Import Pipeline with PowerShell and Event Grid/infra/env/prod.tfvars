# Non-secret settings for the production deployment (used by GitHub Actions).
# subscription_id, sql_admin_login_name and sql_admin_object_id come from GitHub variables (TF_VAR_*).
location            = "germanywestcentral"
prefix              = "blob2sql"
powershell_version  = "7.4"
sql_database_sku    = "Basic"
file_extensions     = [".csv"]
csv_delimiter       = "auto"
csv_encoding        = "utf-8"
csv_source_timezone = "UTC"

tags = {
  workload = "blob-to-sql"
  managed  = "terraform"
}
