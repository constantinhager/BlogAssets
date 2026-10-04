---
status: current
last-verified: 2026-10-04
owner: active-agent
source: current task evidence
---

# Active context

## Current focus

Expose the sample Windows VM for RDP through a Standard public load balancer
NAT rule while keeping the VM itself private, and keep the published
architecture artifacts aligned with the Terraform design.

## Evidence

- Terraform now defines a Standard public IP, Standard public load balancer,
  inbound NAT rule, subnet NSG RDP rule, NIC NAT association, and RDP outputs.
- The README documents the RDP access path and Terraform outputs.
- The architecture source and rendered SVG/PNG now show the public load
  balancer and RDP flow.

## Next step

Apply the Terraform change in Azure when ready, then use the RDP outputs to
connect through the load balancer endpoint.
