---
status: current
last-verified: 2026-10-04
owner: shared
source: repository evidence
---

# Product context

## Problem

Operators need a repeatable way to trigger Azure Update Manager actions and
manage scheduled patching without manually orchestrating ARM calls or building
supporting Azure infrastructure by hand.

## Users

- Azure operators and platform engineers responsible for VM patching.
- Repository maintainers who deploy and update the automation stack.

## Core workflows

1. Deploy the infrastructure and Function App through GitHub Actions and
   Terraform.
2. Call HTTP endpoints to assess machines, run one-time patching, and manage
   maintenance configurations.
3. Inspect and update the sample deployment, including controlled RDP access to
   the sample VM when troubleshooting or validating patching behavior.

## Experience goals

- Keep operations scriptable and reproducible.
- Avoid long-lived secrets by relying on managed identities and OIDC.
- Preserve a private-by-default sample VM topology while still allowing a
  controlled support path when needed.
