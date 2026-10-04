---
status: current
last-verified: 2026-10-04
owner: active-agent
source: repository evidence
---

# System patterns

## Architecture

- Keep the sample Windows VM private. Internet RDP, when required, is exposed
  through a Standard public load balancer inbound NAT rule instead of a public
  IP on the VM NIC.
- Gate RDP at the subnet NSG with configurable source CIDRs so the transport
  path and the allowed client ranges are both expressed in Terraform.
- Keep [docs/architecture.py](../docs/architecture.py) as the diagram source
  and refresh both rendered artifacts when the topology changes.
- Use official Azure architecture icons for public networking components in the
  rendered topology, and place the public load balancer above the NAT gateway
  when both participate in the same internet-facing path.

## Decisions

### Decision 1: Use the canonical Memory Bank base

- Choice: Keep durable project context in .memory-bank.
- Rationale: Preserve evidence-backed context across sessions.

### Decision 2: Publish VM RDP through a public load balancer

- Choice: Add a Standard public load balancer, public IP, inbound NAT rule,
  subnet NSG rule, and NIC NAT association for RDP instead of adding a public
  IP to the VM.
- Rationale: Preserve the private-VM posture while still allowing controlled
  internet RDP access.
