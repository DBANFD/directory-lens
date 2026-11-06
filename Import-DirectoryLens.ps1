#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Devices','Users','Intune','Defender')][string]$Kind,
    [Parameter(Mandatory=$true)][string]$CsvPath,
    [string]$DatabasePath
)
if (-not $DatabasePath) { $DatabasePath = Join-Path $PSScriptRoot 'Directory-Lens.db' }
. (Join-Path $PSScriptRoot 'Database.ps1')
. (Join-Path $PSScriptRoot 'Csv-Helpers.ps1')
$rows = @(Read-CsvFile $CsvPath)
if ($rows.Count -eq 0) { throw 'Empty CSV. Existing database unchanged.' }
$map = @{}
if ($Kind -eq 'Defender') {
    $map.ObjectId = Find-Column $rows[0] @('Device ID')
    $map.Name = Find-Column $rows[0] @('Device Name')
    $map.DeviceId = Find-Column $rows[0] @('AAD Device Id','AadDeviceId')
} elseif ($Kind -eq 'Intune') {
    $map.ObjectId = Find-Column $rows[0] @('Device ID')
    $map.Name = Find-Column $rows[0] @('Device name')
    $map.DeviceId = Find-Column $rows[0] @('Azure AD Device ID')
} else { $map.ObjectId = Find-Column $rows[0] @('id','objectId') }
if ($Kind -eq 'Devices') {
    $map.Name = Find-Column $rows[0] @('displayName','DeviceName','Name')
    $map.DeviceId = Find-Column $rows[0] @('deviceId','EntraDeviceId','AzureADDeviceId')
    $map.OS = Find-Column $rows[0] @('operatingSystem','OS') -Optional
    $map.JoinType = Find-Column $rows[0] @('trustType','joinType') -Optional
    $map.Owner = Find-Column $rows[0] @('owner','registeredOwners') -Optional
    $map.SignIn = Find-Column $rows[0] @('approximateLastSignInDateTime') -Optional
} elseif ($Kind -eq 'Users') {
    $map.Name = Find-Column $rows[0] @('displayName','Name')
    $map.UPN = Find-Column $rows[0] @('userPrincipalName','UPN')
    $map.Department = Find-Column $rows[0] @('department') -Optional
}
$map.Enabled = Find-Column $rows[0] @('accountEnabled','Enabled') -Optional
function Value($Row, [string]$Key) {
    $column = $map[$Key]
    if ($column) { return ([string]$Row.$column).Trim() }
    return ''
}
$sql = New-Object Text.StringBuilder
[void]$sql.AppendLine(@'
BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS devices(ObjectId TEXT PRIMARY KEY, DeviceId TEXT, DeviceName TEXT, NameKey TEXT, OS TEXT, JoinType TEXT, Enabled TEXT, OwnerText TEXT, LastSignIn TEXT);
CREATE INDEX IF NOT EXISTS devices_name ON devices(NameKey);
CREATE TABLE IF NOT EXISTS users(ObjectId TEXT PRIMARY KEY, DisplayName TEXT, NameKey TEXT, UPN TEXT, UpnKey TEXT, Department TEXT, Enabled TEXT);
CREATE INDEX IF NOT EXISTS users_name ON users(NameKey);
CREATE INDEX IF NOT EXISTS users_upn ON users(UpnKey);
CREATE TABLE IF NOT EXISTS imports(ImportId INTEGER PRIMARY KEY, Dataset TEXT, ImportedUtc TEXT, SourceFile TEXT, SourceModifiedUtc TEXT, RowCount INTEGER);
CREATE TABLE IF NOT EXISTS intune(IntuneDeviceId TEXT PRIMARY KEY, DeviceId TEXT, DeviceName TEXT, NameKey TEXT, InventoryJson TEXT);
CREATE INDEX IF NOT EXISTS intune_device ON intune(DeviceId);
CREATE INDEX IF NOT EXISTS intune_name ON intune(NameKey);
CREATE INDEX IF NOT EXISTS devices_device ON devices(DeviceId COLLATE NOCASE);
CREATE TABLE IF NOT EXISTS defender(DefenderDeviceId TEXT PRIMARY KEY, DeviceId TEXT, DeviceName TEXT, NameKey TEXT, InventoryJson TEXT);
CREATE INDEX IF NOT EXISTS defender_device ON defender(DeviceId);
CREATE INDEX IF NOT EXISTS defender_name ON defender(NameKey);
CREATE TABLE IF NOT EXISTS groups(GroupId TEXT PRIMARY KEY,DisplayName TEXT,NameKey TEXT,GroupType TEXT,MembershipType TEXT,Source TEXT,MailEnabled TEXT,OnPremisesSyncEnabled TEXT);
CREATE INDEX IF NOT EXISTS groups_name ON groups(NameKey);
CREATE TABLE IF NOT EXISTS group_members(GroupId TEXT,MemberId TEXT,PRIMARY KEY(GroupId,MemberId));
CREATE TABLE IF NOT EXISTS group_snapshots(GroupId TEXT PRIMARY KEY,ImportedUtc TEXT,SourceFile TEXT,SourceModifiedUtc TEXT,MemberCount INTEGER);
'@)
$table = $Kind.ToLowerInvariant()
[void]$sql.AppendLine("DELETE FROM $table;")
$seen = @{}
$rowNumber = 1
foreach ($row in $rows) {
    $rowNumber++
    $id = Value $row 'ObjectId'
    if ($Kind -eq 'Defender') {
        if ($id -notmatch '^[0-9a-fA-F]{40}$') { throw "Invalid Defender Device ID at CSV row $rowNumber. Expected 40 hexadecimal characters. Existing database unchanged." }
        $id=$id.ToLowerInvariant()
    } else {
        if (-not (Test-Guid $id)) { throw "Invalid Object ID at CSV row $rowNumber. Existing database unchanged." }
        $id = ([guid]$id).ToString()
    }
    if ($seen.ContainsKey($id)) { throw "Duplicate Object ID at CSV row $rowNumber. Existing database unchanged." }
    $seen[$id] = $true
    $name = Value $row 'Name'
    if ($Kind -in @('Intune','Defender')) {
        $deviceId = Value $row 'DeviceId'
        # Missing/invalid Azure IDs remain searchable but must never establish an identity link.
        if (Test-Guid $deviceId) { $deviceId=([guid]$deviceId).ToString() } else { $deviceId='' }
        $values = @($id, $deviceId, $name, $name.ToUpperInvariant(), (ConvertTo-Json -InputObject $row -Compress -Depth 5))
    } elseif ($Kind -eq 'Devices') {
        $values = @($id, (Value $row 'DeviceId'), $name, $name.ToUpperInvariant(), (Value $row 'OS'), (Value $row 'JoinType'), (Value $row 'Enabled'), (Value $row 'Owner'), (Value $row 'SignIn'))
    } else {
        $upn = Value $row 'UPN'
        if (-not $upn) { throw "Empty UPN at CSV row $rowNumber. Existing database unchanged." }
        $values = @($id, $name, $name.ToUpperInvariant(), $upn, $upn.ToUpperInvariant(), (Value $row 'Department'), (Value $row 'Enabled'))
    }
    $quoted = foreach ($v in $values) { Sql-Text $v }
    [void]$sql.AppendLine("INSERT INTO $table VALUES ($($quoted -join ','));")
}
$source = Get-Item -LiteralPath $CsvPath
$now = [DateTime]::UtcNow.ToString('o')
[void]$sql.AppendLine(('INSERT INTO imports(Dataset,ImportedUtc,SourceFile,SourceModifiedUtc,RowCount) VALUES ({0},{1},{2},{3},{4});' -f (Sql-Text $Kind), (Sql-Text $now), (Sql-Text $source.Name), (Sql-Text $source.LastWriteTimeUtc.ToString('o')), $rows.Count))
[void]$sql.AppendLine('PRAGMA user_version=3; COMMIT;')
if (Test-Path -LiteralPath $DatabasePath) {
    $backup = $DatabasePath + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    # SQLite creates a consistent snapshot even if a reader has the database open.
    Invoke-Database ('VACUUM INTO ' + (Sql-Text $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($backup)) + ';') -Write
    Write-Host "Backup: $backup"
}
Write-Host "Importing $($rows.Count) $Kind records..."
Invoke-Database $sql.ToString() -Write
Write-Host "Imported $Kind snapshot. Other dataset preserved. Database: $DatabasePath"
