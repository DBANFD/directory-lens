# Directory Lens

Offline identity and endpoint inventory analysis for Microsoft Entra, Intune, and Defender on Windows. Import CSV snapshots, find device and user IDs, enrich devices with Intune and Defender inventory, prepare group membership CSVs, and generate Defender Advanced Hunting queries.

[Download the latest portable release](https://github.com/DBANFD/directory-lens/releases/latest).

## Start

1. Extract the entire portable ZIP into a writable folder for one organization or environment.
2. Run `Directory-Lens.exe` or `Start-GUI.cmd`.
3. The empty workspace opens **Data and refresh**. Import the CSV exports described on that page and in [IMPORT-GUIDE.md](IMPORT-GUIDE.md).
4. Search devices/users or use a bulk lookup list. Review generated group membership CSVs before manually uploading them to the intended Entra tenant.

Requires Windows x64, Windows PowerShell 5.1 and .NET Framework with WPF. The executable is unsigned. No installation, Graph authentication or network access is required by the app. Keep all package files together.

## Features

- Partial device/user search and exact bulk matching with CSV column selection.
- Separate Entra Object IDs, Entra Device IDs, Intune Device IDs and Defender Device IDs.
- Intune and Defender inventory join only on valid Entra Device IDs. Names never establish identity links.
- Selected-user and exact unambiguous device/user group exports using Object IDs.
- Gap and health reports across Entra, Intune and Defender, with snapshot context in CSV exports.
- Compare one lookup against several selected groups in one sweep.
- Eleven local KQL templates, with single-device, bulk or current report scope. Queries are generated, never executed.
- Transactional dataset replacement with a pre-import database backup.

## One workspace per organization or environment

Extract a fresh empty package for every environment. An import replaces only its selected dataset; the other datasets remain. Mixing tenant exports can therefore leave unrelated data in one workspace. The tool cannot verify the tenant from these CSVs. Databases, backups and result exports contain local data. They are ignored by Git, but still require appropriate local handling.

The release database is created from `schema.sql`; it contains zero devices, users, Intune records, Defender records, groups, member snapshots and import history. Synthetic CSV examples use reserved `example.invalid` addresses and invented IDs. No example data is loaded automatically.

Snapshots are historical observations. Import time is not export freshness. Intune compliance and encryption do not prove current endpoint state. Generated KQL needs validation in your Defender tenant; no live query validation is included.

## Build and verify

Run from Windows PowerShell 5.1:

```powershell
.\Build.ps1
.\tests\Test-DirectoryLens.ps1
.\tests\Test-Defender.ps1
.\tests\Test-Groups.ps1
.\tests\Test-Reports.ps1
.\Package.ps1
```

The package script uses an explicit file allowlist and creates a new empty database, regardless of data in the developer workspace. Output: `dist/Directory-Lens-0.5.2.zip`. A cloned checkout initializes its database on first GUI launch. `Initialize-Database.ps1` refuses to overwrite an existing database.

Pushing a `vX.Y.Z` tag that matches `VERSION` runs the release workflow: build, tests, empty package, build provenance attestation, then a draft release to review before publishing. Verify a download with its `.sha256` file or `gh attestation verify <zip> --repo DBANFD/directory-lens`.

Lookup report CSVs prefix cells that start with `=`, `+`, `-` or `@` with an apostrophe so spreadsheets treat them as text. Group upload CSVs contain Object IDs only and are not changed.

SQLite runtime provenance: [THIRD-PARTY.txt](THIRD-PARTY.txt). This project is independent of Microsoft. No third-party endorsement is implied.

Licensed under the [MIT License](LICENSE).

## Workspace branding

Click **Branding** in the sidebar (or scroll to **Workspace branding** under **Data and refresh**), and set an app name, subtitle and hex accent color. Optionally choose a PNG logo (up to 5 MB, maximum 4096 pixels per dimension), then click **Save branding**. Changes apply immediately and persist across launches. **Restore default branding** resets the appearance without changing imported data.

The logo appears in the sidebar and as the running window icon. The executable filename and its Windows Explorer icon remain Directory Lens. Local settings and a copied logo live in `branding/`; keep that folder with the app when moving a branded workspace. Uncheck **Use custom PNG logo** to hide it. Restoring defaults does not delete the saved logo file.

Branding is local to each portable copy, Git-ignored, and excluded from the empty distribution package. The app name appears in window and record/KQL dialog titles. Neutral export filenames remain stable. A fresh package always starts with Directory Lens branding.

## Defender inventory

Import the CSV exported from **Microsoft Defender portal > Assets > Devices** using **Import Defender CSV**. The portal's `Device ID` identifies a Defender record; `AAD Device Id` supplies the Entra identity link. Onboarding, sensor health, risk, exposure and last update are shown alongside existing inventory. All original fields are available in Details and result exports.

Devices without a valid identity link remain searchable as Defender-only records. They cannot provide group membership Object IDs. Duplicate Defender identities remain visible. Follow [the import guide](IMPORT-GUIDE.md) for required headers and snapshot limitations.

For upgrades, extract the new package to a new folder. After closing the old app, copy its database and optional `branding` folder into the new copy if you want to retain that workspace. Do not overwrite a populated database with the empty database from the ZIP. The next import adds the Defender table with a pre-import backup.

## Compare lists against group membership

1. Open **Group membership** and import the Entra **All groups > Download groups** CSV. This is a catalog of groups, not their members.
2. Search for and select the exact target group. Export **Members > Bulk operations > Download members** from that group in Entra without filters. Confirm it is the complete direct-member export, then import it for the selected group.
3. Close the group window. Run **Bulk device lookup** or **Bulk user lookup** with the list to check. You can also select users in the user search results.
4. Click **Compare group**, select one or several targets (Ctrl/Shift) and click **Compare selected groups**. Review **Existing**, **Missing**, **DuplicateInput**, **Unresolved** and **Not loaded** rows for each group. The lookup stays captured while you select or import other groups.
5. Use **Export comparison report** for the combined results, including group Object IDs and member/inventory snapshot timestamps. To create an upload, select exactly one group and compare it again. Click **Export missing members** to create a deduplicated Entra upload CSV containing only eligible missing Object IDs. Upload it manually to the intended group after checking the snapshot dates and current membership.

A group without a member snapshot is **Not loaded**, never assumed empty. Header-only member exports are accepted only with explicit complete-export confirmation. Refreshing one group's members preserves the other snapshots and all directory inventories. Group catalog refreshes retain member snapshots by group Object ID.

Comparison is by member **Object ID**, never by deviceId or display name. Unresolved, ambiguous and partial lookup matches are excluded from uploads. Nested groups are not expanded; this compares direct membership only. Dynamic and synchronized groups are comparison-only. Upload export supports cloud, assigned Security groups, plus user lists for cloud, assigned Microsoft 365 groups; other or unknown group types/sources are comparison-only. Availability of the operation in your tenant still depends on permissions and group policy.

Member exports may not identify the group or tenant within the file. You must select the correct target and use matching exports from the same tenant. A filtered or stale member list cannot establish current membership; **Missing** means absent from the imported snapshot. Existing **Export group members** remains the general export; use **Compare group > Export missing members** for the difference-only workflow.

## Inventory gaps and health (0.5.0)

Open **Gaps and health** and choose a report. Each report uses the current local datasets and retains source record IDs. **Export current report** writes the displayed records, findings, generation time and snapshot context to CSV.

| Report | Meaning |
| --- | --- |
| Entra without Intune / Entra without Defender | Entra records without a valid identity link to the selected inventory. |
| Intune without valid Entra Device ID | Intune records whose Azure AD Device ID is missing, zero or malformed. |
| Defender without valid AAD Device Id | Defender records whose AAD Device Id is missing, zero or malformed. |
| Intune without Defender / Defender without Intune | Records without a matching valid Entra Device ID in the other inventory, including identities absent from Entra. |
| Disabled Entra with inventory records | Entra `accountEnabled=False` with a valid ID still appearing in Intune or Defender. This does not prove current activity. |
| Defender-only records | No valid identity link to either Entra or Intune. |
| Duplicate identities | More than one record with the same valid Entra Device ID **within a dataset**. Each record remains visible; one identity appearing across different inventories is expected. |
| Missing or weak owner | Blank OwnerText, or text without a unique exact Object ID/UPN match to imported users. Display-name matches are always weak, including unique names. Composite labels are unresolved. This is a review aid, not verified ownership. |

**Not loaded** means a required dataset has never been imported; it is not an empty or missing inventory. **Invalid identity** means a source record cannot establish a link. Neither state is proof that a device is absent from the target service. No names are used to join inventories. Imported UTC, elapsed days since import and source modified UTC are shown above reports; timestamps are retained in exports. A recently copied file or import can contain old observations.

Click **KQL from current report** to open the existing eleven-template generator with device names from the displayed report. Blank names are omitted. Hunting scope uses the templates' existing short-hostname matching, so duplicate names across domains can collide; it does not establish inventory identity links. Review or edit the scope before generating. Queries are generated locally, never executed, and a device missing from the Defender snapshot may also have no hunting telemetry.

Group comparisons show each member snapshot's import time, age and source file time alongside the results. Unloaded targets remain **Not loaded** in a multi-group sweep. Combined comparison exports are review reports, not upload files. Upload exports remain single-target, missing-only Object ID files with the existing restrictions. Nested membership is not expanded.
