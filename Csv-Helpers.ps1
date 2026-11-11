function Read-CsvFile([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'No file selected. Use option 7 to show/save a CSV example.' }
    if ([IO.Path]::GetExtension($Path) -in @('.xlsx','.xls','.xlsm')) { throw 'Save the Excel workbook as CSV UTF-8 first, then select that CSV file.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "CSV not found: $Path" }
    $header = Get-Content -LiteralPath $Path -TotalCount 1
    # Detect common Excel delimiters using the parsed header count.
    $best = ','; $count = 0
    foreach ($delimiter in @(',', ';', "`t")) {
        $probe = @($header, $header) | ConvertFrom-Csv -Delimiter $delimiter
        $n = @($probe.PSObject.Properties).Count
        if ($n -gt $count) { $count = $n; $best = $delimiter }
    }
    Import-Csv -LiteralPath $Path -Delimiter $best -Encoding UTF8
}
function Find-Column($Row, [string[]]$Aliases, [switch]$Optional) {
    foreach ($alias in $Aliases) {
        foreach ($property in $Row.PSObject.Properties.Name) {
            if (($property -replace '[\s_-]', '') -ieq ($alias -replace '[\s_-]', '')) { return $property }
        }
    }
    if (-not $Optional) { throw "Required column missing. Expected: $($Aliases -join ', '). Available: $($Row.PSObject.Properties.Name -join ', ')" }
}
function Test-Guid([string]$Value) {
    $parsed = [guid]::Empty
    return ([guid]::TryParse($Value, [ref]$parsed) -and $parsed -ne [guid]::Empty)
}
function Get-NamesFromCsv([string]$Path, [switch]$Interactive, [switch]$NoHeader) {
    $rows = @(Read-CsvFile $Path)
    $header = Get-Content -LiteralPath $Path -TotalCount 1
    if ([string]::IsNullOrWhiteSpace($header)) { throw 'The file is empty or has a blank first row. Use option 7 for an example.' }
    $probe = if ($rows.Count) { $rows[0] } else { @($header,$header) | ConvertFrom-Csv }
    $columns = @($probe.PSObject.Properties.Name)
    $aliases = @('DeviceName','displayName','ComputerName','Name','Hostname','Device','AssetName','Host','Computer','EndpointName','DNSHostName')
    $recognized = @($columns | Where-Object { ($_ -replace '[\s_-]', '') -in $aliases })
    if ($NoHeader -and $NameColumn) { throw 'Use either -NoHeader or -NameColumn.' }
    if ($NoHeader) {
        if ($columns.Count -ne 1) { throw '-NoHeader requires one column containing device names.' }
    } elseif ($NameColumn) {
        if ($NameColumn -notin $columns) { throw "Name column '$NameColumn' was not found. Available: $($columns -join ', ')" }
        $column = $NameColumn
    } elseif ($recognized.Count -eq 1) {
        $column = $recognized[0]
    } elseif ($Interactive) {
        Write-Host 'Choose the column containing device names:'
        for ($i=0; $i -lt $columns.Count; $i++) {
            $sample = @($rows | Select-Object -First 3 | ForEach-Object { [string]$_.$($columns[$i]) }) -join ' | '
            Write-Host ("{0}  {1}  (examples: {2})" -f ($i+1), $columns[$i], $sample)
        }
        if ($columns.Count -eq 1) { Write-Host '0  No header: the first row is also a device name' }
        $choice = Read-Host 'Column number (Enter cancels)'
        $number = -1
        if (-not [int]::TryParse($choice,[ref]$number)) { throw 'CSV lookup cancelled.' }
        if ($number -eq 0 -and $columns.Count -eq 1) { $NoHeader=$true }
        elseif ($number -ge 1 -and $number -le $columns.Count) { $column=$columns[$number-1] }
        else { throw 'Invalid column selection. No lookup performed.' }
    } else {
        throw "Cannot choose a device-name column unambiguously. Use -NameColumn, or -NoHeader for a single-column list without a header. Available: $($columns -join ', ')"
    }
    if ($NoHeader) {
        $raw = [IO.File]::ReadAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
        $rows = @(("DeviceName`n" + $raw) | ConvertFrom-Csv)
        $column='DeviceName'
    }
    if (-not $rows.Count) { throw 'No data rows. Use option 7 for an example or -NoHeader for a headerless list.' }
    if ($Interactive) {
        Write-Host "Using '$column': $($rows.Count) rows. Exact device matching for bulk lookup."
        $rows | Select-Object -First 5 -Property $column | Format-Table -AutoSize | Out-Host
        $answer = Read-Host 'Continue? (Enter/Y = yes, anything else = cancel)'
        if ($answer -and $answer -ine 'Y') { throw 'CSV lookup cancelled.' }
    }
    foreach ($row in $rows) { [string]$row.$column }
}
function Assert-NewPath([string]$Path) {
    if (Test-Path -LiteralPath $Path) { throw "Output already exists; choose a new filename: $Path" }
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Output folder does not exist: $parent" }
}
function Resolve-OutputPath([string]$Path, [string]$Prefix) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $folder = (Get-Location).ProviderPath
        $stem = '{0}_{1}' -f $Prefix, (Get-Date -Format 'yyyyMMdd_HHmmss')
        $Path = Join-Path $folder ($stem + '.csv')
        $suffix = 1
        while (Test-Path -LiteralPath $Path) {
            $Path = Join-Path $folder ('{0}_{1}.csv' -f $stem, $suffix)
            $suffix++
        }
    }
    return $Path
}
function ConvertTo-SafeCsvText([string]$Text) {
    # Spreadsheets evaluate a cell that starts with = + - or @ (also after leading spaces),
    # or with a tab or line break. Inventory text comes from tenant exports, so prefix such
    # cells with an apostrophe to keep them as text.
    if ($Text -match '^\s*[=+\-@]' -or $Text -match '^[\t\r\n]') { return "'" + $Text }
    return $Text
}
function Save-Report($Results, [string]$Path) {
    $Path = Resolve-OutputPath $Path 'Entra-Lookup'
    Assert-NewPath $Path
    $columns=@($Results | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
    $safe=@(foreach ($row in $Results) {
        $record=[ordered]@{}
        foreach ($column in $columns) {
            $property=$row.PSObject.Properties[$column]
            $value=if ($property) { $property.Value } else { $null }
            $record[$column]=if ($value -is [string]) { ConvertTo-SafeCsvText $value } else { $value }
        }
        [pscustomobject]$record
    })
    $safe | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Lookup report saved: $Path"
}
function Save-Group($Results, [string]$Path) {
    $Path = Resolve-OutputPath $Path 'Entra-GroupMembers'
    Assert-NewPath $Path
    $ids = @($Results | Where-Object { $_.GroupEligible } | Select-Object -ExpandProperty ObjectId -Unique)
    if ($ids.Count -eq 0) { throw 'No unambiguous matches with valid Object IDs. No group CSV written.' }
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) { throw "Group template not found: $TemplatePath" }
    $lines = @(Get-Content -LiteralPath $TemplatePath -Encoding UTF8)
    $offset = 0
    if ($lines.Count -gt 0 -and $lines[0] -match '^version:') { $offset = 1 }
    if ($lines.Count -le $offset) { throw 'Template has no header.' }
    $parsedHeader = @($lines[$offset], $lines[$offset]) | ConvertFrom-Csv
    $headers = @($parsedHeader.PSObject.Properties.Name)
    if ($headers.Count -ne 1 -or $headers[0] -notmatch '\[memberObjectIdOrUpn\]') { throw 'Expected the Entra Import members template with one memberObjectIdOrUpn column.' }
    # Preserve the supplied header/version exactly; omit template example rows.
    $output = @($lines[0..$offset]) + $ids
    [IO.File]::WriteAllLines([IO.Path]::GetFullPath($Path), [string[]]$output, (New-Object Text.UTF8Encoding($true)))
    $excluded = @($Results | Where-Object { -not $_.GroupEligible } | Select-Object -ExpandProperty RequestedName -Unique).Count
    Write-Host "Group upload saved: $Path ($($ids.Count) unique Object IDs; $excluded unresolved names excluded)."
    if ($excluded) { Write-Warning 'Review unresolved names in the lookup report before uploading.' }
}

