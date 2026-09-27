#!/usr/bin/env bash
# Run from infra/ after terraform init. Writes selected Terraform outputs to $GITHUB_OUTPUT.
# Missing or empty outputs (no state yet) are written as empty values, exists=false.
set -uo pipefail

exists=true
for name in resource_group function_app_name sql_server_fqdn sql_database sql_identity_name sql_identity_client_id; do
  # With an empty state, terraform output only warns and exits 0, so an empty value also counts as missing
  value=$(terraform output -raw "$name" 2>/dev/null) || value=""
  [ -n "$value" ] || exists=false
  echo "$name=$value" >> "${GITHUB_OUTPUT:-/dev/stdout}"
done
echo "exists=$exists" >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "Terraform outputs available: $exists"
