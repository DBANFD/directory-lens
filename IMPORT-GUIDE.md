# Import guide

Start with a fresh Directory Lens folder for one tenant. CSV imports live under **Data and refresh**. Each import replaces its dataset, preserves the other datasets and creates a local database backup. Use full exports unless you intentionally want a filtered snapshot.

## 1. Entra devices

In the Microsoft Entra admin center, go to **Entra ID > Devices > All devices > Download devices**. Download the completed CSV export. Use **Import Entra device CSV**.

Required columns:

| Field | Accepted column names |
| --- | --- |
| Entra Object ID | `id`, `objectId` |
| Entra Device ID | `deviceId`, `EntraDeviceId`, `AzureADDeviceId` |
| Device name | `displayName`, `DeviceName`, `Name` |

Optional fields: `operatingSystem`/`OS`, `trustType`/`joinType`, `owner`/`registeredOwners`, `approximateLastSignInDateTime`, `accountEnabled`/`Enabled`.

The Object ID is the directory object's ID used for group membership. It is different from the Device ID used to link Intune inventory. Do not substitute one for the other.

## 2. Entra users

Go to **Entra ID > Users > All users > Download users**. Include the required fields below if the portal offers column selection. Use **Import user CSV**.

| Field | Accepted column names |
| --- | --- |
| User Object ID | `id`, `objectId` |
| Display name | `displayName`, `Name` |
| User principal name | `userPrincipalName`, `UPN` |

Optional fields: `department`, `accountEnabled`/`Enabled`. Every user must have a nonblank UPN. A mail alias is not necessarily a UPN.

## 3. Intune inventory, optional

In the Intune admin center, go to **Devices > All devices > Export** and select **Include all inventory data in the exported file** when offered. Extract the CSV from the downloaded ZIP before selecting **Import Intune CSV**.

Required columns: `Device ID` (Intune record ID), `Device name`, and `Azure AD Device ID` (the Entra Device ID). All exported columns are preserved for the Details view and result exports. This importer expects the inventory CSV's friendly headers; other Intune report schemas may need column renaming.

Valid nonzero Azure AD Device IDs link to the Entra Device ID. Missing or invalid link IDs remain searchable Intune-only records. Multiple enrollments remain separate rows. Intune-only records cannot supply an Entra group membership Object ID.

## File rules and examples

Use UTF-8 CSV with a header row. Comma, semicolon and tab delimiters are supported. Column matching ignores case, spaces, underscores and hyphens. If a portal changes headers, compare the file to the accepted names above. Required Object IDs must be valid nonzero GUIDs and unique within the export. Empty, duplicate-ID and invalid-ID imports are rejected before replacing existing data. Excel workbooks and ZIP archives must be converted or extracted first.

The `examples` folder contains synthetic device, user and Intune exports. You can import all three into a separate lab copy to try the workflow. These files are documentation examples, not customer data.

## Bulk lookup lists are different

A bulk list searches an already imported snapshot. It does not populate the database.

- **Bulk device lookup:** choose `examples/Device-List.csv`, or provide a CSV with a `DeviceName` column. Other columns can be selected in the preview.
- **Bulk user lookup:** choose `examples/User-List.csv`, or provide a `userPrincipalName` column. Exact display names and Object IDs are also supported; UPN is preferable when names collide.
- Headerless one-column files are supported by the bulk lookup option only. Preview the selected column before searching.

Group exports include eligible exact unambiguous matches and deduplicate Object IDs. Review the results and upload manually to the correct tenant. The app never changes membership.

## Microsoft references

- [Download devices](https://learn.microsoft.com/en-us/entra/identity/devices/manage-device-identities)
- [Download users](https://learn.microsoft.com/en-us/entra/identity/users/users-bulk-download)
- [Intune report exports and schemas](https://learn.microsoft.com/en-us/intune/device-management/reports/ref-graph-available-reports)

Portal labels and exported columns can change. The required columns above describe this version's importer.
