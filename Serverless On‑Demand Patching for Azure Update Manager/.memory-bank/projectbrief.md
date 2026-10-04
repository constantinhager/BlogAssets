---
status: current
last-verified: 2026-10-04
owner: shared
source: repository evidence
---

# Project brief

## Purpose

Automate Azure Update Manager operations behind HTTP-triggered Azure Functions
and deploy the supporting Azure infrastructure with Terraform and GitHub
Actions.

## Scope

- In scope: Function endpoints for assessment, one-time patching, maintenance
  configuration management, Terraform-managed Azure infrastructure, and the
  documentation needed to operate and understand the deployment.
- Out of scope: Direct interactive VM administration workflows beyond the
  sample connectivity path, and manual long-term environment operations outside
  the scripted deployment and cleanup flows.

## Stakeholders

- Operators invoking the Function endpoints.
- Maintainers of the Terraform, Function App, and GitHub Actions deployment.
- Azure administrators responsible for the target subscription and identity
  bootstrap.

## Acceptance criteria

1. The repository can deploy the Azure Update Manager automation stack with
   Terraform and GitHub Actions.
2. The documentation explains the deployed topology and the primary operator
   workflows.
3. Sample infrastructure remains reproducible from source-controlled
   configuration.
