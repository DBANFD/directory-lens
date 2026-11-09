#requires -Version 5.1
$ErrorActionPreference='Stop'
$version=(Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
$dist=Join-Path $PSScriptRoot 'dist'
$stage=Join-Path $dist ('stage-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $stage | Out-Null
if (-not (Test-Path (Join-Path $PSScriptRoot 'Directory-Lens.exe'))) { & (Join-Path $PSScriptRoot 'Build.ps1') }
$files=@('Directory-Lens.exe','Directory-Lens-GUI.ps1','Directory-Lens.xaml','Database.ps1','Branding.ps1','Reports.ps1','Report-UI.ps1','Inventory-Reports.xaml','Groups.ps1','Group-UI.ps1','Group-Membership.xaml','groups-schema.sql','Csv-Helpers.ps1','Import-DirectoryLens.ps1','Initialize-Database.ps1','schema.sql','ImportGroupMembersTemplate.csv','Start-GUI.cmd','README.md','IMPORT-GUIDE.md','THIRD-PARTY.txt','LICENSE','VERSION','lib\sqlite3.exe','examples\Entra-Devices.csv','examples\Entra-Users.csv','examples\Intune-Devices.csv','examples\Defender-Devices.csv','examples\Device-List.csv','examples\User-List.csv','examples\Group-Catalog.csv','examples\Group-Members-Devices.csv','examples\Group-Members-Users.csv')
foreach ($file in $files) {
    $target=Join-Path $stage $file
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $target
}
& (Join-Path $stage 'Initialize-Database.ps1')
$DatabasePath=Join-Path $stage 'Directory-Lens.db'
. (Join-Path $stage 'Database.ps1')
$count=Invoke-Database 'SELECT (SELECT count(*) FROM devices)+(SELECT count(*) FROM users)+(SELECT count(*) FROM intune)+(SELECT count(*) FROM defender)+(SELECT count(*) FROM groups)+(SELECT count(*) FROM group_members)+(SELECT count(*) FROM group_snapshots)+(SELECT count(*) FROM imports) AS Total;'
if ($count.Total -ne 0) { throw 'Release database must be empty.' }
$zip=Join-Path $dist ('Directory-Lens-'+$version+'.zip')
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
(Get-FileHash $zip -Algorithm SHA256).Hash+'  '+(Split-Path $zip -Leaf) | Set-Content ($zip+'.sha256')
Write-Output $zip
