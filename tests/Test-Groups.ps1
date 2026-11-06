#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$testRoot=Join-Path $root ('work\groups-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $testRoot | Out-Null
$DatabasePath=Join-Path $testRoot 'test.db'
. (Join-Path $root 'Database.ps1')
. (Join-Path $root 'Csv-Helpers.ps1')
. (Join-Path $root 'Groups.ps1')
function Assert($Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Reject([scriptblock]$Action,[string]$Message) { $failed=$false;try { & $Action | Out-Null } catch { $failed=$true };Assert $failed $Message }
& (Join-Path $root 'Initialize-Database.ps1') -DatabasePath $DatabasePath
& (Join-Path $root 'Import-DirectoryLens.ps1') -Kind Devices -CsvPath (Join-Path $root 'examples\Entra-Devices.csv') -DatabasePath $DatabasePath
$deviceHash=(Invoke-Database 'SELECT * FROM devices;' | ConvertTo-Json -Compress)
# Legacy schema reads as no catalog; first catalog import creates its own tables.
Invoke-Database 'DROP TABLE groups; DROP TABLE group_members; DROP TABLE group_snapshots;' -Write
Assert (@(Get-GroupCatalog).Count -eq 0) 'Legacy schema must be readable'
$catalog=Join-Path $testRoot 'catalog.csv'
@('displayName,id,groupType,membershipType,source,mailEnabled,onPremisesSyncEnabled','Example Devices,55555555-5555-4555-8555-555555555555,Security,assigned,Cloud,False,','Example Users,66666666-6666-4666-8666-666666666666,Microsoft 365,assigned,Cloud,True,','Example Dynamic,77777777-7777-4777-8777-777777777777,Security,dynamic,Cloud,False,','Example Synced,88888888-8888-4888-8888-888888888888,Security,assigned,Windows Server AD,False,True') | Set-Content $catalog
$null=Import-GroupCatalog $catalog
Assert (@(Get-GroupCatalog).Count -eq 4) 'Catalog import failed'
$groupId='55555555-5555-4555-8555-555555555555'
$existing='11111111-1111-4111-8111-111111111111'
$missing='33333333-3333-4333-8333-333333333333'
$candidates=@([pscustomobject]@{RequestedName='EXISTING';ObjectId=$existing;GroupEligible=$true},[pscustomobject]@{RequestedName='MISSING';ObjectId=$missing;GroupEligible=$true},[pscustomobject]@{RequestedName='DUPLICATE';ObjectId=$missing.ToUpperInvariant();GroupEligible=$true},[pscustomobject]@{RequestedName='AMBIGUOUS';ObjectId='99999999-9999-4999-8999-999999999999';GroupEligible=$false})
Reject { Compare-GroupMembers $groupId $candidates Devices } 'Unloaded membership must never be treated as empty'
$members=Join-Path $testRoot 'members.csv'
@('displayName,objectType,id,deviceId,userPrincipalName','Example Device,Device,11111111-1111-4111-8111-111111111111,22222222-2222-4222-8222-222222222222,','Repeated Device,Device,11111111-1111-4111-8111-111111111111,22222222-2222-4222-8222-222222222222,') | Set-Content $members
Reject { Import-GroupMembers $groupId $members } 'Complete snapshot confirmation required'
$null=Import-GroupMembers $groupId $members -CompleteSnapshot
$comparison=@(Compare-GroupMembers $groupId $candidates Devices)
Assert (($comparison.Comparison -join ',') -eq 'Existing,Missing,DuplicateInput,Unresolved') 'Comparison/deduplication incorrect'
Assert (@($comparison | Where-Object GroupEligible).Count -eq 1) 'Only one missing ID should be eligible'
$TemplatePath=Join-Path $root 'ImportGroupMembersTemplate.csv'
$output=Join-Path $testRoot 'missing.csv'
Save-Group @($comparison | Where-Object GroupEligible) $output
Assert ((Get-Content $output -Tail 1) -eq $missing -and @(Get-Content $output).Count -eq 3) 'Missing upload contains wrong IDs'
$before=(Get-FileHash $DatabasePath).Hash
Reject { Import-GroupMembers $groupId $catalog -CompleteSnapshot } 'Catalog must not be accepted as membership'
@('id','INVALID') | Set-Content (Join-Path $testRoot 'bad.csv')
Reject { Import-GroupMembers $groupId (Join-Path $testRoot 'bad.csv') -CompleteSnapshot } 'Invalid IDs must be rejected'
Assert ((Get-FileHash $DatabasePath).Hash -eq $before) 'Rejected import changed database'
@('groupId,memberId','66666666-6666-4666-8666-666666666666,11111111-1111-4111-8111-111111111111') | Set-Content (Join-Path $testRoot 'wrong.csv')
Reject { Import-GroupMembers $groupId (Join-Path $testRoot 'wrong.csv') -CompleteSnapshot } 'Cross-group file must be rejected'
# Header-only export is an explicitly imported empty snapshot, distinct from not loaded.
'id,displayName' | Set-Content (Join-Path $testRoot 'empty.csv')
foreach ($target in @('66666666-6666-4666-8666-666666666666','77777777-7777-4777-8777-777777777777','88888888-8888-4888-8888-888888888888')) {
 $null=Import-GroupMembers $target (Join-Path $testRoot 'empty.csv') -CompleteSnapshot
}
Assert (@(Compare-GroupMembers '66666666-6666-4666-8666-666666666666' $candidates Users | Where-Object GroupEligible).Count -eq 2) 'Empty assigned user group failed'
foreach ($target in @('66666666-6666-4666-8666-666666666666','77777777-7777-4777-8777-777777777777','88888888-8888-4888-8888-888888888888')) {
 Assert (@(Compare-GroupMembers $target $candidates Devices | Where-Object GroupEligible).Count -eq 0) 'Unsupported target allowed device upload'
}
Assert ((Get-GroupCatalog $groupId).MemberCount -eq 1) 'Other groups overwritten'
$null=Import-GroupCatalog $catalog
Assert ((Get-GroupCatalog $groupId).MemberCount -eq 1) 'Catalog refresh erased membership'
Assert ((Invoke-Database 'SELECT * FROM devices;' | ConvertTo-Json -Compress) -eq $deviceHash) 'Group imports changed device inventory'
Assert ((Invoke-Database 'PRAGMA integrity_check;').integrity_check -eq 'ok') 'Integrity failed'
# UI: captured lookup, catalog search, target selection and async comparison.
. (Join-Path $root 'Directory-Lens-GUI.ps1') -DatabasePath $DatabasePath -NoShow
$deadline=[DateTime]::UtcNow.AddSeconds(20)
while ($script:Busy -and [DateTime]::UtcNow -lt $deadline) { if ($script:Handle.IsCompleted) { Complete-Work };Start-Sleep -Milliseconds 20 }
$gw=Show-GroupWorkspace -Candidates $candidates -EntityType Devices -NoShow
function Wait-GroupWork {
 $deadline=[DateTime]::UtcNow.AddSeconds(20)
 while ($script:GBusy -and [DateTime]::UtcNow -lt $deadline) { if ($script:GHandle.IsCompleted) { Complete-GroupWork };Start-Sleep -Milliseconds 20 }
 Assert (-not $script:GBusy -and -not $script:GLastError) 'Group worker failed'
}
Wait-GroupWork
$G.Query.Text=$groupId
Start-GroupWork Search
Wait-GroupWork
$G.Groups.SelectedIndex=0
Assert $G.Compare.IsEnabled 'Loaded target should enable compare'
Start-GroupWork Compare -GroupId $groupId
Wait-GroupWork
Assert ($G.ExportMissing.IsEnabled -and $script:GResults.Count -eq 4) 'GUI missing export/report state failed'
$G.Query.Text='Example Users'
Start-GroupWork Search
Wait-GroupWork
Assert (-not $G.ExportMissing.IsEnabled -and $script:GResults.Count -eq 0) 'Changed target/search retained stale comparison'
$GTimer.Stop();$gw.Close()
$script:Results=@();$script:ResultType='Devices'
$gw=Open-GroupComparison -NoShow
Wait-GroupWork
Assert ($script:GCandidates.Count -eq 0 -and $G.ScopeText.Text -like 'No lookup captured*') 'Empty main-window scope failed'
$GTimer.Stop();$gw.Close();$Timer.Stop();$Window.Close()
'PASS: catalogs, member imports, unloaded/empty distinction, Object ID comparison, deduplication, unresolved guards, missing export, group-type restrictions, snapshot isolation, legacy migration and async GUI.'
