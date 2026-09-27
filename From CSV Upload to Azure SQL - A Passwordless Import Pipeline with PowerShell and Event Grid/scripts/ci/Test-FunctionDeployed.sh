#!/usr/bin/env bash
# Run from infra/ after terraform init and az login.
# Writes deployed=true|false to $GITHUB_OUTPUT: true when the Function App exists
# (per Terraform state) and already hosts $FUNCTION_NAME.
set -uo pipefail

deployed=false
app=$(terraform output -raw function_app_name 2>/dev/null || true)
rg=$(terraform output -raw resource_group 2>/dev/null || true)

if [[ -n "$app" && -n "$rg" && "$app" != *"No outputs"* ]]; then
  if az functionapp function show --resource-group "$rg" --name "$app" \
       --function-name "${FUNCTION_NAME:?}" --only-show-errors > /dev/null 2>&1; then
    deployed=true
  fi
fi

echo "Function '${FUNCTION_NAME}' deployed: $deployed"
echo "deployed=$deployed" >> "${GITHUB_OUTPUT:-/dev/stdout}"
