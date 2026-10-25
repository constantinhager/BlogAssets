# Copy to production.tfvars - the workflow plans with -var-file=production.tfvars. No secrets in here.

location    = "germanywestcentral"
name_prefix = "secrot"

# Report credentials that expire within this many days. Nothing is renewed without your approval.
threshold_days              = 30
secret_validity_days        = 180
certificate_validity_months = 12

mail_sender     = "yoursender@maildomain.com"
mail_recipients = ["yourmailrecepient@maildomain.com"]

# Group that approves renewals (edits the state table) and may import existing secrets into Key Vault
admin_principal_ids = []

# Required: client ID of the rotation app (output of scripts/New-SecretRotationApp.ps1)
rotation_app_id = ""

# Customer tenants (admin consent for the rotation app first). The home tenant is always included.
customer_tenant_ids = []
