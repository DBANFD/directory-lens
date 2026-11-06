Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$script:SqliteExe = Join-Path $PSScriptRoot 'lib\sqlite3.exe'

function Sql-Text([string]$Text) {
    if ($Text.IndexOf([char]0) -ge 0) {
        # Preserve embedded nulls from source exports without sending them to the CLI parser.
        $hex = [BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($Text)).Replace('-', '')
        return "CAST(X'$hex' AS TEXT)"
    }
    return "'" + $Text.Replace("'", "''") + "'"
}
function Invoke-Database([string]$Sql, [switch]$Write) {
    if (-not (Test-Path -LiteralPath $script:SqliteExe)) { throw 'Missing lib\sqlite3.exe. Extract the entire package.' }
    if (-not $Write -and -not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) { throw 'Database not found. Import an export first.' }
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DatabasePath)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:SqliteExe
    $mode = if ($Write) { '' } else { '-readonly ' }
    $info.Arguments = '-batch -bail -json -cmd ".timeout 10000" -init NUL ' + $mode + '"' + $fullPath + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $info
    try {
        [void]$p.Start()
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        $bytes = [Text.Encoding]::UTF8.GetBytes($Sql + "`n")
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.Close()
        $p.WaitForExit()
        $out = $stdout.Result
        $err = $stderr.Result
        if ($p.ExitCode -ne 0) { throw "Database operation failed: $err" }
        if (-not [string]::IsNullOrWhiteSpace($out)) {
            $parsed = $out | ConvertFrom-Json
            foreach ($record in $parsed) { $record }
        }
    } finally { $p.Dispose() }
}
function Get-DatabaseSummary {
    Invoke-Database @'
WITH counts AS (SELECT 'Devices' AS Dataset, count(*) AS Records FROM devices UNION ALL SELECT 'Users', count(*) FROM users)
SELECT c.Dataset, c.Records, i.ImportedUtc, i.SourceFile, i.SourceModifiedUtc
FROM counts c LEFT JOIN imports i ON i.ImportId=(SELECT max(j.ImportId) FROM imports j WHERE j.Dataset=c.Dataset);
'@
    if (Test-IntuneDataset) {
        Invoke-Database "SELECT 'Intune' AS Dataset, (SELECT count(*) FROM intune) AS Records, i.ImportedUtc, i.SourceFile, i.SourceModifiedUtc FROM (SELECT 1) LEFT JOIN imports i ON i.ImportId=(SELECT max(ImportId) FROM imports WHERE Dataset='Intune');"
    }
}
function Search-EntraDevices([string[]]$Names) {
    # One indexed query per batch; never place raw names in SQL identifiers or commands.
    $sql = New-Object Text.StringBuilder
    [void]$sql.AppendLine('WITH requested(seq,name,key) AS (VALUES')
    for ($i=0; $i -lt $Names.Count; $i++) {
        $name = ([string]$Names[$i]).Trim()
        if ($i) { [void]$sql.AppendLine(',') }
        [void]$sql.Append(('({0},{1},{2})' -f $i, (Sql-Text $name), (Sql-Text $name.ToUpperInvariant())))
    }
    if ($Names.Count -eq 0) { return }
    [void]$sql.AppendLine(@'
)
SELECT r.seq, r.name AS RequestedName, d.DeviceName, d.DeviceId, d.ObjectId,
 d.OS, d.JoinType, d.Enabled, d.OwnerText, d.LastSignIn,
 (SELECT count(*) FROM devices x WHERE x.NameKey=r.key AND r.key<>'') AS MatchCount
FROM requested r LEFT JOIN devices d ON d.NameKey=r.key AND r.key<>'' ORDER BY r.seq,d.ObjectId;
'@)
    foreach ($row in @(Invoke-Database $sql.ToString())) {
        $status = if (-not $row.RequestedName) { 'EmptyName' } elseif ($row.MatchCount -eq 0) { 'NotFound' } elseif ($row.MatchCount -gt 1) { 'Ambiguous' } elseif (-not (Test-Guid $row.DeviceId)) { 'InvalidDeviceId' } else { 'Matched' }
        [pscustomobject]@{
            RequestedName=$row.RequestedName; DeviceName=$row.DeviceName; DeviceId=$row.DeviceId
            ObjectId=$row.ObjectId; Status=$status
            GroupEligible=($row.MatchCount -eq 1 -and (Test-Guid $row.ObjectId))
            OS=$row.OS; JoinType=$row.JoinType; Enabled=$row.Enabled
            EntraOwnerText=$row.OwnerText; LastSignIn=$row.LastSignIn
        }
    }
}
function Search-EntraDeviceText([string]$Query) {
    $name = $Query.Trim()
    if (-not $name) { throw 'Enter part of a device name.' }
    $key = Sql-Text $name.ToUpperInvariant()
    $rows = @(Invoke-Database "SELECT d.*, (SELECT count(*) FROM devices x WHERE x.NameKey=d.NameKey) AS MatchCount FROM devices d WHERE instr(d.NameKey,$key)>0 ORDER BY CASE WHEN d.NameKey=$key THEN 0 ELSE 1 END, d.DeviceName,d.ObjectId;")
    foreach ($row in $rows) {
        $exact = $row.NameKey -ceq $name.ToUpperInvariant()
        $status = if (-not $exact) { 'PartialMatch' } elseif ($row.MatchCount -gt 1) { 'Ambiguous' } else { 'Matched' }
        [pscustomobject]@{
            RequestedName=$name; DeviceName=$row.DeviceName; DeviceId=$row.DeviceId; ObjectId=$row.ObjectId
            Status=$status; GroupEligible=($exact -and $row.MatchCount -eq 1 -and (Test-Guid $row.ObjectId))
            OS=$row.OS; JoinType=$row.JoinType; Enabled=$row.Enabled; EntraOwnerText=$row.OwnerText; LastSignIn=$row.LastSignIn
        }
    }
}
function Search-UserList([string[]]$Values) {
    if (-not $Values.Count) { return }
    $sql=New-Object Text.StringBuilder
    [void]$sql.AppendLine('WITH requested(seq,value,key,kind) AS (VALUES')
    for ($i=0; $i -lt $Values.Count; $i++) {
        $value=([string]$Values[$i]).Trim()
        $kind=if (Test-Guid $value) { 'Id' } elseif ($value.Contains('@')) { 'UPN' } else { 'Name' }
        $key=if ($kind -eq 'Id') { ([guid]$value).ToString() } else { $value.ToUpperInvariant() }
        if ($i) { [void]$sql.AppendLine(',') }
        [void]$sql.Append(('({0},{1},{2},{3})' -f ($i+1),(Sql-Text $value),(Sql-Text $key),(Sql-Text $kind)))
    }
    [void]$sql.AppendLine(@'
), hits AS (
 SELECT r.seq,u.* FROM requested r JOIN users u ON
  (r.kind='Id' AND u.ObjectId=r.key) OR
  (r.kind='UPN' AND u.UpnKey=r.key) OR
  (r.kind='Name' AND r.key<>'' AND u.NameKey=r.key)
)
SELECT r.seq AS InputRow, r.value AS RequestedUser, r.kind AS MatchBy,
 h.DisplayName,h.UPN,h.ObjectId,h.Department,h.Enabled,
 (SELECT count(*) FROM hits x WHERE x.seq=r.seq) AS MatchCount
FROM requested r LEFT JOIN hits h ON h.seq=r.seq ORDER BY r.seq,h.ObjectId;
'@)
    foreach ($row in @(Invoke-Database $sql.ToString())) {
        $status=if (-not $row.RequestedUser) { 'EmptyValue' } elseif ($row.MatchCount -eq 0) { 'NotFound' } elseif ($row.MatchCount -gt 1) { 'Ambiguous' } elseif (-not (Test-Guid $row.ObjectId)) { 'InvalidObjectId' } else { 'Matched' }
        [pscustomobject]@{
            InputRow=$row.InputRow; RequestedUser=$row.RequestedUser; RequestedName=$row.RequestedUser
            Status=$status; MatchBy=$row.MatchBy; DisplayName=$row.DisplayName; UPN=$row.UPN
            ObjectId=$row.ObjectId; Department=$row.Department; Enabled=$row.Enabled
            GroupEligible=($status -eq 'Matched')
        }
    }
}
function New-DeviceKql {
    param([string[]]$Names, [ValidateSet('Defender mode and transition','Device inventory and health','Recent successful logons','SentinelOne and MDE coexistence','Security-agent uninstall activity','Application Control audit and blocks','Missing or stale device telemetry','ASR audit and blocks','Network Protection audit and blocks','Controlled Folder Access','Defender configuration gaps')][string]$Template='Defender mode and transition', [ValidateRange(1,30)][int]$Days=2, [string]$Application='')
    $Application=$Application.Trim()
    if ($Application -match '[\x00-\x1f\x7f]') { throw 'Application name must be a single filename without control characters.' }
    $applicationTemplates=@('ASR audit and blocks','Network Protection audit and blocks','Controlled Folder Access')
    if ($Application -and $Template -notin $applicationTemplates) { throw 'Application filtering is not supported by this template.' }
    $seen=@{}
    $normalized=New-Object 'System.Collections.Generic.List[string]'
    $inputCount=0
    foreach ($raw in $Names) {
        $name=([string]$raw).Trim()
        if (-not $name) { continue }
        $inputCount++
        if ($name -match '[\x00-\x1f\x7f]') { throw "A device name contains control characters (entry $inputCount). Remove them before generating KQL." }
        $name=($name -split '\.',2)[0].Trim().ToUpperInvariant()
        if (-not $name) { throw "A device name has an empty short hostname (entry $inputCount)." }
        if (-not $seen.ContainsKey($name)) { $seen[$name]=$true; $normalized.Add($name) }
    }
    if (-not $normalized.Count) { throw 'Enter at least one device name, one per line.' }
    if ($normalized.Count -gt 10000) { throw 'Use at most 10,000 unique names per query. Split the list into smaller batches.' }
    $literals=@(foreach ($name in $normalized) { '    '+(ConvertTo-Json -InputObject $name -Compress) })
    $prefix="// Generated locally for Microsoft Defender XDR Advanced Hunting. Not executed.`n// Short-hostname matching; same short names across domains collapse to one target.`n// Portal time range and available telemetry still apply. Missing devices may have no rows.`nlet TargetDevices = dynamic([`n"+($literals -join ",`n")+"`n]);`n"
    $body=switch ($Template) {
        'Defender mode and transition' { @'
// Based on the supplied SCID-2010 query. Registry transitions are historical evidence,
// not confirmation of the current AV mode. No assessment-age cutoff is applied.
DeviceInfo
| extend ComputerName = tostring(split(DeviceName, ".")[0])
| where ComputerName in~ (TargetDevices)
| summarize arg_max(Timestamp, *) by ComputerName
| project ComputerName, DeviceId, OSPlatform, ClientVersion, DeviceLastSeen = Timestamp
| join kind=leftouter (
    DeviceTvmSecureConfigurationAssessment
    | where ConfigurationId == "scid-2010"
    | where isnotempty(Context)
    | extend ModeCode = tostring(parse_json(Context)[0][0])
    | summarize arg_max(Timestamp, *) by DeviceId
    | project DeviceId, ModeCode, ModeAssessmentTime = Timestamp
) on DeviceId
| join kind=leftouter (
    DeviceRegistryEvents
    | where Timestamp > ago(__DAYS__d)
    | where ActionType == "RegistryValueSet"
    | where RegistryKey =~ @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Defender"
    | where RegistryValueName =~ "PassiveMode"
    | where PreviousRegistryValueData == "1"
    | where RegistryValueData == "0"
    | summarize arg_max(Timestamp, *) by DeviceId
    | project DeviceId, PassiveToActiveDetected = Timestamp, InitiatingProcessAccountName
) on DeviceId
| extend MDEMode = case(
    ModeCode == "0", "Active",
    ModeCode == "1", "Passive",
    ModeCode == "4", "EDR Block Mode",
    isempty(ModeCode), "No Mode Data",
    "Unknown"
)
| extend Status = case(
    MDEMode == "Active", "OK - MDE ACTIVE",
    MDEMode == "Passive" and isnotempty(PassiveToActiveDetected), "TRANSITION DETECTED - SCID STILL PASSIVE",
    MDEMode == "Passive", "ACTION - MDE PASSIVE",
    MDEMode == "EDR Block Mode", "CHECK - EDR BLOCK MODE",
    MDEMode == "No Mode Data" and isnotempty(PassiveToActiveDetected), "TRANSITION DETECTED - NO SCID DATA",
    MDEMode == "No Mode Data", "CHECK - NO MODE DATA",
    "CHECK - UNKNOWN"
)
| extend SortOrder = case(
    Status == "TRANSITION DETECTED - SCID STILL PASSIVE", 1,
    Status == "ACTION - MDE PASSIVE", 2,
    Status == "TRANSITION DETECTED - NO SCID DATA", 3,
    Status == "CHECK - EDR BLOCK MODE", 4,
    Status == "CHECK - NO MODE DATA", 5,
    Status == "CHECK - UNKNOWN", 6,
    7
)
| project ComputerName, MDEMode, Status, ModeCode, PassiveToActiveDetected,
    ModeAssessmentTime, DeviceLastSeen, OSPlatform, ClientVersion,
    InitiatingProcessAccountName, SortOrder
| order by SortOrder asc, ComputerName asc
| project-away SortOrder
'@ }
        'Device inventory and health' { @'
DeviceInfo
| extend ComputerName = tostring(split(DeviceName, ".")[0])
| where ComputerName in~ (TargetDevices)
| summarize arg_max(Timestamp, *) by DeviceId
| project ComputerName, DeviceName, DeviceId, AadDeviceId, OSPlatform,
    OSVersion, ClientVersion, OnboardingStatus, SensorHealthState,
    DeviceLastSeen = Timestamp
| order by ComputerName asc, DeviceLastSeen desc
'@ }
        'SentinelOne and MDE coexistence' { @'
// Process evidence is historical, not proof that S1 is running now.
// No S1 evidence does not prove absence. Software inventory has no observation timestamp.
// Windows mode uses SCID-2010; other platforms retain Unknown pending platform-specific checks.
let Devices = DeviceInfo
| extend ComputerName = tostring(split(DeviceName, ".")[0])
| where ComputerName in~ (TargetDevices)
| summarize arg_max(Timestamp, *) by DeviceId
| project ComputerName, DeviceName, DeviceId, OSPlatform, OnboardingStatus,
    SensorHealthState, DeviceLastSeen = Timestamp;
let S1Processes = DeviceProcessEvents
| where Timestamp > ago(__DAYS__d)
| extend ComputerName = tostring(split(DeviceName, ".")[0])
| where ComputerName in~ (TargetDevices)
| where FileName in~ ("SentinelAgent.exe", "SentinelServiceHost.exe", "SentinelOne", "sentinel-agent", "sentineld")
| summarize S1ProcessLastSeen = max(Timestamp), S1Processes = make_set(FileName, 20) by DeviceId;
let S1Software = DeviceTvmSoftwareInventory
| extend ComputerName = tostring(split(DeviceName, ".")[0])
| where ComputerName in~ (TargetDevices)
| where SoftwareVendor contains "sentinelone" or SoftwareName contains "sentinelone" or SoftwareName contains "sentinel agent"
| summarize S1Software = make_set(strcat(SoftwareName, " ", SoftwareVersion), 20) by DeviceId;
let Modes = DeviceTvmSecureConfigurationAssessment
| where ConfigurationId == "scid-2010" and isnotempty(Context)
| where DeviceId in (Devices | project DeviceId)
| summarize arg_max(Timestamp, Context) by DeviceId
| project DeviceId, ModeAssessmentTime = Timestamp, ModeCode = tostring(parse_json(Context)[0][0]);
Devices
| join kind=leftouter S1Processes on DeviceId
| join kind=leftouter S1Software on DeviceId
| join kind=leftouter Modes on DeviceId
| extend S1Evidence = case(isnotnull(S1ProcessLastSeen), "Process observed in selected lookback",
    array_length(S1Software) > 0, "Software inventory only", "No evidence in queried sources")
| extend MDEMode = case(OSPlatform !startswith "Windows", "Unknown - platform-specific check needed",
    ModeCode == "0", "Active", ModeCode == "1", "Passive", ModeCode == "4", "EDR Block Mode", "Unknown")
| extend ModeEvidence = case(isnull(ModeAssessmentTime), "No assessment",
    ModeAssessmentTime < ago(__DAYS__d), "Stale assessment", "Assessment within selected lookback")
| project ComputerName, DeviceName, DeviceId, OSPlatform, OnboardingStatus, SensorHealthState,
    DeviceLastSeen, S1Evidence, S1ProcessLastSeen, S1Processes, S1Software,
    MDEMode, ModeEvidence, ModeAssessmentTime
| order by ComputerName asc, DeviceLastSeen desc
'@ }
        'Security-agent uninstall activity' { @'
// Candidate removal activity only: commands do not establish successful removal.
// SYSTEM is the execution account, not necessarily the console/API operator.
// Agent names and command patterns are a starting set, not exhaustive coverage.
DeviceProcessEvents
| where Timestamp > ago(__DAYS__d)
| extend ComputerName = tostring(split(DeviceName, ".")[0])
| where ComputerName in~ (TargetDevices)
| where ProcessCommandLine contains "uninstall" or ProcessCommandLine contains "offboard"
    or ProcessCommandLine contains "approve_uninstall" or ProcessCommandLine contains "wsc_unregister"
    or ProcessCommandLine contains "sw_unregister" or ProcessCommandLine contains "unload"
    or (FileName =~ "msiexec.exe" and (ProcessCommandLine contains "/x" or ProcessCommandLine contains "REMOVE=ALL"))
| where FileName contains "sentinel" or FolderPath contains "sentinel"
    or ProcessCommandLine contains "sentinel" or InitiatingProcessFileName contains "sentinel"
    or InitiatingProcessFolderPath contains "sentinel" or InitiatingProcessCommandLine contains "sentinel"
    or ProcessCommandLine contains "Defender" or ProcessCommandLine contains "mdatp"
    or ProcessCommandLine contains "WindowsAdvancedThreatProtection"
    or InitiatingProcessFolderPath contains "Windows Defender"
| project Timestamp, ComputerName, DeviceName, DeviceId, FileName, ProcessCommandLine,
    AccountDomain, AccountName, InitiatingProcessFileName, InitiatingProcessCommandLine,
    InitiatingProcessAccountName, ReportId
| order by Timestamp desc
'@ }
        'Application Control audit and blocks' { @'
// Audit and block events are distinct. A process start does not prove its script ran.
// AdditionalFields is retained because policy details vary by event type.
DeviceEvents
| where Timestamp > ago(__DAYS__d)
| extend ComputerName = tostring(split(DeviceName, ".")[0])
| where ComputerName in~ (TargetDevices)
| where ActionType startswith "AppControl"
| where ActionType endswith "Audited" or ActionType endswith "Blocked"
| extend EvidenceType = iff(ActionType endswith "Blocked", "Block event", "Audit event")
| project Timestamp, ComputerName, DeviceName, DeviceId, EvidenceType, ActionType,
    FileName, FolderPath, SHA1, InitiatingProcessFileName, InitiatingProcessCommandLine,
    InitiatingProcessAccountName, AdditionalFields, ReportId
| order by Timestamp desc
'@ }
        'Missing or stale device telemetry' { @'
// Set the portal range wider than the selected stale threshold to see older records.
// Missing means no DeviceInfo in the portal range, not proof the device is not onboarded.
// Keep distinct MDE DeviceIds so duplicate/re-onboarded identities remain visible.
let LatestDevices = DeviceInfo
| extend ComputerName = toupper(tostring(split(DeviceName, ".")[0]))
| where ComputerName in~ (TargetDevices)
| summarize arg_max(Timestamp, *) by DeviceId
| project ComputerName, DeviceName, DeviceId, AadDeviceId, OSPlatform,
    OnboardingStatus, SensorHealthState, DeviceLastSeen = Timestamp;
print Names = TargetDevices
| mv-expand ComputerName = Names to typeof(string)
| project ComputerName
| join kind=leftouter LatestDevices on ComputerName
| extend TelemetryStatus = case(isnull(DeviceLastSeen), "No telemetry in portal range",
    DeviceLastSeen < ago(__DAYS__d), "Stale telemetry", "Recent telemetry")
| extend SortOrder = case(isnull(DeviceLastSeen), 0, DeviceLastSeen < ago(__DAYS__d), 1, 2)
| project ComputerName, TelemetryStatus, DeviceLastSeen, DeviceName, DeviceId,
    AadDeviceId, OSPlatform, OnboardingStatus, SensorHealthState, SortOrder
| order by SortOrder asc, ComputerName asc, DeviceLastSeen desc
| project-away SortOrder
'@ }
        'ASR audit and blocks' { @'
// ASR events are throttled; counts are observed events, not all attempts.
// No events does not prove rules are disabled or the application is unaffected.
// Optional application filter matches the affected file or initiating process, exactly.
DeviceEvents
| where Timestamp > ago(__DAYS__d)
| extend ComputerName = tostring(split(DeviceName, ".")[0])
| where ComputerName in~ (TargetDevices)
| where ActionType startswith "Asr"
| where ActionType endswith "Audited" or ActionType endswith "Blocked" or ActionType endswith "WarnBypassed"
__APP_FILTER__
| extend EvidenceType = case(ActionType endswith "Audited", "Audit event",
    ActionType endswith "Blocked", "Block event", "Warning bypassed")
| extend RuleId = tostring(parse_json(AdditionalFields).RuleId)
| project Timestamp, ComputerName, DeviceName, DeviceId, EvidenceType, ActionType,
    RuleId, FileName, FolderPath, InitiatingProcessFileName, InitiatingProcessCommandLine,
    InitiatingProcessAccountName, AdditionalFields, ReportId
| order by Timestamp desc
'@ }
        'Network Protection audit and blocks' { @'
// Network Protection events only, not a complete firewall or connectivity test.
// No events does not establish that a destination is reachable or permitted.
DeviceEvents
| where Timestamp > ago(__DAYS__d)
| extend ComputerName = tostring(split(DeviceName, ".")[0])
| where ComputerName in~ (TargetDevices)
| where ActionType in ("ExploitGuardNetworkProtectionAudited", "ExploitGuardNetworkProtectionBlocked")
__APP_FILTER__
| extend EvidenceType = iff(ActionType endswith "Blocked", "Block event", "Audit event")
| extend Details = parse_json(AdditionalFields)
| project Timestamp, ComputerName, DeviceName, DeviceId, EvidenceType, ActionType,
    RemoteUrl, RemoteIP, ResponseCategory = tostring(Details.ResponseCategory),
    DisplayName = tostring(Details.DisplayName), FileName, InitiatingProcessFileName,
    InitiatingProcessCommandLine, InitiatingProcessAccountName, AdditionalFields, ReportId
| order by Timestamp desc
'@ }
        'Controlled Folder Access' { @'
// CFA evidence only; no events does not rule out permissions, file locks or other causes.
// Application filter matches the initiating process, not the target document filename.
DeviceEvents
| where Timestamp > ago(__DAYS__d)
| extend ComputerName = tostring(split(DeviceName, ".")[0])
| where ComputerName in~ (TargetDevices)
| where ActionType in ("ControlledFolderAccessViolationAudited", "ControlledFolderAccessViolationBlocked")
__APP_FILTER__
| extend EvidenceType = iff(ActionType endswith "Blocked", "Block event", "Audit event")
| project Timestamp, ComputerName, DeviceName, DeviceId, EvidenceType, ActionType,
    FileName, FolderPath, InitiatingProcessFileName, InitiatingProcessCommandLine,
    InitiatingProcessAccountName, AdditionalFields, ReportId
| order by Timestamp desc
'@ }
        'Defender configuration gaps' { @'
// Latest applicable, noncompliant Antivirus assessments per device/configuration.
// Historical assessment evidence, not live endpoint state or Intune policy compliance.
// Days is a freshness threshold, not a filter: stale findings remain visible.
// Empty output can mean missing assessment coverage, not necessarily no gaps.
DeviceTvmSecureConfigurationAssessment
| extend ComputerName = tostring(split(DeviceName, ".")[0])
| where ComputerName in~ (TargetDevices)
| where ConfigurationSubcategory =~ "Antivirus"
| summarize arg_max(Timestamp, *) by DeviceId, ConfigurationId
| where IsApplicable == true and IsCompliant == false
| join kind=leftouter (
    DeviceTvmSecureConfigurationAssessmentKB
    | project ConfigurationId, ConfigurationName, ConfigurationDescription, RiskDescription
) on ConfigurationId
| extend AssessmentFreshness = iff(Timestamp < ago(__DAYS__d), "Stale assessment", "Recent assessment")
| project ComputerName, DeviceName, DeviceId, OSPlatform, ConfigurationId,
    ConfigurationName, ConfigurationDescription, RiskDescription, ConfigurationImpact,
    AssessmentTime = Timestamp, AssessmentFreshness, IsApplicable, IsCompliant, Context
| order by ConfigurationImpact desc, ComputerName asc
'@ }
        'Recent successful logons' { @'
// Logon evidence is not an Intune primary-user assignment.
DeviceLogonEvents
| where Timestamp > ago(__DAYS__d)
| where ActionType == "LogonSuccess"
| extend ComputerName = tostring(split(DeviceName, ".")[0])
| where ComputerName in~ (TargetDevices)
| summarize arg_max(Timestamp, *) by DeviceId, AccountDomain, AccountName
| project ComputerName, DeviceName, DeviceId, AccountDomain, AccountName,
    LogonType, RemoteIP, LastSuccessfulLogon = Timestamp
| order by ComputerName asc, LastSuccessfulLogon desc
'@ }
    }
    $appFilter=''
    if ($Application) {
        $literal=ConvertTo-Json -InputObject $Application -Compress
        $appFilter=if ($Template -eq 'ASR audit and blocks') { '| where FileName =~ '+$literal+' or InitiatingProcessFileName =~ '+$literal } else { '| where InitiatingProcessFileName =~ '+$literal }
    }
    [pscustomobject]@{ Query=$prefix+$body.Replace('__DAYS__',[string]$Days).Replace('__APP_FILTER__',$appFilter); Count=$normalized.Count; InputCount=$inputCount; Names=$normalized.ToArray() }
}
function Test-IntuneDataset {
    return (@(Invoke-Database "SELECT name FROM sqlite_master WHERE type='table' AND name='intune';").Count -gt 0)
}
function Add-IntuneInventory($Row, $Inventory, [string[]]$Headers, [int]$Count=0) {
    $record=[ordered]@{}
    foreach ($property in $Row.PSObject.Properties) { $record[$property.Name]=$property.Value }
    $record['IntuneLink']=if ($Inventory) { if ($Row.ObjectId) { 'Azure AD Device ID' } else { 'Intune only: no Entra ID match' } } else { 'No linked Intune record in snapshot' }
    $record['IntuneEnrollmentCount']=$Count
    foreach ($header in $Headers) {
        $field='Intune'+($header -replace '[^a-zA-Z0-9]','')
        $record[$field]=if ($Inventory) { [string]$Inventory.$header } else { '' }
    }
    [pscustomobject]$record
}
function Merge-IntuneResults([object[]]$Rows, [string[]]$Names, [switch]$Partial) {
    if (-not (Test-IntuneDataset)) { $Rows; return }
    $sample=@(Invoke-Database 'SELECT InventoryJson FROM intune LIMIT 1;')
    if (-not $sample.Count) { $Rows; return }
    $headers=@(($sample[0].InventoryJson | ConvertFrom-Json).PSObject.Properties.Name)
    $ids=@($Rows | ForEach-Object { if (Test-Guid $_.DeviceId) { Sql-Text ([guid]$_.DeviceId).ToString() } } | Select-Object -Unique)
    $byId=@{}
    if ($ids.Count) {
        foreach ($item in @(Invoke-Database ("SELECT * FROM intune WHERE DeviceId IN ("+($ids -join ',')+") ORDER BY IntuneDeviceId;"))) {
            if (-not $byId.ContainsKey($item.DeviceId)) { $byId[$item.DeviceId]=New-Object Collections.Generic.List[object] }
            $byId[$item.DeviceId].Add(($item.InventoryJson | ConvertFrom-Json))
        }
    }
    $keys=@($Names | ForEach-Object { Sql-Text $_.Trim().ToUpperInvariant() } | Select-Object -Unique)
    if (-not $keys.Count) { return }
    $condition=if ($Partial) { 'instr(i.NameKey,'+$keys[0]+')>0' } else { 'i.NameKey IN ('+($keys -join ',')+") AND i.NameKey<>''" }
    # Never link by hostname: retain orphan enrollments, even when an Entra name is identical.
    $orphans=@(Invoke-Database ("SELECT i.* FROM intune i WHERE $condition AND NOT EXISTS (SELECT 1 FROM devices d WHERE d.DeviceId=i.DeviceId COLLATE NOCASE AND i.DeviceId<>'') ORDER BY i.DeviceName,i.IntuneDeviceId;"))
    $orphansByName=@{}
    foreach ($item in $orphans) {
        if (-not $orphansByName.ContainsKey($item.NameKey)) { $orphansByName[$item.NameKey]=New-Object Collections.Generic.List[object] }
        $orphansByName[$item.NameKey].Add($item)
    }
    foreach ($row in $Rows) {
        $nameKey=$row.RequestedName.ToUpperInvariant()
        if ($row.Status -eq 'NotFound' -and $orphansByName.ContainsKey($nameKey)) { continue }
        $id=[string]$row.DeviceId
        if (Test-Guid $id) { $id=([guid]$id).ToString() }
        # An unlinked same-name device makes name-only group selection unsafe.
        if ($orphansByName.ContainsKey($nameKey)) { $row.GroupEligible=$false; if ($row.Status -eq 'Matched') { $row.Status='Ambiguous' } }
        if ($byId.ContainsKey($id)) {
            foreach ($inventory in $byId[$id]) { Add-IntuneInventory $row $inventory $headers $byId[$id].Count }
        } else { Add-IntuneInventory $row $null $headers }
    }
    # Repeat orphan matches per bulk input, retaining the caller's original requested name.
    foreach ($name in $Names) {
        $items=if ($Partial) { $orphans } elseif ($orphansByName.ContainsKey($name.Trim().ToUpperInvariant())) { $orphansByName[$name.Trim().ToUpperInvariant()] } else { @() }
        foreach ($item in $items) {
            $inventory=$item.InventoryJson | ConvertFrom-Json
            $row=[pscustomobject]@{RequestedName=$name.Trim(); DeviceName=$item.DeviceName; DeviceId=$item.DeviceId; ObjectId=''; Status='IntuneOnly'; GroupEligible=$false; OS=[string]$inventory.OS; JoinType=''; Enabled=''; EntraOwnerText=''; LastSignIn=''}
            Add-IntuneInventory $row $inventory $headers 1
        }
    }
}
function Search-Devices([string[]]$Names) {
    if (-not $Names.Count) { return }
    Merge-IntuneResults -Rows @(Search-EntraDevices $Names) -Names $Names
}
function Search-DeviceText([string]$Query) {
    Merge-IntuneResults -Rows @(Search-EntraDeviceText $Query) -Names @($Query) -Partial
}
function Search-Users([string]$Query) {
    if ([string]::IsNullOrWhiteSpace($Query)) { throw 'Enter a user name, UPN or Object ID.' }
    $normalized = $Query.Trim().ToUpperInvariant()
    $key = Sql-Text $normalized
    $terms = @($normalized -split '[\s,]+' | Where-Object { $_ })
    if (-not $terms.Count) { throw 'Enter at least one name or email search term.' }
    # Literal substring matching: every term must occur in the name or UPN,
    # regardless of order. Percent, underscore and apostrophes are literal text.
    $conditions = foreach ($term in $terms) {
        $quoted = Sql-Text $term
        "(instr(NameKey,$quoted)>0 OR instr(UpnKey,$quoted)>0)"
    }
    $where = $conditions -join ' AND '
    Invoke-Database "SELECT DisplayName, UPN, ObjectId, Department, Enabled FROM users WHERE upper(ObjectId)=$key OR ($where) ORDER BY CASE WHEN NameKey=$key OR UpnKey=$key OR upper(ObjectId)=$key THEN 0 ELSE 1 END, DisplayName, UPN, ObjectId;"
}
