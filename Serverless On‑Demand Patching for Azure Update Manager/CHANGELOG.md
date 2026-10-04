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
