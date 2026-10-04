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
- Test Resource Graph queries before shipping: run the KQL with
  `az rest --method post --url .../providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01`
  to get the full `error.details` (parser line/token). Avoid reserved KQL
  keywords such as `kind` as column names.
- Resource Graph only returns rows the caller may read, checked as
  `<type>/read`. For `patchassessmentresources` the custom role therefore needs
  the wildcard `Microsoft.Compute/virtualMachines/patchAssessmentResults/*`
  (the plain `.../read` action is not a valid role action). Symptom when it is
  missing: machines are listed, assessment fields are empty.
- Role changes reach Resource Graph within about a minute; test the deployed
  endpoint read-only with the function key from `listKeys`.
  scopes) cannot be listed via ARM (404 NotImplemented, all API versions). Read
  them from Resource Graph: `maintenanceresources | where type =~
  'microsoft.maintenance/configurationassignments'`. `filter` is a reserved KQL
  keyword; use `properties['filter']`. New rows appear in Resource Graph after
  a delay of up to about a minute.

## Operations

- The Terraform state (`sttfstateblogassets`/`tfstate` in `rg-aum-tfstate`) is
  Entra ID only. Reading outputs such as `sample_vm_rdp_password` needs
  *Storage Blob Data Reader* on that storage account; grant it temporarily and
  remove it afterwards. Never write the password to files, docs, or the blog.
- The blog post lives outside this repository
  (`Downloads\AzureUpdateManagerAutomation\...\blog`) and must be kept in sync
  with `docs/architecture.png`, the sample exclusions, and the workflow.
