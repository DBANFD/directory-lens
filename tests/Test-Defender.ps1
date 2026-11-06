#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$testRoot=Join-Path $root ('work\defender-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $testRoot | Out-Null
$DatabasePath=Join-Path $testRoot 'test.db'
. (Join-Path $root 'Database.ps1')
. (Join-Path $root 'Csv-Helpers.ps1')
function Assert($Value,[string]$Message) { if (-not $Value) { throw $Message } }
& (Join-Path $root 'Initialize-Database.ps1') -DatabasePath $DatabasePath
# Simulate a pre-Defender workspace. Reading must not require migration.
Invoke-Database 'DROP TABLE defender;' -Write
Assert (@(Get-DatabaseSummary | Where-Object Dataset -eq 'Defender')[0].Records -eq 0) 'Legacy summary failed'
foreach ($kind in @('Devices','Users','Intune')) {
 $file=@{Devices='Entra-Devices.csv';Users='Entra-Users.csv';Intune='Intune-Devices.csv'}[$kind]
 & (Join-Path $root 'Import-DirectoryLens.ps1') -Kind $kind -CsvPath (Join-Path $root ('examples\'+$file)) -DatabasePath $DatabasePath
}
$csv=Join-Path $testRoot 'defender.csv'
$header='Device ID,Device Name,AAD Device Id,OS Platform,Health Status,Onboarding Status,Extra Field'
@($header,(('a'*40)+',LAB-PC-01,22222222-2222-4222-8222-222222222222,Windows11,Active,Onboarded,first'),(('b'*40)+',LAB-PC-01.old,22222222-2222-4222-8222-222222222222,Windows11,Inactive,Onboarded,second'),(('c'*40)+',UNLINKED,,Linux,Active,Can be onboarded,third')) | Set-Content $csv
& (Join-Path $root 'Import-DirectoryLens.ps1') -Kind Defender -CsvPath $csv -DatabasePath $DatabasePath
Assert (@(Get-DatabaseSummary | Where-Object Records -eq 1).Count -eq 3) 'Defender import altered existing datasets'
$rows=@(Search-Devices @('LAB-PC-01'))
Assert ($rows.Count -eq 2 -and $rows[0].DefenderRecordCount -eq 2 -and $rows[0].GroupEligible) 'Multiple linked Defender records not retained'
Assert ($rows[0].IntuneModel -eq 'Example Model') 'Intune enrichment lost'
Assert ($rows[1].DefenderExtraField -eq 'second') 'Original Defender field lost'
$orphans=@(Search-DeviceText 'UNLINK')
Assert ($orphans.Count -eq 1 -and $orphans[0].Status -eq 'DefenderOnly' -and -not $orphans[0].GroupEligible) 'Defender-only lookup unsafe'
$report=Join-Path $testRoot 'report.csv'
Save-Report @($orphans+$rows) $report
$exported=@(Import-Csv $report)
Assert ($exported[1].IntuneModel -eq 'Example Model' -and $exported[0].DefenderExtraField -eq 'third') 'Mixed result report lost fields'
$before=(Get-FileHash $DatabasePath).Hash
Add-Content $csv ((('a'*40)+',DUPLICATE,,Windows,,,,'))
$rejected=$false
try { & (Join-Path $root 'Import-DirectoryLens.ps1') -Kind Defender -CsvPath $csv -DatabasePath $DatabasePath } catch { $rejected=$true }
Assert ($rejected -and (Get-FileHash $DatabasePath).Hash -eq $before) 'Duplicate import must preserve database'
# Same-name unlinked Defender records must never make a group match eligible.
@($header,(('a'*40)+',LAB-PC-01,22222222-2222-4222-8222-222222222222,Windows11,Active,Onboarded,first'),(('d'*40)+',LAB-PC-01,invalid,Windows11,Inactive,Can be onboarded,unlinked')) | Set-Content $csv
& (Join-Path $root 'Import-DirectoryLens.ps1') -Kind Defender -CsvPath $csv -DatabasePath $DatabasePath
$rows=@(Search-Devices @('LAB-PC-01'))
Assert ($rows.Count -eq 2 -and @($rows | Where-Object GroupEligible).Count -eq 0) 'Same-name orphan conflict must disable group export'
& (Join-Path $root 'Import-DirectoryLens.ps1') -Kind Users -CsvPath (Join-Path $root 'examples\Entra-Users.csv') -DatabasePath $DatabasePath
Assert ((Invoke-Database 'SELECT count(*) AS N FROM defender;').N -eq 2) 'Other dataset refresh erased Defender'
Assert ((Invoke-Database 'PRAGMA integrity_check;').integrity_check -eq 'ok') 'Integrity failed'
# Exercise the GUI background import path on a fresh empty workspace.
$empty=Join-Path $testRoot 'gui.db'
. (Join-Path $root 'Directory-Lens-GUI.ps1') -DatabasePath $empty -NoShow
function Wait-Work {
 $deadline=[DateTime]::UtcNow.AddSeconds(25)
 while ($script:Busy -and [DateTime]::UtcNow -lt $deadline) { if ($script:Handle.IsCompleted) { Complete-Work }; Start-Sleep -Milliseconds 20 }
 Assert (-not $script:Busy -and -not $script:LastError) 'GUI background operation failed'
}
Wait-Work
Start-Work 'ImportDefender' -CsvPath (Join-Path $root 'examples\Defender-Devices.csv')
Wait-Work
Assert ($C.SnapshotDetails.Text -match 'Defender: 1 records') 'GUI Defender summary missing'
Set-Page 'Devices'
Start-Work 'Devices' -Query 'LAB-PC-01'
Wait-Work
Assert ($script:Results.Count -eq 1 -and $script:Results[0].Status -eq 'DefenderOnly') 'GUI Defender-only search failed'
$Timer.Stop();$Window.Close()
'PASS: Defender migration, ID-only links, duplicate identities, orphan/group safeguards, all-field reports, rejected import isolation, refresh retention and async GUI import/search.'
