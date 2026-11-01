location     = "germanywestcentral"
name_prefix  = "dab"
sql_sku_name = "S0" # DTU model, Standard tier, 10 DTUs

# sql_admin_group_name and sql_admin_group_object_id come from the repository variables
# SQL_ADMIN_GROUP_NAME and SQL_ADMIN_GROUP_ID (TF_VAR_* in the workflow).

tags = {
  workload = "data-api-builder-sample"
  owner    = "platform-team"
}
