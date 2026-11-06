#requires -Version 5.1
[CmdletBinding()]
param([string]$DatabasePath, [switch]$NoShow)

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start with Windows PowerShell -STA, or use Start-GUI.cmd.' }
$ErrorActionPreference='Stop'
$script:AppRoot=$PSScriptRoot
if (-not $DatabasePath) { $DatabasePath=Join-Path $PSScriptRoot 'Directory-Lens.db' }
$script:DatabasePath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DatabasePath)
$TemplatePath=Join-Path $PSScriptRoot 'ImportGroupMembersTemplate.csv'
$NameColumn=$null
. (Join-Path $PSScriptRoot 'Csv-Helpers.ps1')
. (Join-Path $PSScriptRoot 'Database.ps1')
. (Join-Path $PSScriptRoot 'Branding.ps1')
. (Join-Path $PSScriptRoot 'Groups.ps1')
. (Join-Path $PSScriptRoot 'Group-UI.ps1')
if (-not (Test-Path -LiteralPath $DatabasePath)) { & (Join-Path $PSScriptRoot 'Initialize-Database.ps1') -DatabasePath $DatabasePath }

function Show-Problem([string]$Message) {
    $script:C.StatusText.Text=$Message
    [void][Windows.MessageBox]::Show($script:Window,$Message,$script:Brand.Name,[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Warning)
}
function Set-Status([string]$Text) { $script:C.StatusText.Text=$Text }
function Set-GridColumns([string]$Type) {
    $script:C.ResultsGrid.Columns.Clear()
    $definitions = if ($Type -eq 'Users') {
        @(@('Name','DisplayName',210),@('Email / UPN','UPN',300),@('Object ID','ObjectId',290),@('Department','Department',160),@('Enabled','Enabled',85))
    } elseif ($Type -eq 'BulkUsers') {
        @(@('Requested user','RequestedUser',220),@('Match','Status',115),@('Name','DisplayName',210),@('UPN','UPN',290),@('Object ID','ObjectId',290),@('Matched by','MatchBy',100),@('Input row','InputRow',90))
    } else {
        @(@('Device name','DeviceName',190),@('Match','Status',130),@('OS','OS',100),@('Defender link','DefenderLink',230),@('Defender onboarding','DefenderOnboardingStatus',170),@('Sensor health','DefenderHealthStatus',130),@('Risk','DefenderRiskLevel',100),@('Exposure','DefenderExposureLevel',100),@('Defender last update','DefenderLastdeviceupdate',190),@('Defender device name','DefenderDeviceName',220),@('Defender device ID','DefenderDeviceID',300),@('Defender records','DefenderRecordCount',110),@('Intune link','IntuneLink',220),@('Primary user UPN','IntunePrimaryuserUPN',270),@('Compliance (snapshot)','IntuneCompliance',165),@('Last check-in','IntuneLastcheckin',200),@('Encrypted','IntuneEncrypted',95),@('Model','IntuneModel',180),@('Serial number','IntuneSerialnumber',160),@('Managed by','IntuneManagedby',120),@('Ownership','IntuneOwnership',100),@('OS version','IntuneOSversion',150),@('Intune device name','IntuneDevicename',190),@('Intune device ID','IntuneDeviceID',290),@('Enrollments','IntuneEnrollmentCount',100),@('Device ID','DeviceId',290),@('Object ID','ObjectId',290),@('Requested name','RequestedName',190),@('Owner label','EntraOwnerText',200),@('Group eligible','GroupEligible',115))
    }
    foreach ($definition in $definitions) {
        $col=New-Object Windows.Controls.DataGridTextColumn
        $col.Header=$definition[0]
        $col.Binding=New-Object Windows.Data.Binding($definition[1])
        $col.Width=[Windows.Controls.DataGridLength]::new([double]$definition[2])
        $col.MinWidth=70
        [void]$script:C.ResultsGrid.Columns.Add($col)
    }
}
function Update-Actions {
    $selected=$script:C.ResultsGrid.SelectedItem
    $selectionCount=$script:C.ResultsGrid.SelectedItems.Count
    $hasSelection=($null -ne $selected -and -not $script:Busy)
    $script:C.ViewDetails.IsEnabled=($hasSelection -and $selectionCount -eq 1)
    foreach ($key in @('CopyName','CopyIdentifier','CopyObject')) { $script:C[$key].IsEnabled=($hasSelection -and $selectionCount -eq 1) }
    $script:C.ExportResults.IsEnabled=($script:Results.Count -gt 0 -and -not $script:Busy)
    $eligible=@($script:Results | Where-Object { $_.PSObject.Properties['GroupEligible'] -and $_.GroupEligible }).Count
    if ($script:ResultType -eq 'Users') {
        $invalid=@($script:C.ResultsGrid.SelectedItems | Where-Object { -not (Test-Guid $_.ObjectId) }).Count
        $script:C.ExportGroup.IsEnabled=($selectionCount -gt 0 -and $invalid -eq 0 -and -not $script:Busy)
    } else {
        $script:C.ExportGroup.IsEnabled=($eligible -gt 0 -and -not $script:Busy)
    }
    if ($hasSelection -and $selectionCount -gt 1) {
        $script:C.SelectionLabel.Text="$selectionCount users selected for group export. Select one row to use copy buttons."
    } elseif ($hasSelection) {
        $name=if ($script:ResultType -in @('Users','BulkUsers')) { $selected.DisplayName } else { $selected.DeviceName }
        $script:C.SelectionLabel.Text="$name   |   Object ID: $($selected.ObjectId)"
    } else { $script:C.SelectionLabel.Text=if ($script:ResultType -eq 'Users') { 'Select users for group export. Hold Ctrl to pick rows, or Shift to select a range.' } else { 'Select a result to copy its details.' } }
}
function Set-Busy([bool]$Value) {
    $script:Busy=$Value
    foreach ($key in @('NavDevices','NavUsers','NavBulk','NavBulkUsers','NavKql','NavData','NavBranding','NavGroups','CompareGroup','SearchButton','SearchText','ChooseCsv','ColumnPicker','NoHeaderCheck','ExampleButton','ImportDevices','ImportUsers','ImportIntune','ImportDefender','ReloadSummary')) { $script:C[$key].IsEnabled= -not $Value }
    $script:C.Progress.Visibility=if ($Value) { 'Visible' } else { 'Collapsed' }
    if (-not $Value) { Update-CsvPreview } else { $script:C.RunBulk.IsEnabled=$false }
    Update-Actions
}
function Clear-Results {
    $script:Results=@()
    $script:C.ResultsGrid.ItemsSource=$null
    $script:C.EmptyState.Visibility='Visible'
    $script:C.EmptyTitle.Text='Your directory, ready to search'
    $script:C.EmptyHint.Text='Enter a name above to see matching records.'
    $script:C.ResultCount.Text='Search to get started'
    Update-Actions
}
function Set-Page([string]$Page) {
    $script:Page=$Page
    $script:ResultType=if ($Page -eq 'Users') { 'Users' } elseif ($Page -eq 'BulkUsers') { 'BulkUsers' } else { 'Devices' }
    Clear-Results
    $script:C.ResultsGrid.SelectionMode=if ($Page -eq 'Users') { 'Extended' } else { 'Single' }
    Set-GridColumns $script:ResultType
    $script:C.SearchText.Text=''
    foreach ($pair in @(@('Devices','NavDevices'),@('Users','NavUsers'),@('Bulk','NavBulk'),@('BulkUsers','NavBulkUsers'),@('Data','NavData'))) {
        $script:C[$pair[1]].Background=if ($Page -eq $pair[0]) { $script:Brand.Accent } else { 'Transparent' }
        $script:C[$pair[1]].Foreground=if ($Page -eq $pair[0]) { $script:BrandForeground } else { '#CAD6E5' }
    }
    $script:C.SearchPanel.Visibility=if ($Page -in @('Devices','Users')) { 'Visible' } else { 'Collapsed' }
    $script:C.BulkPanel.Visibility=if ($Page -in @('Bulk','BulkUsers')) { 'Visible' } else { 'Collapsed' }
    $script:C.ResultsPanel.Visibility=if ($Page -eq 'Data') { 'Collapsed' } else { 'Visible' }
    $script:C.DataPanel.Visibility=if ($Page -eq 'Data') { 'Visible' } else { 'Collapsed' }
    $script:C.ActionsPanel.Visibility=if ($Page -eq 'Data') { 'Collapsed' } else { 'Visible' }
    $script:C.CopyIdentifier.Content=if ($Page -in @('Users','BulkUsers')) { 'Copy email / UPN' } else { 'Copy Device ID' }
    $script:C.ExportGroup.Visibility='Visible'
    $script:C.ExportGroup.Content=if ($Page -eq 'Users') { 'Export selected users' } elseif ($Page -eq 'BulkUsers') { 'Export matched users' } else { 'Export group members' }
    $script:C.ExportGroup.ToolTip=if ($Page -eq 'Users') { 'Create an Entra membership CSV for selected users only.' } elseif ($Page -eq 'BulkUsers') { 'Export all uniquely resolved users from the CSV. Unresolved rows are excluded.' } else { 'Export all eligible device matches in the current results.' }
    if ($Page -in @('Bulk','BulkUsers')) {
        $script:CsvPath=''; $script:CsvRows=@(); $script:CsvColumns=@()
        $script:C.ColumnPicker.ItemsSource=$null
        $script:C.NoHeaderCheck.IsChecked=$false
        $script:C.RunBulk.Content=if ($Page -eq 'BulkUsers') { 'Check users' } else { 'Check devices' }
        $script:C.CsvColumnLabel.Text=if ($Page -eq 'BulkUsers') { 'UPN, Object ID, or full display-name column' } else { 'Device-name column' }
        $script:C.NoHeaderCheck.Content=if ($Page -eq 'BulkUsers') { 'First row is a user (no header)' } else { 'First row is a device (no header)' }
        $script:C.CsvFileLabel.Text='Choose a CSV to begin.'
        $script:C.CsvPreview.Text=if ($Page -eq 'BulkUsers') { 'Prefer full sign-in UPNs or Object IDs. Email aliases are not in this snapshot. Names must match exactly.' } else { 'Choose a file to preview its columns and device names.' }
    }
    switch ($Page) {
        'Devices' {
            $script:C.PageTitle.Text='Device directory'
            $script:C.PageSubtitle.Text='Find a device, inspect its identity, and copy what you need.'
            $script:C.SearchLabel.Text='Full or partial device name'
            $script:C.SearchHint.Text='Entra identities enriched by Intune and Defender Entra device IDs. Scroll for inventory columns; Details and exports include all inventory fields.'
        }
        'Users' {
            $script:C.PageTitle.Text='User directory'
            $script:C.PageSubtitle.Text='Search name words in any order, part of an email, or a full Object ID.'
            $script:C.SearchLabel.Text='Name, email / UPN, or Object ID'
            $script:C.SearchHint.Text='Exact matches appear first. Ctrl-click or Shift-click rows to select users for group export.'
        }
        'Bulk' {
            $script:C.PageTitle.Text='Bulk device lookup'
            $script:C.PageSubtitle.Text='Choose a CSV, preview its names, then check against the snapshot.'
            $script:C.EmptyHint.Text='Load a CSV and check its name column to begin.'
            Update-CsvPreview
        }
        'BulkUsers' {
            $script:C.PageTitle.Text='Bulk user lookup'
            $script:C.PageSubtitle.Text='Resolve a user list, review missing or ambiguous entries, and export group members.'
            $script:C.EmptyHint.Text='Load a CSV, choose its user column, then click Check users.'
            Update-CsvPreview
        }
        'Data' {
            $script:C.PageTitle.Text='Data and refresh'
            $script:C.PageSubtitle.Text='Know which exports you are searching, and refresh local snapshots.'
        }
    }
    Set-Status 'Ready. Working from local snapshots.'
}
function Set-Results([object[]]$Rows) {
    $script:Results=@($Rows)
    if ($script:ResultType -eq 'Devices') {
        $field=if ($script:Page -eq 'Bulk') { 'RequestedName' } else { 'DeviceName' }
        $script:LastDeviceNames=@($Rows | ForEach-Object { [string]$_.$field } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $script:LastDeviceSource=if ($script:Page -eq 'Bulk') { 'Last bulk-device input, including names not found in Entra' } else { 'All full device names returned by the last device search' }
    }
    $shown=@($Rows | Select-Object -First 5000)
    $script:C.ResultsGrid.ItemsSource=[object[]]$shown
    $script:C.EmptyState.Visibility=if ($Rows.Count) { 'Collapsed' } else { 'Visible' }
    $script:C.EmptyTitle.Text='No matching records'
    $script:C.EmptyHint.Text='Try less text, check the selected CSV column, or review the snapshot dates.'
    $script:C.ResultCount.Text=('{0:N0} results' -f $Rows.Count)
    if ($Rows.Count -gt 5000) { $script:C.ResultCount.Text+=' | showing first 5,000; exports include all' }
    if ($script:ResultType -eq 'Devices') {
        $eligible=@($Rows | Where-Object GroupEligible).Count
        Set-Status ("{0:N0} result rows. {1:N0} exact, unambiguous rows eligible for group export. Partial and unresolved matches are excluded." -f $Rows.Count,$eligible)
    } elseif ($script:ResultType -eq 'BulkUsers') {
        $eligible=@($Rows | Where-Object GroupEligible | Select-Object -ExpandProperty ObjectId -Unique).Count
        $unresolved=@($Rows | Where-Object { -not $_.GroupEligible } | Select-Object -ExpandProperty InputRow -Unique).Count
        Set-Status "$eligible unique users ready for group export; $unresolved unresolved input rows excluded. Export results for the full review report."
    } else { Set-Status ("{0:N0} users matched. Select rows for group export; Ctrl-click adds individual users, Shift-click selects a range." -f $Rows.Count) }
    Update-Actions
}
function Apply-Summary([object[]]$Rows) {
    $devices=@($Rows | Where-Object Dataset -eq 'Devices')
    $users=@($Rows | Where-Object Dataset -eq 'Users')
    if ($devices.Count -ne 1 -or $users.Count -ne 1) { throw 'Database does not contain the expected snapshot information.' }
    $script:C.DeviceCount.Text=('{0:N0}' -f $devices[0].Records)
    $script:C.UserCount.Text=('{0:N0}' -f $users[0].Records)
    $parts=foreach ($row in $Rows) {
        "$($row.Dataset): $($row.Records) records`nSource: $($row.SourceFile)`nImported (UTC): $($row.ImportedUtc)`nFile modified (UTC): $($row.SourceModifiedUtc)"
    }
    $script:C.SnapshotDetails.Text=($parts -join "`n`n")+"`n`nSource filenames may identify an older export date. Import time is not data freshness. Intune compliance and encryption are exported observations; check Last check-in. Multiple enrollments and Defender identities remain separate rows. Defender health, risk and onboarding are exported observations; Last device update is not a live heartbeat.`n`nDatabase: $script:DatabasePath"
}
function Start-Work([string]$Task, [string]$Query='', [string]$CsvPath='', [string]$Column='', [bool]$Headerless=$false) {
    if ($script:Busy) { return }
    $script:LastError=$null
    if ($Task -in @('Devices','Users','Bulk','BulkUsers')) { Clear-Results }
    Set-Busy $true
    Set-Status $(if ($Task -like 'Import*') { 'Importing snapshot and creating a backup. Large imports may take several minutes...' } else { 'Working... You can move or resize this window while the lookup runs.' })
    $script:Task=$Task
    $script:Worker=[powershell]::Create()
    [void]$script:Worker.AddScript({
        param($Root,$Db,$Task,$Query,$CsvPath,$Column,$Headerless)
        $ErrorActionPreference='Stop'
        $DatabasePath=$Db
        $NameColumn=$Column
        . (Join-Path $Root 'Database.ps1')
        . (Join-Path $Root 'Csv-Helpers.ps1')
        switch ($Task) {
            'Devices' { Search-DeviceText $Query }
            'Users' { Search-Users $Query }
            'Bulk' { $names=@(Get-NamesFromCsv $CsvPath -NoHeader:$Headerless); Search-Devices $names }
            'BulkUsers' { $values=@(Get-NamesFromCsv $CsvPath -NoHeader:$Headerless); Search-UserList $values }
            'Summary' { Get-DatabaseSummary }
            'ImportDevices' { & (Join-Path $Root 'Import-DirectoryLens.ps1') -Kind Devices -CsvPath $CsvPath -DatabasePath $Db; Get-DatabaseSummary }
            'ImportDefender' { & (Join-Path $Root 'Import-DirectoryLens.ps1') -Kind Defender -CsvPath $CsvPath -DatabasePath $Db; Get-DatabaseSummary }
            'ImportIntune' { & (Join-Path $Root 'Import-DirectoryLens.ps1') -Kind Intune -CsvPath $CsvPath -DatabasePath $Db; Get-DatabaseSummary }
            'ImportUsers' { & (Join-Path $Root 'Import-DirectoryLens.ps1') -Kind Users -CsvPath $CsvPath -DatabasePath $Db; Get-DatabaseSummary }
        }
    }.ToString()).AddArgument($script:AppRoot).AddArgument($script:DatabasePath).AddArgument($Task).AddArgument($Query).AddArgument($CsvPath).AddArgument($Column).AddArgument($Headerless)
    $script:Handle=$script:Worker.BeginInvoke()
    $script:Timer.Start()
}
function Complete-Work {
    if (-not $script:Handle.IsCompleted) { return }
    $script:Timer.Stop()
    try {
        $rows=@($script:Worker.EndInvoke($script:Handle))
        if ($script:Worker.HadErrors) { throw ($script:Worker.Streams.Error | Out-String) }
        if ($script:Task -in @('Summary','ImportDevices','ImportUsers','ImportIntune','ImportDefender')) {
            Apply-Summary $rows
            if ($script:Task -eq 'Summary' -and @($rows | Where-Object { $_.Records -gt 0 }).Count -eq 0) { Set-Page 'Data' }
            Set-Status $(if ($script:Task -like 'Import*') { 'Snapshot refreshed. A pre-import database backup was created.' } else { 'Ready. Working from local snapshots.' })
        } else { Set-Results $rows }
    } catch {
        $script:LastError=$_.Exception.Message
        if ($NoShow) { Set-Status $script:LastError } else { Show-Problem $script:LastError }
    } finally {
        $script:Worker.Dispose(); $script:Worker=$null
        Set-Busy $false
    }
}
function Open-CsvDialog {
    $dialog=New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter='CSV and text files (*.csv;*.tsv;*.txt)|*.csv;*.tsv;*.txt|All files (*.*)|*.*'
    $dialog.Title='Choose a CSV export or lookup list'
    if ($dialog.ShowDialog($script:Window)) { return $dialog.FileName }
    return $null
}
function New-OutputDialog([string]$Prefix) {
    $dialog=New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter='CSV UTF-8 (*.csv)|*.csv'
    $dialog.DefaultExt='.csv'
    $dialog.FileName=$Prefix+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'.csv'
    $dialog.InitialDirectory=(Get-Location).ProviderPath
    $dialog.OverwritePrompt=$false
    if ($dialog.ShowDialog($script:Window)) { Assert-NewPath $dialog.FileName; return $dialog.FileName }
    return $null
}
function Load-CsvPreview([string]$Path) {
    $script:CsvPath=''; $script:CsvRows=@(); $script:CsvColumns=@()
    $script:C.ColumnPicker.ItemsSource=$null
    $script:C.NoHeaderCheck.IsChecked=$false
    $script:C.RunBulk.IsEnabled=$false
    $script:C.CsvFileLabel.Text='Reading CSV...'
    try {
        $rows=@(Read-CsvFile $Path)
        $header=Get-Content -LiteralPath $Path -TotalCount 1
        if ([string]::IsNullOrWhiteSpace($header)) { throw 'The file is empty or has a blank first row.' }
        $probe=if ($rows.Count) { $rows[0] } else { @($header,$header) | ConvertFrom-Csv }
        $columns=@($probe.PSObject.Properties.Name)
        $script:CsvPath=$Path; $script:CsvRows=$rows; $script:CsvColumns=$columns
        $script:C.ColumnPicker.ItemsSource=[string[]]$columns
        $aliases=if ($script:Page -eq 'BulkUsers') { @('userPrincipalName','UPN','Email','EmailAddress','ObjectId','id','displayName','Name','User','UserName') } else { @('DeviceName','displayName','ComputerName','Name','Hostname','Device','AssetName','Host','Computer','EndpointName','DNSHostName') }
        $known=@($columns | Where-Object { ($_ -replace '[\s_-]','') -in $aliases })
        if ($known.Count -eq 1) { $script:C.ColumnPicker.SelectedItem=$known[0] } else { $script:C.ColumnPicker.SelectedIndex=-1 }
        $script:C.CsvFileLabel.Text=[IO.Path]::GetFileName($Path)
        $script:C.CsvFileLabel.ToolTip=$Path
        Update-CsvPreview
    } catch { $script:C.CsvFileLabel.Text='No CSV selected'; throw }
}
function Update-CsvPreview {
    if (-not $script:CsvPath) { $script:C.RunBulk.IsEnabled=$false; return }
    $script:C.NoHeaderCheck.IsEnabled=($script:CsvColumns.Count -eq 1 -and -not $script:Busy)
    $headerless=[bool]$script:C.NoHeaderCheck.IsChecked
    $script:C.ColumnPicker.IsEnabled=(-not $headerless -and -not $script:Busy)
    $column=[string]$script:C.ColumnPicker.SelectedItem
    if ($headerless) { $column=$script:CsvColumns[0] }
    if (-not $column) {
        $script:C.CsvPreview.Text='Choose the lookup column. Multiple or unfamiliar headers require your selection.'
        $script:C.RunBulk.IsEnabled=$false
        return
    }
    $samples=@($script:CsvRows | Select-Object -First 5 | ForEach-Object { [string]$_.$column })
    $count=$script:CsvRows.Count
    if ($headerless) { $samples=@($column)+$samples; $count++ }
    $hint=if ($script:Page -eq 'BulkUsers') { 'Exact UPN / Object ID / full-name matching. Missing and ambiguous users are excluded from group export.' } else { 'Bulk matching is exact. Missing and duplicate names remain visible in results.' }
    $script:C.CsvPreview.Text=("{0:N0} rows | Preview: {1}`n{2}" -f $count,($samples -join '  |  '),$hint)
    $script:C.RunBulk.IsEnabled=($count -gt 0 -and -not $script:Busy)
}
function Copy-Selected([string]$Field) {
    if ($script:C.ResultsGrid.SelectedItems.Count -ne 1) { return }
    $row=$script:C.ResultsGrid.SelectedItem
    if ($null -eq $row) { return }
    $text=[string]$row.$Field
    if (-not $text) { Set-Status 'This field is empty in the selected record.'; return }
    [Windows.Clipboard]::SetText($text)
    Set-Status "$Field copied to clipboard."
}
function Get-GroupExportPlan {
    if ($script:ResultType -eq 'BulkUsers') {
        $rows=@($script:Results)
        $ids=@($rows | Where-Object GroupEligible | Select-Object -ExpandProperty ObjectId -Unique)
        if (-not $ids.Count) { throw 'No uniquely resolved users to export. Review the lookup results.' }
        $excluded=@($rows | Where-Object { -not $_.GroupEligible } | Select-Object -ExpandProperty InputRow -Unique).Count
        return [pscustomobject]@{
            Rows=$rows; Prefix='Directory-Lens-UserGroupMembers'
            Message="Export $($ids.Count) unique user Object IDs from this CSV lookup?`n`n$excluded missing, blank or ambiguous input rows are excluded. Review those rows in Export results.`n`nThis exports all uniquely matched users in the lookup, not only a selected row. The file is ready for manual Entra upload; no group is changed automatically."
        }
    }
    if ($script:ResultType -eq 'Users') {
        $selected=@($script:C.ResultsGrid.SelectedItems)
        if (-not $selected.Count) { throw 'Select at least one user for group export.' }
        $rows=@(foreach ($user in $selected) {
            if (-not (Test-Guid $user.ObjectId)) { throw 'A selected user has a missing or invalid Object ID. No export was created.' }
            [pscustomobject]@{ RequestedName=$user.UPN; ObjectId=([guid]$user.ObjectId).ToString(); GroupEligible=$true }
        })
        $count=@($rows | Select-Object -ExpandProperty ObjectId -Unique).Count
        $preview=@($selected | Select-Object -First 10 | ForEach-Object { "$($_.DisplayName)  <$($_.UPN)>" }) -join "`n"
        if ($selected.Count -gt 10) { $preview+="`n...and $($selected.Count-10) more selected users." }
        return [pscustomobject]@{
            Rows=$rows; Prefix='Directory-Lens-UserGroupMembers'
            Message="Export $count unique user Object IDs from $($selected.Count) selected rows?`n`n$preview`n`nOnly selected users will be included. This creates a CSV for manual upload; it does not change a group."
        }
    }
    $ids=@($script:Results | Where-Object GroupEligible | Select-Object -ExpandProperty ObjectId -Unique)
    if (-not $ids.Count) { throw 'No eligible exact device matches to export.' }
    $excluded=@($script:Results | Where-Object { -not $_.GroupEligible }).Count
    return [pscustomobject]@{
        Rows=$script:Results; Prefix='Directory-Lens-GroupMembers'
        Message="Export $($ids.Count) unique device Object IDs?`n`n$excluded partial or unresolved result rows will be excluded. This creates a CSV for manual upload; it does not change a group."
    }
}
function New-KqlWindow {
    [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Directory Lens | KQL generator" Width="1080" Height="830" MinWidth="860" MinHeight="700" WindowStartupLocation="CenterOwner" Background="#F3F5F8" FontFamily="Segoe UI" FontSize="13" Foreground="#18283B">
 <Grid Margin="24"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <StackPanel><TextBlock Text="KQL generator" FontSize="25" FontWeight="SemiBold"/><TextBlock Text="Build a device-scoped query for Defender Advanced Hunting. Nothing is run or uploaded." Foreground="#63768A" Margin="0,6,0,16"/></StackPanel>
  <Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/><ColumnDefinition Width="140"/></Grid.ColumnDefinitions>
   <StackPanel Margin="0,0,14,12"><TextBlock Text="Query template" Margin="0,0,0,6"/><ComboBox x:Name="Template" Padding="8"/></StackPanel>
   <StackPanel Grid.Column="1" Margin="0,0,14,12"><TextBlock x:Name="DaysLabel" Text="Lookback (days)" Margin="0,0,0,6"/><ComboBox x:Name="Days" Padding="8"/></StackPanel>
   <Button x:Name="Generate" Grid.Column="2" Content="Generate query" VerticalAlignment="Bottom" Margin="0,0,0,12" Padding="12" Background="#1469C0" Foreground="White"/>
  </Grid>
  <Border Grid.Row="2" Background="White" CornerRadius="8" Padding="14" Margin="0,0,0,14"><StackPanel>
   <DockPanel><Button x:Name="UseLast" DockPanel.Dock="Right" Content="Use last device lookup" Padding="10,6"/><TextBlock Text="One or multiple devices - one name per line" VerticalAlignment="Center" FontWeight="SemiBold"/></DockPanel>
   <TextBox x:Name="Names" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Height="115" Margin="0,10,0,8" Padding="8" FontFamily="Consolas"/>
   <TextBlock x:Name="SourceHint" TextWrapping="Wrap" Foreground="#63768A" FontSize="11"/>
   <StackPanel x:Name="ApplicationPanel" Visibility="Collapsed" Margin="0,8,0,0"><TextBlock Text="Optional application filename (exact match, e.g. AASW.exe; leave blank for all)" FontSize="11"/><TextBox x:Name="Application" Padding="6" Margin="0,4,0,0"/></StackPanel>
   <TextBlock x:Name="TemplateHint" TextWrapping="Wrap" Foreground="#63768A" FontSize="11" Margin="0,6,0,0"/>
   <TextBlock Text="FQDNs become short hostnames; duplicates are removed. Maximum 10,000 unique names." Foreground="#63768A" FontSize="11" Margin="0,5,0,0"/>
  </StackPanel></Border>
  <TextBox x:Name="Query" Grid.Row="3" AcceptsReturn="True" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" FontFamily="Consolas" FontSize="12" Background="#12263E" Foreground="#E2EDF7" Padding="14"/>
  <StackPanel Grid.Row="4" Margin="0,12,0,0"><TextBlock x:Name="Status" Text="Choose a template and add devices, then generate a query." TextWrapping="Wrap" Foreground="#63768A" FontSize="11" Margin="0,0,0,10"/><DockPanel><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="Copy" Content="Copy query" Padding="14,8" IsEnabled="False" Margin="0,0,10,0"/><Button x:Name="Save" Content="Save .kql" Padding="14,8" IsEnabled="False" Margin="0,0,10,0"/><Button x:Name="Close" Content="Close" Padding="14,8"/></StackPanel><TextBlock Text="Generated locally. Review and run in your Defender portal." VerticalAlignment="Center" Foreground="#63768A" FontSize="11"/></DockPanel></StackPanel>
 </Grid>
</Window>
'@
    $script:KqlWindow=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader($markup)))
    if ($script:Window.IsVisible) { $script:KqlWindow.Owner=$script:Window }
    $script:KqlWindow.Icon=$script:Window.Icon
    $script:KqlWindow.Title=$script:Brand.Name+' | KQL generator'
    $script:K=@{}
    foreach ($name in @('Template','Days','DaysLabel','Generate','UseLast','Names','SourceHint','ApplicationPanel','Application','TemplateHint','Query','Status','Copy','Save','Close')) { $script:K[$name]=$script:KqlWindow.FindName($name) }
    $K.Template.ItemsSource=[string[]]@('Defender mode and transition','Device inventory and health','Recent successful logons','SentinelOne and MDE coexistence','Security-agent uninstall activity','Application Control audit and blocks','Missing or stale device telemetry','ASR audit and blocks','Network Protection audit and blocks','Controlled Folder Access','Defender configuration gaps')
    $K.Template.SelectedIndex=0
    $K.Days.ItemsSource=[int[]]@(1,2,7,14,30)
    $K.Days.SelectedItem=2
    $K.UseLast.IsEnabled=($script:LastDeviceNames.Count -gt 0)
    $K.Names.Text=$script:LastDeviceNames -join "`r`n"
    $K.SourceHint.Text=if ($script:LastDeviceNames.Count) { $script:LastDeviceSource } else { 'Paste names here, or first run a device or bulk-device lookup. Users are never used as device targets.' }
    $K.Generate.Add_Click({ try { Generate-KqlPreview } catch { $K.Status.Text=$_.Exception.Message } })
    $K.UseLast.Add_Click({ $K.Names.Text=$script:LastDeviceNames -join "`r`n"; $K.SourceHint.Text=$script:LastDeviceSource })
    $K.Names.Add_TextChanged({ $K.SourceHint.Text='Using the names shown above. Edit this list to set the query scope.'; Invalidate-KqlPreview })
    $K.Template.Add_SelectionChanged({
        $K.Days.IsEnabled=($K.Template.SelectedItem -ne 'Device inventory and health')
        $isAssessment=$K.Template.SelectedItem -in @('Missing or stale device telemetry','Defender configuration gaps')
        $K.DaysLabel.Text=if ($isAssessment) { 'Stale after (days)' } else { 'Lookback (days)' }
        $K.Days.ToolTip=if ($isAssessment) { 'Freshness threshold, not an event filter. Use a wider portal time range to see older records.' } else { 'Event lookback; the Defender portal time range also applies.' }
        $K.ApplicationPanel.Visibility=if ($K.Template.SelectedItem -in @('ASR audit and blocks','Network Protection audit and blocks','Controlled Folder Access')) { 'Visible' } else { 'Collapsed' }
        $K.TemplateHint.Text=switch ($K.Template.SelectedItem) {
            'ASR audit and blocks' { 'Shows audit, block and warning-bypass evidence. Application matches the affected filename or initiating process. Event counts can be throttled.' }
            'Network Protection audit and blocks' { 'Shows audited/blocked destinations and initiating applications. This is not a full firewall or connectivity test.' }
            'Controlled Folder Access' { 'Shows audited/blocked protected-folder access. Application matches the initiating process. No events does not rule out other write failures.' }
            'Defender configuration gaps' { 'Shows latest applicable, noncompliant antivirus assessments, including stale findings. No results may mean missing coverage; this is not a live check.' }
            default { '' }
        }
        Invalidate-KqlPreview
    })
    $K.Application.Add_TextChanged({ Invalidate-KqlPreview })
    $K.Days.Add_SelectionChanged({ Invalidate-KqlPreview })
    $K.Copy.Add_Click({ try { [Windows.Clipboard]::SetText($K.Query.Text); $K.Status.Text='Query copied. Paste it into Defender Advanced Hunting.' } catch { $K.Status.Text=$_.Exception.Message } })
    $K.Save.Add_Click({ try {
        $dialog=New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Filter='KQL query (*.kql)|*.kql'; $dialog.DefaultExt='.kql'; $dialog.OverwritePrompt=$false
        $dialog.FileName='Directory-Lens-DeviceQuery_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'.kql'
        $dialog.InitialDirectory=(Get-Location).ProviderPath
        if ($dialog.ShowDialog($script:KqlWindow)) { Assert-NewPath $dialog.FileName; [IO.File]::WriteAllText($dialog.FileName,$K.Query.Text,(New-Object Text.UTF8Encoding($false))); $K.Status.Text="Query saved: $($dialog.FileName)" }
    } catch { $K.Status.Text=$_.Exception.Message } })
    $K.Close.Add_Click({ $script:KqlWindow.Close() })
    return $script:KqlWindow
}
function Invalidate-KqlPreview {
    $script:K.Query.Text=''; $script:K.Copy.IsEnabled=$false; $script:K.Save.IsEnabled=$false
    $script:K.Status.Text='Inputs changed. Generate a new query before copying or saving.'
}
function Generate-KqlPreview {
    Invalidate-KqlPreview
    $names=@($script:K.Names.Text -split '\r?\n')
    $application=if ($script:K.ApplicationPanel.Visibility -eq 'Visible') { $script:K.Application.Text } else { '' }
    $generated=New-DeviceKql -Names $names -Template ([string]$script:K.Template.SelectedItem) -Days ([int]$script:K.Days.SelectedItem) -Application $application
    $script:K.Query.Text=$generated.Query
    $script:K.Copy.IsEnabled=$true; $script:K.Save.IsEnabled=$true
    $script:K.Status.Text="$($generated.Count) unique short hostnames from $($generated.InputCount) nonblank entries. Review before running; no live tenant validation was performed."
}
function Apply-Branding {
    $script:Window.Title=$script:Brand.Name+' | Offline lookup'
    $script:C.BrandName.Text=$script:Brand.Name
    $script:C.BrandSubtitle.Text=$script:Brand.Subtitle
    $color=[Windows.Media.ColorConverter]::ConvertFromString($script:Brand.Accent)
    $script:BrandForeground=if ((0.299*$color.R+0.587*$color.G+0.114*$color.B) -gt 150) { '#12263E' } else { '#FFFFFF' }
    $script:Window.Resources['BrandAccent']=[Windows.Media.SolidColorBrush]::new($color)
    $script:Window.Resources['BrandContrast']=[Windows.Media.BrushConverter]::new().ConvertFromString($script:BrandForeground)
    $script:C.BrandLogo.Source=$null
    $script:C.BrandLogo.Visibility='Collapsed'
    $script:Window.Icon=$script:DefaultIcon
    if ($script:Brand.Logo) {
        try {
            $logo=Get-BrandLogo (Join-Path $script:AppRoot 'branding\logo.png')
            $script:C.BrandLogo.Source=$logo
            $script:C.BrandLogo.Visibility='Visible'
            $script:Window.Icon=$logo
        } catch { $script:C.BrandLogoStatus.Text='Logo unavailable. Choose a valid PNG and save again.' }
    }
    foreach ($pair in @(@('Devices','NavDevices'),@('Users','NavUsers'),@('Bulk','NavBulk'),@('BulkUsers','NavBulkUsers'),@('Data','NavData'))) {
        $active=$script:Page -eq $pair[0]
        $script:C[$pair[1]].Background=if ($active) { $script:Brand.Accent } else { 'Transparent' }
        $script:C[$pair[1]].Foreground=if ($active) { $script:BrandForeground } else { '#CAD6E5' }
    }
}
function Fill-BrandingForm {
    $script:C.BrandNameInput.Text=$script:Brand.Name
    $script:C.BrandSubtitleInput.Text=$script:Brand.Subtitle
    $script:C.BrandAccentInput.Text=$script:Brand.Accent
    $script:C.BrandUseLogo.IsChecked=$script:Brand.Logo
    $script:C.BrandLogoStatus.Text=if ($script:Brand.Logo) { 'Workspace logo: branding\logo.png' } else { 'No custom logo selected.' }
    $script:PendingLogo=''
}
function Save-BrandingForm {
    $brand=[pscustomobject]@{Name=$C.BrandNameInput.Text.Trim();Subtitle=$C.BrandSubtitleInput.Text.Trim();Accent=$C.BrandAccentInput.Text.Trim();Logo=[bool]$C.BrandUseLogo.IsChecked}
    Test-Branding $brand
    if ($brand.Logo) {
        $source=if ($script:PendingLogo) { $script:PendingLogo } else { Join-Path $script:AppRoot 'branding\logo.png' }
        $null=Get-BrandLogo $source
        if ($script:PendingLogo) {
            $dir=Join-Path $script:AppRoot 'branding'
            [void][IO.Directory]::CreateDirectory($dir)
            $target=Join-Path $dir 'logo.png'
            if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($target)) { Copy-Item -LiteralPath $source -Destination $target -Force }
        }
    }
    Write-Branding $script:AppRoot $brand
    $script:Brand=$brand
    Fill-BrandingForm
    Apply-Branding
    Set-Status 'Branding saved for this workspace.'
}

