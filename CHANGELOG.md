# Changelog

## 0.5.2 - 2026-11-11

- Startup errors now show the actual PowerShell error and its position. The launcher previously displayed only a .NET type name.
- Lookup report CSVs keep text as text in Excel: cells that start with `=`, `+`, `-`, `@`, a tab or a line break are written with a leading apostrophe, so inventory text from a tenant export cannot run as a formula.
- Read-only database queries run the bundled SQLite shell in safe mode, which refuses shell and file commands. Imports are unchanged.
- Releases are built by a tag-triggered workflow that tests, packages, attests build provenance and creates a draft release. CI actions are pinned by commit, Dependabot watches them, and PSScriptAnalyzer runs on every push.

## 0.5.1 - 2026-11-09

- Fixed a startup error on machines with the RemoteSigned execution policy when the package was downloaded from the internet. Directory-Lens.exe and Start-GUI.cmd now run the bundled scripts with a process-only Bypass policy. Group Policy execution policy settings still apply.

## 0.5.0 - 2026-11-09

- Inventory gap reports with CSV export: Entra devices without Intune, Intune and Defender records without a valid Entra Device ID, and linked Intune/Defender identities missing against each other. Joins use valid Entra Device IDs only, never display names.
- Health views: disabled Entra devices still present in Intune or Defender, Defender-only records, duplicate identities, and devices without an owner or with a weak OwnerText match. Owner text matching is a review heuristic and never establishes identity links.
- The existing eleven KQL templates can use the current report as query scope. Queries are generated, never executed.
- Compare one lookup list against several groups in a single sweep. Groups without a member snapshot show as Not loaded. Object ID matching, direct-membership-only comparison and single-target upload rules are unchanged.
- Snapshot import time and source file time are shown during compare and export.
- MIT license added to the repository and portable package.

## 0.4.0 - 2026-11-06

- Import the Entra group catalog and per-group direct-member snapshots.
- Compare device and user lookups against a group and export only eligible missing members as an Entra upload CSV.
- Header-only member exports require explicit complete-export confirmation. A group without a snapshot is never assumed empty.

## 0.3.0 - 2026-11-06

- Import Defender portal device inventory and enrich devices with onboarding, sensor health, risk, exposure and last update.
- Defender records link only through a valid AAD Device Id. Unlinked records remain searchable as Defender-only.

## 0.2.0 - 2026-11-06

- Portable workspace branding: app name, subtitle, accent color and optional PNG logo, stored locally per copy.

## 0.1.0 - 2026-11-06

- Initial portable release: empty workspace, Entra device/user and Intune CSV imports, device and user search, bulk lookup, Object ID group exports and eleven local KQL templates.
