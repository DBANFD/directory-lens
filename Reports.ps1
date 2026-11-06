#requires -Version 5.1
function Get-InventoryReportNames {
    'Entra without Intune'
    'Entra without Defender'
    'Intune without valid Entra Device ID'
    'Defender without valid AAD Device Id'
    'Intune without Defender'
    'Defender without Intune'
    'Disabled Entra with inventory records'
    'Defender-only records'
    'Duplicate identities'
    'Missing or weak owner'
}
function Get-SnapshotContext {
    $summary=@(Get-DatabaseSummary)
    foreach ($dataset in @('Devices','Users','Intune','Defender')) {
        $row=@($summary | Where-Object Dataset -eq $dataset)
        if (-not $row.Count -or -not $row[0].ImportedUtc) { "$dataset`: Not loaded"; continue }
        $item=$row[0]
        $age=[Math]::Round(([DateTime]::UtcNow-([DateTimeOffset]::Parse($item.ImportedUtc).UtcDateTime)).TotalDays,1)
        "$dataset`: imported UTC $($item.ImportedUtc) ($age days ago); source $($item.SourceFile); source modified UTC $($item.SourceModifiedUtc)"
    }
}
function Get-InventoryReport([string]$Report) {
    if ($Report -notin @(Get-InventoryReportNames)) { throw 'Choose an inventory report.' }
    $context=@(Get-SnapshotContext) -join ' | '
    $loaded=@{Devices=$false;Users=$false;Intune=$false;Defender=$false}
    foreach ($item in @(Get-DatabaseSummary)) { $loaded[$item.Dataset]=[bool]$item.ImportedUtc }
    $sets=@{
        Devices=@(Invoke-Database 'SELECT ObjectId AS RecordId,DeviceId,DeviceName,Enabled,OwnerText FROM devices ORDER BY DeviceName,ObjectId;')
        Intune=@(); Defender=@()
    }
    if (Test-IntuneDataset) { $sets.Intune=@(Invoke-Database 'SELECT IntuneDeviceId AS RecordId,DeviceId,DeviceName FROM intune ORDER BY DeviceName,IntuneDeviceId;') }
    if (Test-DefenderDataset) { $sets.Defender=@(Invoke-Database 'SELECT DefenderDeviceId AS RecordId,DeviceId,DeviceName FROM defender ORDER BY DeviceName,DefenderDeviceId;') }
    $indexes=@{}
    foreach ($source in @('Devices','Intune','Defender')) {
        $index=@{}
        foreach ($row in $sets[$source]) {
            $id=if (Test-Guid $row.DeviceId) { ([guid]$row.DeviceId).ToString() } else { '' }
            $row | Add-Member NoteProperty IdentityKey $id
            if ($id) { if (-not $index.ContainsKey($id)) { $index[$id]=0 }; $index[$id]++ }
        }
        $indexes[$source]=$index
    }
    $strongOwners=@{}; $nameOwners=@{}
    if ($Report -eq 'Missing or weak owner') {
        foreach ($user in @(Invoke-Database 'SELECT ObjectId,UPN,DisplayName FROM users;')) {
            foreach ($key in @($user.ObjectId,$user.UPN)) {
                $key=([string]$key).Trim()
                if ($key) { if (-not $strongOwners.ContainsKey($key)) { $strongOwners[$key]=0 }; $strongOwners[$key]++ }
            }
            $key=([string]$user.DisplayName).Trim()
            if ($key) { if (-not $nameOwners.ContainsKey($key)) { $nameOwners[$key]=0 }; $nameOwners[$key]++ }
        }
    }
    $sources=switch ($Report) {
        'Duplicate identities' { 'Devices'; 'Intune'; 'Defender' }
        { $_ -like 'Intune*' } { 'Intune' }
        { $_ -like 'Defender*' } { 'Defender' }
        default { 'Devices' }
    }
    $generated=[DateTime]::UtcNow.ToString('o')
    foreach ($source in $sources) {
        foreach ($row in $sets[$source]) {
            $id=$row.IdentityKey
            $entra=$id -and $indexes.Devices.ContainsKey($id)
            $intune=$id -and $indexes.Intune.ContainsKey($id)
            $defender=$id -and $indexes.Defender.ContainsKey($id)
            $include=$false; $finding=''; $state='Observed in snapshot'; $owner=''
            $target=switch ($Report) {
                'Entra without Intune' { 'Intune' }
                'Entra without Defender' { 'Defender' }
                'Intune without Defender' { 'Defender' }
                'Defender without Intune' { 'Intune' }
            }
            if ($target) {
                $include=-not ($id -and $indexes[$target].ContainsKey($id))
                $state=if (-not $loaded[$target]) { 'Not loaded' } elseif (-not $id) { 'Invalid identity' } else { 'Missing in snapshot' }
                $finding=if ($state -eq 'Not loaded') { "$target snapshot not loaded; absence cannot be assessed" } elseif (-not $id) { 'No valid Entra Device ID; cannot establish an identity link' } else { "Valid Entra Device ID absent from $target snapshot" }
            } else {
                switch ($Report) {
                    'Intune without valid Entra Device ID' { $include=-not $id; $finding='Missing, zero or malformed Azure AD Device ID' }
                    'Defender without valid AAD Device Id' { $include=-not $id; $finding='Missing, zero or malformed AAD Device Id' }
                    'Disabled Entra with inventory records' { $include=($row.Enabled -ieq 'false' -and ($intune -or $defender)); $finding="Disabled Entra record; Intune link: $intune; Defender link: $defender" }
                    'Defender-only records' {
                        $include=-not $entra -and -not $intune
                        $finding='No valid identity link to Entra or Intune in imported snapshots'
                        if (-not $loaded.Devices -or -not $loaded.Intune) { $state='Not loaded'; $finding='Entra or Intune snapshot not loaded; Defender-only status cannot be confirmed' }
                    }
                    'Duplicate identities' { $include=$id -and $indexes[$source][$id] -gt 1; $finding="Repeated valid Entra Device ID within $source" }
                    'Missing or weak owner' {
                        $owner=([string]$row.OwnerText).Trim()
                        $include=$true
                        if (-not $owner) { $finding='No OwnerText in Entra snapshot' }
                        elseif (-not $loaded.Users) { $state='Not loaded'; $finding='Users snapshot not loaded; OwnerText cannot be assessed' }
                        elseif ($strongOwners.ContainsKey($owner) -and $strongOwners[$owner] -eq 1) { $include=$false }
                        elseif ($nameOwners.ContainsKey($owner)) { $finding="Weak display-name match ($($nameOwners[$owner]) imported users); not an ownership link" }
                        else { $finding='Weak/unresolved OwnerText: no unique exact user Object ID or UPN match' }
                    }
                }
            }
            if ($include) {
                [pscustomobject][ordered]@{
                    Report=$Report; Dataset=$source; DeviceName=$row.DeviceName; RecordId=$row.RecordId
                    EntraDeviceId=$id; Assessment=$state; Finding=$finding; OwnerText=$owner
                    EntraRecords=$(if ($entra) { $indexes.Devices[$id] } else { 0 })
                    IntuneRecords=$(if ($intune) { $indexes.Intune[$id] } else { 0 })
                    DefenderRecords=$(if ($defender) { $indexes.Defender[$id] } else { 0 })
                    GeneratedUtc=$generated; Snapshots=$context
                }
            }
        }
    }
}
function Get-ReportKqlNames([object[]]$Rows) {
    @($Rows | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_.DeviceName)) { $_.DeviceName } } | Select-Object -Unique)
}
