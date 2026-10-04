---
status: current
last-verified: 2026-10-04
owner: active-agent
source: repository evidence
---

# Tech context

## Stack

- Terraform provisions Azure networking, storage, monitoring, the Function App,
  and the sample Windows VM.
- The architecture diagram source is Python in
  [docs/architecture.py](../docs/architecture.py), while rendered artifacts are
  [docs/architecture.svg](../docs/architecture.svg) and
  [docs/architecture.png](../docs/architecture.png).

## Environment

- Validation in this workspace can run Terraform locally.
- Python is not currently available in the workspace, so the rendered diagram
  artifacts may need to be updated by editing the SVG directly and re-rendering
  the PNG with headless Edge when Python-based regeneration is unavailable.

## Constraints

- The sample VM must stay private with no public IP on the NIC.
- RDP exposure must remain configurable and restricted by source CIDR ranges.

## Validation

- Use `terraform fmt -check -recursive`, `terraform init -backend=false`, and
  `terraform validate` for infrastructure changes.
- Verify diagram updates by checking the SVG labels and re-rendering the PNG.
