#requires -Version 5.1
function Clear-GroupComparison {
    $script:GResults=@()
    $script:G.Results.ItemsSource=$null
    $script:G.ExportMissing.IsEnabled=$false
    $script:G.ExportReport.IsEnabled=$false
}
function Update-GroupActions {
    $group=$script:G.Groups.SelectedItem
    $script:G.ImportMembers.IsEnabled=(-not $script:GBusy -and $null -ne $group -and $script:G.Groups.SelectedItems.Count -eq 1 -and $script:G.Complete.IsChecked)
    $script:G.Compare.IsEnabled=(-not $script:GBusy -and $null -ne $group -and $script:GCandidates.Count -gt 0)
}
function Start-GroupWork([string]$Task,[string]$Path='',[string[]]$GroupId=@()) {
    if ($script:GBusy) { return }
    Clear-GroupComparison
    $script:GBusy=$true
    foreach ($name in @('Search','Query','ImportCatalog','Groups','Complete','ImportMembers','Compare','ExportMissing','ExportReport','Close')) { $script:G[$name].IsEnabled=$false }
    $script:G.Status.Text='Working on the local snapshot...'
    $script:GTask=$Task
    $script:GWorker=[powershell]::Create()
    [void]$script:GWorker.AddScript({
        param($Root,$Db,$Task,$Path,$GroupId,$Query,$Candidates,$EntityType)
        $DatabasePath=$Db
        . (Join-Path $Root 'Database.ps1')
        . (Join-Path $Root 'Csv-Helpers.ps1')
        . (Join-Path $Root 'Groups.ps1')
        . (Join-Path $Root 'Reports.ps1')
        switch ($Task) {
            'Search' { Get-GroupCatalog $Query }
            'Catalog' { $null=Import-GroupCatalog $Path; Get-GroupCatalog $Query }
            'Members' { $null=Import-GroupMembers -GroupId $GroupId[0] -CsvPath $Path -CompleteSnapshot; Get-GroupCatalog $GroupId[0] }
            'Compare' { Compare-MultipleGroups $GroupId $Candidates $EntityType }
        }
    }.ToString()).AddArgument($script:AppRoot).AddArgument($script:DatabasePath).AddArgument($Task).AddArgument($Path).AddArgument($GroupId).AddArgument($G.Query.Text).AddArgument($script:GCandidates).AddArgument($script:GEntityType)
    $script:GHandle=$script:GWorker.BeginInvoke()
    $script:GTimer.Start()
}
function Complete-GroupWork {
    if (-not $script:GHandle.IsCompleted) { return }
    $script:GTimer.Stop()
    try {
        $rows=@($script:GWorker.EndInvoke($script:GHandle))
        if ($script:GWorker.HadErrors) { throw ($script:GWorker.Streams.Error | Out-String) }
        if ($script:GTask -eq 'Compare') {
            $script:GResults=$rows
            $G.Results.ItemsSource=$rows
            $missing=@($rows | Where-Object Comparison -eq 'Missing').Count
            $existing=@($rows | Where-Object Comparison -eq 'Existing').Count
            $unresolved=@($rows | Where-Object Comparison -eq 'Unresolved').Count
            $duplicates=@($rows | Where-Object Comparison -eq 'DuplicateInput').Count
            $notLoaded=@($rows | Where-Object Comparison -eq 'Not loaded').Count
            $G.Status.Text="Not loaded: $notLoaded | Missing: $missing | Existing: $existing | Unresolved: $unresolved | Duplicate inputs: $duplicates. Missing means absent from the imported snapshot."
        } else {
            $G.Groups.ItemsSource=$rows
            $G.Status.Text="Showing $($rows.Count) groups (maximum 1,000). Select a target to inspect its member snapshot."
            if ($script:GTask -eq 'Members' -and $rows.Count -eq 1) { $G.Groups.SelectedIndex=0 }
        }
    } catch { $G.Status.Text=$_.Exception.Message; $script:GLastError=$_.Exception.Message }
    finally {
        $script:GWorker.Dispose();$script:GWorker=$null;$script:GBusy=$false
        foreach ($name in @('Search','Query','ImportCatalog','Groups','Complete','Close')) { $G[$name].IsEnabled=$true }
        $G.ExportMissing.IsEnabled=($G.Groups.SelectedItems.Count -eq 1 -and @($script:GResults | Where-Object GroupEligible).Count -gt 0)
        $G.ExportReport.IsEnabled=($script:GResults.Count -gt 0)
        Update-GroupActions
    }
}
function Show-GroupWorkspace([object[]]$Candidates=@(),[ValidateSet('Devices','Users')][string]$EntityType='Devices',[switch]$NoShow) {
    $Candidates=@($Candidates | Where-Object { $null -ne $_ })
    [xml]$markup=Get-Content (Join-Path $script:AppRoot 'Group-Membership.xaml') -Raw
    $script:GWindow=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
    $script:GWindow.Title=$script:Brand.Name+' | Group membership'
    if ($script:Window.IsVisible) { $script:GWindow.Owner=$script:Window }
    $script:GWindow.Icon=$script:Window.Icon
    $script:G=@{}
    $markup.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $name=$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');if ($name) { $G[$name]=$GWindow.FindName($name) } }
    $script:GCandidates=@($Candidates);$script:GEntityType=$EntityType;$script:GResults=@();$script:GBusy=$false;$script:GLastError=$null
    $G.ScopeText.Text=if ($Candidates.Count) { "Comparison scope: $($Candidates.Count) $EntityType lookup rows captured from the main window. Exact, unambiguous Object IDs only." } else { 'No lookup captured. Import snapshots here, close this window, run Bulk device/user lookup, then choose Compare group.' }
    $G.SnapshotText.Text=(@(Get-SnapshotContext) -join "`n")
    $script:GTimer=[Windows.Threading.DispatcherTimer]::new()
    $GTimer.Interval=[TimeSpan]::FromMilliseconds(120)
    $GTimer.Add_Tick({ Complete-GroupWork })
    $G.Search.Add_Click({ Start-GroupWork 'Search' })
    $G.Query.Add_KeyDown({ if ($_.Key -eq 'Return' -and -not $script:GBusy) { Start-GroupWork 'Search' } })
    $G.Groups.Add_SelectionChanged({
        Clear-GroupComparison
        $G.Complete.IsChecked=$false
        $group=$G.Groups.SelectedItem
        if ($group) {
            $policy=if (Test-GroupWritable $group $script:GEntityType) { 'Manual additions supported for this lookup type.' } else { 'Comparison only: group type, membership type or source does not support this manual upload.' }
            $G.TargetText.Text="$($group.DisplayName) | $($group.GroupId)`nSelected groups: $($G.Groups.SelectedItems.Count) | Membership: $($group.MembershipSnapshot) | Source: $($group.SourceFile) | Imported UTC: $($group.ImportedUtc)`nSource modified UTC: $($group.SourceModifiedUtc). Import time is not observation time.`n$policy"
        } else { $G.TargetText.Text='Select a group. No member snapshot is assumed.' }
        Update-GroupActions
    })
    $G.Complete.Add_Checked({ Update-GroupActions });$G.Complete.Add_Unchecked({ Update-GroupActions })
    $G.ImportCatalog.Add_Click({ $path=Open-CsvDialog; if ($path) { Start-GroupWork 'Catalog' -Path $path } })
    $G.ImportMembers.Add_Click({
        $group=$G.Groups.SelectedItem
        if (-not $group -or -not $G.Complete.IsChecked) { return }
        $path=Open-CsvDialog
        if (-not $path) { return }
        $message="Replace the member snapshot for this group?`n`n$($group.DisplayName)`n$($group.GroupId)`n`n$path`n`nOnly this group's member snapshot is replaced. A local database backup is created. The CSV must contain all direct members for this exact group and tenant."
        if ([Windows.MessageBox]::Show($GWindow,$message,'Import member snapshot','YesNo','Question') -eq 'Yes') { Start-GroupWork 'Members' -Path $path -GroupId $group.GroupId }
    })
    $G.Compare.Add_Click({ if ($G.Groups.SelectedItem) { Start-GroupWork 'Compare' -GroupId @($G.Groups.SelectedItems | ForEach-Object { $_.GroupId }) } })
    $G.ExportReport.Add_Click({ try { $path=New-OutputDialog 'Directory-Lens-MembershipComparison';if ($path) { Save-Report $script:GResults $path; $G.Status.Text='Comparison report saved with member and inventory snapshot timestamps.' } } catch { $G.Status.Text=$_.Exception.Message } })
    $G.ExportMissing.Add_Click({
        try {
            if ($G.Groups.SelectedItems.Count -ne 1) { throw 'Select exactly one target group for an upload export.' }
            $group=$G.Groups.SelectedItem
            # Re-evaluate against the current snapshot before saving, never reuse stale eligibility.
            $fresh=@(Compare-GroupMembers $group.GroupId $script:GCandidates $script:GEntityType)
            $missing=@($fresh | Where-Object GroupEligible)
            if (-not $missing.Count) { throw 'No eligible missing members remain for this target.' }
            $message="Export $($missing.Count) missing Object IDs for $($group.DisplayName)?`nTarget group: $($group.GroupId)`nSnapshot imported UTC: $($missing[0].MembershipImportedUtc) ($($missing[0].MembershipAgeDays) days ago)`nSource modified UTC: $($missing[0].MembershipSourceModifiedUtc)`n$(@(Get-SnapshotContext) -join "`n")`n`nExisting, unresolved and duplicate inputs are excluded. Review the comparison and verify the current tenant/group before manually uploading."
            if ([Windows.MessageBox]::Show($GWindow,$message,'Export missing members','YesNo','Question') -ne 'Yes') { return }
            $path=New-OutputDialog ('Directory-Lens-MissingMembers-'+$group.GroupId)
            if ($path) { Save-Group $missing $path; $G.Status.Text="Exported $($missing.Count) missing Object IDs. No group was changed." }
        } catch { $G.Status.Text=$_.Exception.Message }
    })
    $G.Close.Add_Click({ $GWindow.Close() })
    $GWindow.Add_Closing({ if ($script:GBusy) { $_.Cancel=$true;$G.Status.Text='Wait for the current operation to finish.' } })
    $GWindow.Add_Closed({ $GTimer.Stop(); if ($script:GWorker) { $script:GWorker.Dispose() } })
    Start-GroupWork 'Search'
    if ($NoShow) { return $GWindow }
    [void]$GWindow.ShowDialog()
}
function Open-GroupComparison {
    param([switch]$NoShow)
    $type=if ($script:ResultType -in @('Users','BulkUsers')) { 'Users' } else { 'Devices' }
    $rows=if ($script:ResultType -eq 'Users') {
        @(foreach ($user in $script:C.ResultsGrid.SelectedItems) { [pscustomobject]@{RequestedName=$user.UPN;ObjectId=$user.ObjectId;GroupEligible=(Test-Guid $user.ObjectId)} })
    } else { @($script:Results) }
    Show-GroupWorkspace -Candidates $rows -EntityType $type -NoShow:$NoShow
}