function Request-Import([string]$Kind) {
    $path=Open-CsvDialog
    if (-not $path) { return }
    $message="Replace the local $Kind snapshot with this export?`n`n$path`n`nThe other datasets are kept. A backup is created first. Nothing is changed in Entra."
    if ([Windows.MessageBox]::Show($script:Window,$message,'Refresh local snapshot',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question) -eq 'Yes') { Start-Work ('Import'+$Kind) -CsvPath $path }
}

try {
    [xml]$xaml=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Directory-Lens.xaml') -Raw
    $reader=New-Object Xml.XmlNodeReader($xaml)
    $script:Window=[Windows.Markup.XamlReader]::Load($reader)
    # The window/taskbar image lives in the launcher, keeping the portable package minimal.
    $iconAssembly=[Reflection.Assembly]::LoadFile((Join-Path $PSScriptRoot 'Directory-Lens.exe'))
    $iconStream=$iconAssembly.GetManifestResourceStream('DirectoryIcon.png')
    if ($iconStream) {
        try {
            $iconFrame=[Windows.Media.Imaging.BitmapFrame]::Create($iconStream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $iconFrame.Freeze()
            $script:Window.Icon=$iconFrame
        } finally { $iconStream.Dispose() }
    }
    $script:C=@{}
    $xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $name=$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml'); if ($name) { $script:C[$name]=$script:Window.FindName($name) } }
    $script:DefaultIcon=$script:Window.Icon
    $script:Page='Devices'
    try { $script:Brand=Read-Branding $script:AppRoot } catch { $script:Brand=Get-DefaultBranding }
    Fill-BrandingForm
    Apply-Branding
    $C.BrandSave.Add_Click({ try { Save-BrandingForm } catch { Show-Problem $_.Exception.Message } })
    $C.BrandReset.Add_Click({ try { $brand=Get-DefaultBranding; Write-Branding $script:AppRoot $brand; $script:Brand=$brand; Fill-BrandingForm; Apply-Branding; Set-Status 'Default branding restored. Imported data is unchanged.' } catch { Show-Problem $_.Exception.Message } })
    $C.BrandChooseLogo.Add_Click({
        try {
            $dialog=New-Object Microsoft.Win32.OpenFileDialog
            $dialog.Filter='PNG logo (*.png)|*.png'
            if ($dialog.ShowDialog($script:Window)) {
                $null=Get-BrandLogo $dialog.FileName
                $script:PendingLogo=$dialog.FileName
                $C.BrandUseLogo.IsChecked=$true
                $C.BrandLogoStatus.Text='Selected: '+[IO.Path]::GetFileName($dialog.FileName)+' (click Save branding)'
            }
        } catch { Show-Problem $_.Exception.Message }
    })
    $script:Busy=$false; $script:Results=@(); $script:ResultType='Devices'; $script:CsvPath=''; $script:CsvRows=@(); $script:CsvColumns=@(); $script:Worker=$null; $script:LastError=$null
    $script:LastDeviceNames=@(); $script:LastDeviceSource=''
    $script:Timer=New-Object Windows.Threading.DispatcherTimer
    $script:Timer.Interval=[TimeSpan]::FromMilliseconds(120)
    $script:Timer.Add_Tick({ Complete-Work })
    $C.NavDevices.Add_Click({ Set-Page 'Devices' })
    $C.NavUsers.Add_Click({ Set-Page 'Users' })
    $C.NavBulk.Add_Click({ Set-Page 'Bulk' })
    $C.NavBulkUsers.Add_Click({ Set-Page 'BulkUsers' })
    $C.NavGroups.Add_Click({ try { Open-GroupComparison } catch { Show-Problem $_.Exception.Message } })
    $C.CompareGroup.Add_Click({ try { Open-GroupComparison } catch { Show-Problem $_.Exception.Message } })
    $C.NavData.Add_Click({ Set-Page 'Data' })
    $C.NavBranding.Add_Click({ Set-Page 'Data'; $Window.UpdateLayout(); $offset=$C.BrandingHeading.TranslatePoint([Windows.Point]::new(0,0),$C.DataScroll.Content).Y; $C.DataScroll.ScrollToVerticalOffset($offset) })
    $C.NavKql.Add_Click({ try { $dialog=New-KqlWindow; [void]$dialog.ShowDialog() } catch { Show-Problem $_.Exception.Message } })
    $C.SearchButton.Add_Click({ try { if ([string]::IsNullOrWhiteSpace($C.SearchText.Text)) { Set-Status 'Enter some search text first.' } else { Start-Work $script:Page -Query $C.SearchText.Text } } catch { Show-Problem $_.Exception.Message } })
    $C.SearchText.Add_KeyDown({ if ($_.Key -eq 'Return' -and -not $script:Busy) { $C.SearchButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) } })
    $C.ChooseCsv.Add_Click({ try { $path=Open-CsvDialog; if ($path) { Load-CsvPreview $path } } catch { Show-Problem $_.Exception.Message } })
    $C.ColumnPicker.Add_SelectionChanged({ Update-CsvPreview })
    $C.NoHeaderCheck.Add_Checked({ Update-CsvPreview })
    $C.NoHeaderCheck.Add_Unchecked({ Update-CsvPreview })
    $C.RunBulk.Add_Click({ try { $column=if ($C.NoHeaderCheck.IsChecked) { '' } else { [string]$C.ColumnPicker.SelectedItem }; Start-Work $script:Page -CsvPath $script:CsvPath -Column $column -Headerless ([bool]$C.NoHeaderCheck.IsChecked) } catch { Show-Problem $_.Exception.Message } })
    $C.ExampleButton.Add_Click({ try {
        $userList=$script:Page -eq 'BulkUsers'
        $prefix=if ($userList) { 'UserList-example' } else { 'DeviceNames-example' }
        $path=New-OutputDialog $prefix
        if ($path) {
            $example=if ($userList) { @('userPrincipalName','person.one@example.invalid','person.two@example.invalid') } else { @('DeviceName','PC001','PC002') }
            $example | Set-Content -LiteralPath $path -Encoding UTF8
            Set-Status "Example saved: $path. Replace the example values with your list."
        }
    } catch { Show-Problem $_.Exception.Message } })
    $C.ResultsGrid.Add_SelectionChanged({ Update-Actions })
    $C.CopyName.Add_Click({ try { Copy-Selected $(if ($script:ResultType -in @('Users','BulkUsers')) { 'DisplayName' } else { 'DeviceName' }) } catch { Show-Problem $_.Exception.Message } })
    $C.CopyIdentifier.Add_Click({ try { Copy-Selected $(if ($script:ResultType -in @('Users','BulkUsers')) { 'UPN' } else { 'DeviceId' }) } catch { Show-Problem $_.Exception.Message } })
    $C.CopyObject.Add_Click({ try { Copy-Selected 'ObjectId' } catch { Show-Problem $_.Exception.Message } })
    $C.ExportResults.Add_Click({ try { $path=New-OutputDialog 'Directory-Lens-Lookup'; if ($path) { Save-Report $script:Results $path; Set-Status "All $($script:Results.Count) result rows saved: $path" } } catch { Show-Problem $_.Exception.Message } })
    $C.ExportGroup.Add_Click({
        try {
            $plan=Get-GroupExportPlan
            if ([Windows.MessageBox]::Show($Window,$plan.Message,'Review group export',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question) -eq 'Yes') {
                $path=New-OutputDialog $plan.Prefix
                if ($path) { Save-Group $plan.Rows $path; Set-Status "Group upload saved: $path" }
            }
        } catch { Show-Problem $_.Exception.Message }
    })
    $C.ViewDetails.Add_Click({
        $selected=$script:C.ResultsGrid.SelectedItem
        if (-not $selected) { return }
        $dialog=New-Object Windows.Window
        $dialog.Title=$script:Brand.Name+' | Record details'
        $dialog.Width=780; $dialog.Height=700; $dialog.MinWidth=500; $dialog.MinHeight=400
        $dialog.WindowStartupLocation='CenterOwner'; $dialog.Owner=$script:Window
        $text=New-Object Windows.Controls.TextBox
        $text.IsReadOnly=$true; $text.TextWrapping='Wrap'; $text.VerticalScrollBarVisibility='Auto'
        $text.FontFamily='Segoe UI'; $text.FontSize=13; $text.Padding='20'; $text.Background='#F8FAFC'
        $lines=@('Local snapshot. Check source dates and Intune last check-in.','')
        foreach ($property in $selected.PSObject.Properties) { $lines+=($property.Name+': '+[string]$property.Value) }
        $text.Text=$lines -join "`r`n`r`n"
        $dialog.Content=$text
        [void]$dialog.ShowDialog()
    })
    $C.ImportDevices.Add_Click({ try { Request-Import 'Devices' } catch { Show-Problem $_.Exception.Message } })
    $C.ImportDefender.Add_Click({ try { Request-Import 'Defender' } catch { Show-Problem $_.Exception.Message } })
    $C.ImportIntune.Add_Click({ try { Request-Import 'Intune' } catch { Show-Problem $_.Exception.Message } })
    $C.ImportUsers.Add_Click({ try { Request-Import 'Users' } catch { Show-Problem $_.Exception.Message } })
    $C.ReloadSummary.Add_Click({ Start-Work 'Summary' })
    $Window.Add_Closing({ if ($script:Busy) { $_.Cancel=$true; Set-Status 'Please wait for the current operation to finish before closing.' } })
    $Window.Add_Closed({ $script:Timer.Stop(); if ($script:Worker) { $script:Worker.Dispose() } })
    Set-Page 'Devices'
    Start-Work 'Summary'
    if (-not $NoShow) { [void]$Window.ShowDialog() }
} catch {
    if ($NoShow) { throw }
    [void][Windows.MessageBox]::Show($_.Exception.Message,'Unable to open Directory Lens',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error)
    exit 1
}
