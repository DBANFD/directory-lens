#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$testRoot=Join-Path $root ('work\reports-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $testRoot | Out-Null
$DatabasePath=Join-Path $testRoot 'test.db'
. (Join-Path $root 'Database.ps1')
. (Join-Path $root 'Csv-Helpers.ps1')
. (Join-Path $root 'Reports.ps1')
. (Join-Path $root 'Groups.ps1')
function Assert($Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Import-TestCsv($Kind,$Lines) {
    $path=Join-Path $testRoot ($Kind+'.csv')
    $Lines | Set-Content -LiteralPath $path -Encoding UTF8
    (Get-Item $path).LastWriteTimeUtc=[DateTime]'2020-01-01T00:00:00Z'
    & (Join-Path $root 'Import-DirectoryLens.ps1') -Kind $Kind -CsvPath $path -DatabasePath $DatabasePath
}
& (Join-Path $root 'Initialize-Database.ps1') -DatabasePath $DatabasePath
foreach ($report in @(Get-InventoryReportNames)) { Assert (@(Get-InventoryReport $report).Count -eq 0) "Empty report failed: $report" }
$a='aaaaaaaa-1111-4111-8111-111111111111'
$b='bbbbbbbb-2222-4222-8222-222222222222'
$identityC='cccccccc-3333-4333-8333-333333333333'
$d='dddddddd-4444-4444-8444-444444444444'
$e='eeeeeeee-5555-4555-8555-555555555555'
$o1='11111111-1111-4111-8111-111111111111'
$o2='22222222-2222-4222-8222-222222222222'
$o3='33333333-3333-4333-8333-333333333333'
$o4='44444444-4444-4444-8444-444444444444'
Import-TestCsv Devices @('id,deviceId,displayName,accountEnabled,owner',"$o1,$($a.ToUpperInvariant()),SAME-NAME,False,Example User", "$o2,$b,ENTRA-GAP,True,", "$o3,$a,ALIAS,True,example.user@example.invalid", "$o4,invalid,INVALID-ENTRA,False,Unknown Owner")
$rows=@(Get-InventoryReport 'Entra without Intune')
Assert ($rows.Count -eq 4 -and @($rows | Where-Object Assessment -eq 'Not loaded').Count -eq 4) 'Unloaded Intune must not imply missing'
Assert (@(Get-InventoryReport 'Missing or weak owner' | Where-Object Assessment -eq 'Not loaded').Count -eq 3) 'Unloaded users must not imply owner mismatch'
# Legacy databases must be readable without writing a migration during a report.
Invoke-Database 'DROP TABLE intune; DROP TABLE defender;' -Write
Assert (@(Get-InventoryReport 'Entra without Defender' | Where-Object Assessment -eq 'Not loaded').Count -eq 4) 'Legacy report failed'
Import-TestCsv Intune @('Device ID,Device name,Azure AD Device ID',"$o1,DIFFERENT-NAME,$a", "$o2,INTUNE-GAP,$identityC", "$o3,SAME-NAME,00000000-0000-0000-0000-000000000000", "$o4,INTUNE-DUP,$identityC")
Import-TestCsv Defender @('Device ID,Device Name,AAD Device Id',(('a'*40)+",DEFENDER-ALIAS,$a"),(('b'*40)+",DEFENDER-DUP,$a"),(('c'*40)+',SAME-NAME,invalid'),(('d'*40)+",DEFENDER-ONLY,$d"),(('e'*40)+",INTUNE-GAP,$e"),(('f'*40)+',BLANK-ID,'))
Import-TestCsv Users @('id,displayName,userPrincipalName',"$o1,Example User,example.user@example.invalid", "$o2,Example User,second.user@example.invalid")
$before=(Get-FileHash $DatabasePath).Hash
$rows=@(Get-InventoryReport 'Entra without Intune')
Assert ($rows.Count -eq 2 -and $rows.DeviceName -contains 'ENTRA-GAP' -and $rows.DeviceName -contains 'INVALID-ENTRA') 'Entra/Intune must use normalized valid IDs only'
Assert (@(Get-InventoryReport 'Entra without Defender').Count -eq 2) 'Entra/Defender gaps incorrect'
Assert (@(Get-InventoryReport 'Intune without valid Entra Device ID').Count -eq 1) 'Zero GUID was treated as a valid identity'
Assert (@(Get-InventoryReport 'Defender without valid AAD Device Id').Count -eq 2) 'Invalid/blank Defender IDs missing from report'
$rows=@(Get-InventoryReport 'Intune without Defender')
Assert ($rows.Count -eq 3 -and @($rows | Where-Object EntraDeviceId -eq $identityC).Count -eq 2) 'Intune/Defender missing or duplicate records lost'
Assert (@(Get-InventoryReport 'Defender without Intune').Count -eq 4) 'Defender/Intune gaps incorrect'
$rows=@(Get-InventoryReport 'Disabled Entra with inventory records')
Assert ($rows.Count -eq 1 -and $rows[0].RecordId -eq $o1 -and $rows[0].DefenderRecords -eq 2) 'Disabled view incorrectly linked invalid IDs or names'
$rows=@(Get-InventoryReport 'Defender-only records')
Assert ($rows.Count -eq 4 -and $rows.RecordId -contains ('e'*40)) 'Same names must not join orphan identities'
$rows=@(Get-InventoryReport 'Duplicate identities')
Assert ($rows.Count -eq 6 -and @($rows | Where-Object Dataset -eq 'Devices').Count -eq 2 -and @($rows | Where-Object Dataset -eq 'Intune').Count -eq 2) 'Duplicate identity report must count within each dataset and preserve records'
$rows=@(Get-InventoryReport 'Missing or weak owner')
Assert ($rows.Count -eq 3 -and $rows.DeviceName -notcontains 'ALIAS') 'Unique exact UPN owner must not be reported weak'
Assert (@($rows | Where-Object Finding -like 'Weak display-name match (2 imported users)*').Count -eq 1) 'Ambiguous display-name owner was not labelled weak'
$export=Join-Path $testRoot 'health.csv'
Save-Report $rows $export
$saved=@(Import-Csv $export)
Assert ($saved.Count -eq 3 -and $saved[0].Snapshots -like '*2020-01-01*' -and $saved[0].GeneratedUtc) 'CSV lost snapshot source times or generation time'
Assert ((Get-FileHash $DatabasePath).Hash -eq $before) 'Read-only reports changed database'

# Multi-group sweep includes loaded, empty, unloaded and restricted targets.
$catalog=Join-Path $testRoot 'groups.csv'
@('displayName,id,groupType,membershipType,source',"Existing group,$a,Security,assigned,Cloud", "Empty group,$b,Security,assigned,Cloud", "Unloaded group,$identityC,Security,assigned,Cloud", "Dynamic group,$d,Security,dynamic,Cloud") | Set-Content $catalog
$null=Import-GroupCatalog $catalog
$members=Join-Path $testRoot 'members.csv'
@('id',$o1) | Set-Content $members
$null=Import-GroupMembers $a $members -CompleteSnapshot
'id' | Set-Content $members
foreach ($group in @($b,$d)) { $null=Import-GroupMembers $group $members -CompleteSnapshot }
$candidates=@([pscustomobject]@{RequestedName='Existing';ObjectId=$o1;GroupEligible=$true},[pscustomobject]@{RequestedName='Missing';ObjectId=$o2;GroupEligible=$true},[pscustomobject]@{RequestedName='Duplicate';ObjectId=$o2;GroupEligible=$true},[pscustomobject]@{RequestedName='Unresolved';ObjectId=$o3;GroupEligible=$false})
$comparison=@(Compare-MultipleGroups @($a,$b,$identityC,$d,$a) $candidates Devices)
Assert ($comparison.Count -eq 16) 'Group sweep must deduplicate targets, not candidates'
Assert (@($comparison | Where-Object Comparison -eq 'Not loaded').Count -eq 4) 'Unloaded group treated as empty'
Assert (@($comparison | Where-Object GroupEligible).Count -eq 3) 'Multi-group policy or per-group input deduplication failed'
Assert (@($comparison | Where-Object { $_.TargetGroupId -eq $d -and $_.GroupEligible }).Count -eq 0) 'Dynamic target allowed uploads'
Assert ($comparison[0].MembershipSourceModifiedUtc -and $comparison[0].InventorySnapshots -like '*2020-01-01*') 'Comparison lost snapshot context'
Save-Report $comparison (Join-Path $testRoot 'comparison.csv')
Assert (@(Import-Csv (Join-Path $testRoot 'comparison.csv')).Count -eq 16) 'Combined CSV lost group rows'

# WPF flow: current report replaces KQL scope, all eleven templates stay local.
. (Join-Path $root 'Directory-Lens-GUI.ps1') -DatabasePath $DatabasePath -NoShow
$deadline=[DateTime]::UtcNow.AddSeconds(30)
while ($script:Busy -and [DateTime]::UtcNow -lt $deadline) { if ($Handle.IsCompleted) { Complete-Work }; Start-Sleep -Milliseconds 20 }
Assert (-not $script:Busy -and -not $script:LastError) 'Main startup failed'
function Wait-Report {
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while ($script:RBusy -and [DateTime]::UtcNow -lt $deadline) { if ($RHandle.IsCompleted) { Complete-ReportWork }; Start-Sleep -Milliseconds 20 }
    Assert (-not $script:RBusy -and -not $script:RLastError) "Report worker failed: $script:RLastError"
}
$rw=Show-InventoryReports -NoShow
Wait-Report
Assert ($RRows.Count -eq 2 -and $R.Export.IsEnabled -and $R.Snapshots.Text -like '*2020-01-01*') 'Initial report UI failed'
$R.Report.SelectedItem='Intune without Defender'
Wait-Report
Assert ($RRows.Count -eq 3 -and $R.Kql.IsEnabled) 'Changing report did not replace current scope'
$script:LastDeviceNames=@('UNRELATED-OLD-LOOKUP')
$kw=Open-ReportKql
Assert ($K.Names.Text -notlike '*UNRELATED*' -and $K.Names.Text -like '*INTUNE-GAP*') 'Report KQL reused old lookup scope'
foreach ($template in $K.Template.ItemsSource) {
    $K.Template.SelectedItem=$template
    Generate-KqlPreview
    Assert ($K.Query.Text -like '*INTUNE-GAP*' -and $K.Query.Text -notlike '*UNRELATED*' -and $K.Query.Text -like '*Not executed*') "Report scope failed for $template"
}
$kw.Close(); $rw.Close()
function Wait-Group {
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while ($script:GBusy -and [DateTime]::UtcNow -lt $deadline) { if ($GHandle.IsCompleted) { Complete-GroupWork }; Start-Sleep -Milliseconds 20 }
    Assert (-not $script:GBusy -and -not $script:GLastError) "Group worker failed: $script:GLastError"
}
$gw=Show-GroupWorkspace -Candidates $candidates -NoShow
Wait-Group
$G.Groups.SelectAll()
Assert ($G.Groups.SelectedItems.Count -eq 4 -and $G.Compare.IsEnabled -and -not $G.ImportMembers.IsEnabled) 'Multi-selection actions unsafe'
$G.Compare.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
Wait-Group
Assert ($GResults.Count -eq 16 -and $G.ExportReport.IsEnabled -and -not $G.ExportMissing.IsEnabled) 'Combined sweep enabled a mixed-target upload'
$G.Groups.SelectedItem=@($G.Groups.ItemsSource | Where-Object GroupId -eq $b)[0]
$G.Groups.UnselectAll(); $G.Groups.SelectedItem=@($G.Groups.ItemsSource | Where-Object GroupId -eq $b)[0]
Assert ($GResults.Count -eq 0 -and -not $G.ExportReport.IsEnabled) 'Changed selection retained stale export'
$G.Compare.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
Wait-Group
Assert ($GResults.Count -eq 4 -and $G.ExportMissing.IsEnabled) 'Single-target upload workflow failed after sweep'
$gw.Close(); $Timer.Stop(); $Window.Close()
Import-TestCsv Defender @('Device ID,Device Name,AAD Device Id',(('a'*40)+",REFRESHED,$identityC"))
$refreshed=@(Get-InventoryReport 'Intune without Defender')
Assert ($refreshed.Count -eq 2 -and $refreshed.EntraDeviceId -notcontains $identityC) 'Refreshed inventory reused a stale gap list'
Assert ((Invoke-Database 'PRAGMA integrity_check;').integrity_check -eq 'ok') 'Database integrity failed'
'PASS: inventory gaps, health, valid-ID joins, snapshot age, CSVs, eleven report-scoped KQL templates and multi-group WPF flow.'

