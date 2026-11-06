#requires -Version 5.1
$ErrorActionPreference='Stop'
# Reproduce UTF-8 console input used by hosted Windows runners.
[Console]::InputEncoding = New-Object Text.UTF8Encoding($true)
$root=Split-Path $PSScriptRoot
$testRoot=Join-Path $root ('work\tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $testRoot | Out-Null
$DatabasePath=Join-Path $testRoot 'test.db'
. (Join-Path $root 'Database.ps1')
. (Join-Path $root 'Csv-Helpers.ps1')
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
& (Join-Path $root 'Initialize-Database.ps1') -DatabasePath $DatabasePath
$summary=@(Get-DatabaseSummary)
Assert ($summary.Count -eq 3 -and @($summary | Where-Object Records -ne 0).Count -eq 0) 'Empty database must report three zero datasets'
foreach ($kind in @('Devices','Users','Intune')) {
 $file=@{Devices='Entra-Devices.csv';Users='Entra-Users.csv';Intune='Intune-Devices.csv'}[$kind]
 & (Join-Path $root 'Import-DirectoryLens.ps1') -Kind $kind -CsvPath (Join-Path $root ('examples\'+$file)) -DatabasePath $DatabasePath
}
Assert (@(Get-DatabaseSummary | Where-Object Records -eq 1).Count -eq 3) 'Imports must preserve other datasets'
$matches=@(Search-Devices @('LAB-PC-01'))
Assert ($matches.Count -eq 1 -and $matches[0].ObjectId -eq '11111111-1111-4111-8111-111111111111') 'Device identity match failed'
Assert (@(Search-Users 'example.user@example.invalid').Count -eq 1) 'User search failed'
$before=(Get-FileHash $DatabasePath).Hash
$bad=Join-Path $testRoot 'bad.csv'
'id,deviceId,displayName','invalid,invalid,BAD' | Set-Content $bad
$rejected=$false
try { & (Join-Path $root 'Import-DirectoryLens.ps1') -Kind Devices -CsvPath $bad -DatabasePath $DatabasePath } catch { $rejected=$true }
Assert $rejected 'Invalid import must fail'
Assert ((Get-FileHash $DatabasePath).Hash -eq $before) 'Invalid import changed database'
Assert (@(Get-ChildItem $testRoot -Filter '*.backup-*').Count -eq 3) 'Expected three pre-import backups'
$integrity=Invoke-Database 'PRAGMA integrity_check;'
Assert ($integrity.integrity_check -eq 'ok') 'Database integrity failed'
$TemplatePath=Join-Path $root 'ImportGroupMembersTemplate.csv'
$group=Join-Path $testRoot 'group.csv'
Save-Group $matches $group
Assert ((Get-Content $group -Tail 1) -eq '11111111-1111-4111-8111-111111111111') 'Group export must contain Object ID'
Assert (-not (@(Search-DeviceText 'LAB')[0].GroupEligible)) 'Partial match must not be group eligible'
$templates=@('Defender mode and transition','Device inventory and health','Recent successful logons','SentinelOne and MDE coexistence','Security-agent uninstall activity','Application Control audit and blocks','Missing or stale device telemetry','ASR audit and blocks','Network Protection audit and blocks','Controlled Folder Access','Defender configuration gaps')
foreach ($template in $templates) {
 $query=New-DeviceKql -Names @('LAB-PC-01','LAB-PC-02') -Template $template
 Assert ($query -match 'LAB-PC-01' -and $query -match 'LAB-PC-02') ('Missing KQL scope: '+$template)
}
# A new workspace starts empty and opens the import guide without modal errors.
$empty=Join-Path $testRoot 'empty.db'
. (Join-Path $root 'Directory-Lens-GUI.ps1') -DatabasePath $empty -NoShow
$deadline=[DateTime]::UtcNow.AddSeconds(20)
while ($script:Busy -and [DateTime]::UtcNow -lt $deadline) {
 if ($script:Handle.IsCompleted) { Complete-Work }
 Start-Sleep -Milliseconds 30
}
Assert (-not $script:Busy) 'GUI startup timed out'
Assert ($script:C.DataPanel.Visibility -eq 'Visible') 'Empty startup must open import guidance'
Assert ($script:C.SnapshotDetails.Text -match 'Intune: 0 records') 'Empty Intune summary missing'
Assert ($script:Window.Title -like 'Directory Lens*') 'Window branding incorrect'
# Branding uses an isolated workspace; the developer copy remains neutral.
$script:AppRoot=$testRoot
$databaseBefore=(Get-FileHash $empty).Hash
$C.BrandNameInput.Text='Example Lab'
$C.BrandSubtitleInput.Text='IDENTITY WORKSPACE'
$C.BrandAccentInput.Text='#F0B429'
$script:PendingLogo=Join-Path $root 'design\directory-icon\DirectoryIcon.png'
$C.BrandUseLogo.IsChecked=$true
Save-BrandingForm
Assert ((Read-Branding $testRoot).Name -eq 'Example Lab') 'Branding persistence failed'
Assert ($Window.Title -eq 'Example Lab | Offline lookup') 'Brand title failed'
Assert ($C.BrandLogo.Visibility -eq 'Visible' -and $Window.Icon) 'Custom logo failed'
Assert ($script:BrandForeground -eq '#12263E') 'Bright accent contrast failed'
$kql=New-KqlWindow
Assert ($kql.Title -eq 'Example Lab | KQL generator') 'KQL branding failed'
$kql.Close()
$settings=Join-Path $testRoot 'branding\settings.json'
$saved=(Get-FileHash $settings).Hash
$C.BrandAccentInput.Text='invalid'
$rejected=$false
try { Save-BrandingForm } catch { $rejected=$true }
Assert ($rejected -and (Get-FileHash $settings).Hash -eq $saved) 'Invalid branding must preserve saved settings'
$C.BrandReset.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
Assert ($Window.Title -eq 'Directory Lens | Offline lookup' -and -not (Read-Branding $testRoot).Logo) 'Reset branding failed'
Assert ((Get-FileHash $empty).Hash -eq $databaseBefore) 'Branding changed database'
$script:Timer.Stop()
$script:Window.Close()
Write-Output 'PASS: empty initialization, all three imports, isolation, identity lookup, invalid-import preservation, backups, integrity, group safeguards, eleven KQL templates WPF empty startup, branding persistence, logo, validation, contrast and reset.'
