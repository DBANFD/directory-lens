#requires -Version 5.1
function Test-GroupTables {
    (@(Invoke-Database "SELECT name FROM sqlite_master WHERE type='table' AND name='group_snapshots';").Count -gt 0)
}
function Get-GroupCatalog([string]$Query='') {
    if (-not (Test-GroupTables)) { return }
    $key=Sql-Text $Query.Trim().ToUpperInvariant()
    Invoke-Database "SELECT g.*,s.ImportedUtc,s.SourceFile,s.MemberCount,CASE WHEN s.GroupId IS NULL THEN 'Not loaded' ELSE 'Loaded' END AS MembershipSnapshot FROM groups g LEFT JOIN group_snapshots s ON s.GroupId=g.GroupId WHERE instr(g.NameKey,$key)>0 OR upper(g.GroupId)=$key ORDER BY g.DisplayName,g.GroupId LIMIT 1000;"
}
function Get-TargetGroup([string]$GroupId) {
    if (-not (Test-Guid $GroupId) -or -not (Test-GroupTables)) { throw 'Select a group from an imported catalog first.' }
    $rows=@(Invoke-Database ('SELECT * FROM groups WHERE GroupId='+(Sql-Text ([guid]$GroupId).ToString())+';'))
    if ($rows.Count -ne 1) { throw 'Target group is not in the current catalog.' }
    $rows[0]
}
function Test-GroupWritable($Group,[string]$EntityType) {
    if ($Group.MembershipType -ine 'assigned' -or $Group.OnPremisesSyncEnabled -ieq 'true' -or $Group.Source -ine 'Cloud') { return $false }
    if ($Group.GroupType -eq 'Security') { return $true }
    return ($Group.GroupType -eq 'Microsoft 365' -and $EntityType -eq 'Users')
}
function Backup-GroupDatabase {
    if (Test-Path -LiteralPath $DatabasePath) {
        $backup=$DatabasePath+'.backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
        Invoke-Database ('VACUUM INTO '+(Sql-Text ([IO.Path]::GetFullPath($backup)))+';') -Write
    }
}
function Import-GroupCatalog([string]$CsvPath) {
    $rows=@(Read-CsvFile $CsvPath)
    if (-not $rows.Count) { throw 'Group catalog is empty. Existing data unchanged.' }
    $idColumn=Find-Column $rows[0] @('id','objectId','groupId')
    $nameColumn=Find-Column $rows[0] @('displayName','Name')
    $typeColumn=Find-Column $rows[0] @('groupType')
    $membershipColumn=Find-Column $rows[0] @('membershipType')
    $sourceColumn=Find-Column $rows[0] @('source') -Optional
    $mailColumn=Find-Column $rows[0] @('mailEnabled') -Optional
    $syncColumn=Find-Column $rows[0] @('onPremisesSyncEnabled') -Optional
    $sql=[Text.StringBuilder]::new()
    [void]$sql.AppendLine('BEGIN IMMEDIATE;')
    [void]$sql.AppendLine((Get-Content (Join-Path $PSScriptRoot 'groups-schema.sql') -Raw))
    [void]$sql.AppendLine('DELETE FROM groups;')
    $seen=@{}
    foreach ($row in $rows) {
        $id=[string]$row.$idColumn
        if (-not (Test-Guid $id)) { throw 'Invalid group Object ID. Existing data unchanged.' }
        $id=([guid]$id).ToString()
        if ($seen.ContainsKey($id)) { throw 'Duplicate group Object ID. Existing data unchanged.' }
        $seen[$id]=$true
        $name=([string]$row.$nameColumn).Trim()
        $source=if ($sourceColumn) { [string]$row.$sourceColumn } else { '' }
        $mail=if ($mailColumn) { [string]$row.$mailColumn } else { '' }
        $sync=if ($syncColumn) { [string]$row.$syncColumn } else { '' }
        $values=@($id,$name,$name.ToUpperInvariant(),[string]$row.$typeColumn,[string]$row.$membershipColumn,$source,$mail,$sync) | ForEach-Object { Sql-Text $_ }
        [void]$sql.AppendLine('INSERT INTO groups VALUES ('+($values -join ',')+');')
    }
    [void]$sql.AppendLine('PRAGMA user_version=3; COMMIT;')
    Backup-GroupDatabase
    Invoke-Database $sql.ToString() -Write
    [pscustomobject]@{Message="Imported $($rows.Count) groups. Member snapshots are retained separately; groups without a snapshot are not treated as empty."}
}
function Import-GroupMembers([string]$GroupId,[string]$CsvPath,[switch]$CompleteSnapshot) {
    $group=Get-TargetGroup $GroupId
    if (-not $CompleteSnapshot) { throw 'Confirm this is the complete direct-member export for the selected group.' }
    $rows=@(Read-CsvFile $CsvPath)
    # Parse even header-only exports so an explicitly confirmed empty group is supported.
    $line=Get-Content -LiteralPath $CsvPath -Encoding UTF8 -TotalCount 1
    $probe=$null;$max=0
    foreach ($delimiter in @(',', ';', "`t")) {
        $candidate=@($line,$line) | ConvertFrom-Csv -Delimiter $delimiter
        if (@($candidate.PSObject.Properties).Count -gt $max) { $probe=$candidate;$max=@($candidate.PSObject.Properties).Count }
    }
    if (-not $probe) { throw 'Member CSV needs a header row.' }
    if (Find-Column $probe @('groupType','membershipType') -Optional) { throw 'This is a group catalog, not a member export. Export Members for the selected group.' }
    $idColumn=Find-Column $probe @('id','objectId','memberId','memberObjectId')
    $groupColumn=Find-Column $probe @('groupId') -Optional
    $seen=@{}
    $sql=[Text.StringBuilder]::new()
    [void]$sql.AppendLine('BEGIN IMMEDIATE;')
    $target=Sql-Text $group.GroupId
    [void]$sql.AppendLine("DELETE FROM group_members WHERE GroupId=$target;")
    foreach ($row in $rows) {
        if ($groupColumn -and ([string]$row.$groupColumn).Trim() -ine $group.GroupId) { throw 'A row belongs to a different group. Existing snapshot unchanged.' }
        $id=([string]$row.$idColumn).Trim()
        if (-not (Test-Guid $id)) { throw 'Invalid member Object ID. Existing snapshot unchanged.' }
        $id=([guid]$id).ToString()
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id]=$true
        [void]$sql.AppendLine("INSERT INTO group_members VALUES ($target,"+(Sql-Text $id)+');')
    }
    $file=Get-Item -LiteralPath $CsvPath
    $values=@($group.GroupId,[DateTime]::UtcNow.ToString('o'),$file.Name,$file.LastWriteTimeUtc.ToString('o')) | ForEach-Object { Sql-Text $_ }
    [void]$sql.AppendLine('INSERT OR REPLACE INTO group_snapshots VALUES ('+($values -join ',')+','+$seen.Count+'); COMMIT;')
    Backup-GroupDatabase
    Invoke-Database $sql.ToString() -Write
    [pscustomobject]@{Message="Loaded $($seen.Count) unique direct members for $($group.DisplayName)."}
}
function Compare-GroupMembers([string]$GroupId,[object[]]$Candidates,[ValidateSet('Devices','Users')][string]$EntityType) {
    $group=Get-TargetGroup $GroupId
    $key=Sql-Text $group.GroupId
    $snapshot=@(Invoke-Database "SELECT * FROM group_snapshots WHERE GroupId=$key;")
    if (-not $snapshot.Count) { throw 'Membership not loaded. Import a complete direct-member CSV for this group before comparing.' }
    $members=@{}
    foreach ($member in @(Invoke-Database "SELECT MemberId FROM group_members WHERE GroupId=$key;")) { $members[$member.MemberId]=$true }
    $seen=@{}
    $writable=Test-GroupWritable $group $EntityType
    foreach ($candidate in $Candidates) {
        $inputName=if ($candidate.PSObject.Properties['RequestedUser']) { [string]$candidate.RequestedUser } elseif ($candidate.PSObject.Properties['RequestedName']) { [string]$candidate.RequestedName } else { [string]$candidate.DisplayName }
        $id=[string]$candidate.ObjectId
        $eligible=$candidate.PSObject.Properties['GroupEligible'] -and $candidate.GroupEligible -and (Test-Guid $id)
        $status='Unresolved'
        if ($eligible) {
            $id=([guid]$id).ToString()
            $status=if ($members.ContainsKey($id)) { 'Existing' } else { 'Missing' }
            if ($seen.ContainsKey($id)) { $status='DuplicateInput' }
            $seen[$id]=$true
        }
        [pscustomobject]@{RequestedName=$inputName;ObjectId=$id;Comparison=$status;GroupEligible=($status -eq 'Missing' -and $writable);TargetGroup=$group.DisplayName;TargetGroupId=$group.GroupId;MembershipImportedUtc=$snapshot[0].ImportedUtc;MembershipSource=$snapshot[0].SourceFile;ExportPolicy=$(if ($writable) { 'Manual additions supported' } else { 'Comparison only: target type/source does not support this manual upload' })}
    }
}
