# Changelog

All notable changes to this project will be documented in this file.

The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add a Standard public load balancer with an inbound NAT rule for RDP access
  to the sample Windows VM.
- Add Terraform outputs for the sample VM RDP endpoint and local admin
  credentials.

### Changed

- Update the README and architecture diagram to show the RDP entry path through
  the public load balancer.
- Redesign the architecture diagram layout: runtime lane on top, deployment
  lane (Entra ID + GitHub) at the bottom, separate admin node for RDP, NSG on
  the RDP path, maintenance configurations trigger Update Manager, legend, and
  no overlapping labels or crossing arrows.

### Fixed

- Fix `Get-UpdateManagerMachine` failing with `400 BadRequest`: the Resource
  Graph query used the reserved KQL keyword `kind` as a column name. The
  column is now `machineKind`; the `Kind` property of the response is
  unchanged.
- Include the `error.details` of a failed ARM request in the exception
  message, so query parser failures show their line and token.
- Stop Terraform from removing the `hidden-link: /app-insights-resource-id`
  tag of the Function App on every apply. Azure sets this tag itself, so it is
  now ignored via `lifecycle.ignore_changes`.
- Fix `Get-UpdateMaintenanceConfiguration` logging `404 NotImplemented` and
  returning no dynamic scopes: Azure does not support listing subscription-level
  configuration assignments through ARM. The dynamic scopes are now read from
  Azure Resource Graph (`maintenanceresources`).
