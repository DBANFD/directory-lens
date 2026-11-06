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
- Eleven local KQL templates, with single-device or bulk scope. Queries are generated, never executed.
- Transactional dataset replacement with a pre-import database backup.

## One workspace per organization or environment

Extract a fresh empty package for every environment. An import replaces only its selected dataset; the other datasets remain. Mixing tenant exports can therefore leave unrelated data in one workspace. The tool cannot verify the tenant from these CSVs. Databases, backups and result exports contain local data. They are ignored by Git, but still require appropriate local handling.

The release database is created from `schema.sql`; it contains zero devices, users, Intune records, Defender records and import history. Synthetic CSV examples use reserved `example.invalid` addresses and invented IDs. No example data is loaded automatically.

Snapshots are historical observations. Import time is not export freshness. Intune compliance and encryption do not prove current endpoint state. Generated KQL needs validation in your Defender tenant; no live query validation is included.

## Build and verify

Run from Windows PowerShell 5.1:

```powershell
.\Build.ps1
.\tests\Test-DirectoryLens.ps1
.\tests\Test-Defender.ps1
.\Package.ps1
```

The package script uses an explicit file allowlist and creates a new empty database, regardless of data in the developer workspace. Output: `dist/Directory-Lens-0.3.0.zip`. A cloned checkout initializes its database on first GUI launch. `Initialize-Database.ps1` refuses to overwrite an existing database.

SQLite runtime provenance: [THIRD-PARTY.txt](THIRD-PARTY.txt). This project is independent of Microsoft. No third-party endorsement is implied.

## Workspace branding

Click **Branding** in the sidebar (or scroll to **Workspace branding** under **Data and refresh**), and set an app name, subtitle and hex accent color. Optionally choose a PNG logo (up to 5 MB, maximum 4096 pixels per dimension), then click **Save branding**. Changes apply immediately and persist across launches. **Restore default branding** resets the appearance without changing imported data.

The logo appears in the sidebar and as the running window icon. The executable filename and its Windows Explorer icon remain Directory Lens. Local settings and a copied logo live in `branding/`; keep that folder with the app when moving a branded workspace. Uncheck **Use custom PNG logo** to hide it. Restoring defaults does not delete the saved logo file.

Branding is local to each portable copy, Git-ignored, and excluded from the empty distribution package. The app name appears in window and record/KQL dialog titles. Neutral export filenames remain stable. A fresh package always starts with Directory Lens branding.

## Defender inventory

Import the CSV exported from **Microsoft Defender portal > Assets > Devices** using **Import Defender CSV**. The portal's `Device ID` identifies a Defender record; `AAD Device Id` supplies the Entra identity link. Onboarding, sensor health, risk, exposure and last update are shown alongside existing inventory. All original fields are available in Details and result exports.

Devices without a valid identity link remain searchable as Defender-only records. They cannot provide group membership Object IDs. Duplicate Defender identities remain visible. Follow [the import guide](IMPORT-GUIDE.md) for required headers and snapshot limitations.

For upgrades, extract the new package to a new folder. After closing the old app, copy its database and optional `branding` folder into the new copy if you want to retain that workspace. Do not overwrite a populated database with the empty database from the ZIP. The next import adds the Defender table with a pre-import backup.
