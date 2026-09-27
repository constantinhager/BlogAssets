#!/usr/bin/env bash
# Opens or closes a temporary SQL firewall rule for the GitHub runner's public IP.
# Usage: Set-SqlFirewallRule.sh open|close <resource-group> <sql-server-fqdn>
set -euo pipefail

action=${1:?open|close}
rg=${2:?resource group}
server=$(echo "${3:?sql server fqdn}" | cut -d. -f1)
rule="gh-runner-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-job}"

case "$action" in
  open)
    ip=$(curl -fsS https://api.ipify.org)
    az sql server firewall-rule create --resource-group "$rg" --server "$server" \
      --name "$rule" --start-ip-address "$ip" --end-ip-address "$ip" --output none
    echo "Opened $rule for $ip on $server"
    ;;
  close)
    az sql server firewall-rule delete --resource-group "$rg" --server "$server" --name "$rule" --output none || true
    echo "Closed $rule on $server"
    ;;
  *)
    echo "Unknown action '$action'" >&2
    exit 1
    ;;
esac
