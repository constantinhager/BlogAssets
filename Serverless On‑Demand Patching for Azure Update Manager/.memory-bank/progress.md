---
status: current
last-verified: 2026-10-04
owner: active-agent
source: repository evidence
---

# Progress

## Current status

RDP ingress for the sample VM is implemented in Terraform and reflected in the
published architecture artifacts.

## Recent milestones

- Canonical Memory Bank base initialized.
- 2026-10-04: Added a Standard public load balancer + NAT rule for sample VM
  RDP access, documented the outputs in the README, and refreshed the
  architecture SVG/PNG.
- 2026-10-04: Refined the architecture layout so the public load balancer uses
  an official Azure icon and sits above the NAT gateway in the public traffic
  path.

## Stable capabilities

- Terraform deploys a private sample VM whose outbound traffic uses a NAT
  gateway.
- RDP can be exposed without assigning a public IP directly to the VM.

## Open work

- Apply the infrastructure update in Azure and confirm the deployed RDP
  endpoint from Terraform outputs.
