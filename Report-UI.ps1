#requires -Version 5.1
function Start-ReportWork {
    if ($script:RBusy) { return }
    $script:RRows=@(); $R.Results.ItemsSource=$null
    $script:RBusy=$true; $script:RLastError=$null
    foreach ($name in @('Report','Refresh','Export','Kql')) { $R[$name].IsEnabled=$false }
    $R.Status.Text='Reading local inventory snapshots...'
    $script:RWorker=[powershell]::Create()
    [void]$RWorker.AddScript({
        param($Root,$Db,$Report)
        $DatabasePath=$Db
        . (Join-Path $Root 'Database.ps1')
        . (Join-Path $Root 'Csv-Helpers.ps1')
        . (Join-Path $Root 'Reports.ps1')
        [pscustomobject]@{Rows=@(Get-InventoryReport $Report);Context=(@(Get-SnapshotContext) -join "`n")}
    }.ToString()).AddArgument($script:AppRoot).AddArgument($script:DatabasePath).AddArgument([string]$R.Report.SelectedItem)
    $script:RHandle=$RWorker.BeginInvoke(); $RTimer.Start()
}
function Complete-ReportWork {
    if (-not $RHandle.IsCompleted) { return }
    $RTimer.Stop()
    try {
        $result=@($RWorker.EndInvoke($RHandle))
        if ($RWorker.HadErrors) { throw ($RWorker.Streams.Error | Out-String) }
        $script:RRows=@($result[0].Rows)
        $R.Results.ItemsSource=$script:RRows
        $R.Snapshots.Text=$result[0].Context
        $R.Status.Text="$($RRows.Count) records. Missing means absent from these snapshots; Not loaded means no comparison is possible. Source file time is not a device observation time."
    } catch { $script:RLastError=$_.Exception.Message; $R.Status.Text=$script:RLastError }
    finally {
        $RWorker.Dispose(); $script:RWorker=$null; $script:RBusy=$false
        $R.Report.IsEnabled=$true; $R.Refresh.IsEnabled=$true
        $R.Export.IsEnabled=($RRows.Count -gt 0)
        $R.Kql.IsEnabled=(@(Get-ReportKqlNames $RRows).Count -gt 0)
    }
}
function Open-ReportKql {
    $dialog=New-KqlWindow
    $K.Names.Text=@(Get-ReportKqlNames $script:RRows) -join "`r`n"
    $K.SourceHint.Text="Current report: $($R.Report.SelectedItem) ($($RRows.Count) rows). Names are hunting scope only, never identity links. Blank names omitted; short names may collide."
    $K.Template.SelectedItem='Missing or stale device telemetry'
    return $dialog
}
function Show-InventoryReports([switch]$NoShow) {
    [xml]$markup=Get-Content (Join-Path $script:AppRoot 'Inventory-Reports.xaml') -Raw
    $script:RWindow=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
    $RWindow.Title=$script:Brand.Name+' | Inventory gaps and health'
    $RWindow.Icon=$script:Window.Icon
    if ($script:Window.IsVisible) { $RWindow.Owner=$script:Window }
    $script:R=@{}
    foreach ($name in @('Report','Refresh','Export','Kql','Results','Snapshots','Status','Close')) { $R[$name]=$RWindow.FindName($name) }
    $script:RRows=@(); $script:RBusy=$false; $script:RWorker=$null
    $R.Report.ItemsSource=[string[]]@(Get-InventoryReportNames); $R.Report.SelectedIndex=0
    $script:RTimer=[Windows.Threading.DispatcherTimer]::new(); $RTimer.Interval=[TimeSpan]::FromMilliseconds(120)
    $RTimer.Add_Tick({ Complete-ReportWork })
    $R.Report.Add_SelectionChanged({ Start-ReportWork })
    $R.Refresh.Add_Click({ Start-ReportWork })
    $R.Export.Add_Click({ try {
        $path=New-OutputDialog ('Directory-Lens-'+(([string]$R.Report.SelectedItem) -replace '[^a-zA-Z0-9]+','-'))
        if ($path) { Save-Report $script:RRows $path; $R.Status.Text='Report saved with snapshot timestamps and assessment context. No live validation was performed.' }
    } catch { $R.Status.Text=$_.Exception.Message } })
    $R.Kql.Add_Click({ try { $dialog=Open-ReportKql; $dialog.Owner=$RWindow; [void]$dialog.ShowDialog() } catch { $R.Status.Text=$_.Exception.Message } })
    $R.Close.Add_Click({ $RWindow.Close() })
    $RWindow.Add_Closing({ if ($script:RBusy) { $_.Cancel=$true; $R.Status.Text='Wait for the current report to finish.' } })
    $RWindow.Add_Closed({ $RTimer.Stop() })
    Start-ReportWork
    if ($NoShow) { return $RWindow }
    [void]$RWindow.ShowDialog()
}
