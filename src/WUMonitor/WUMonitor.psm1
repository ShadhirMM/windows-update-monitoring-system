#Requires -Version 5.1
<#
    WUMonitor - read-only Windows Update configuration monitor.

    Design rules (enforced by tests/ReadOnly.Tests.ps1):
      * Nothing in this module changes Windows settings, services or registry values.
      * The only files written are the monitor's own log files and webhook outbox files.

    Layout:
      Configuration  - defaults, JSON loading, validation
      Collection     - Get-WURawState (self-contained so it can run remotely)
      Evaluation     - one Test-WU* function per check, pure functions (no I/O)
      Reporting      - report object, webhook payload formats
      Delivery       - webhook POST with retry, outbox for failed deliveries
      Logging        - file log with retention, Windows Event Log
      Orchestration  - Invoke-WUMonitorRun
#>

Set-StrictMode -Version 2.0

$script:WUMonitorVersion = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'WUMonitor.psd1')).ModuleVersion
$script:LogFile = $null
$script:LogDirectory = $null
$script:EventSource = 'WUMonitor'
$script:StatusRank = @{ OK = 0; WARNING = 1; ALERT = 2 }

#region Helpers

function Get-WUProp {
    # Safe property read that works for hashtables, PSCustomObjects and deserialized
    # remote objects, and does not throw under strict mode when a property is missing.
    [CmdletBinding()]
    param(
        [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-WUInt {
    # Null-safe integer conversion. Note: "$null -as [int]" returns 0 in PowerShell, which would
    # make a missing registry value look like an explicit 0. This returns $null instead.
    [CmdletBinding()]
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [int]) { return $Value }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $result = 0
    if ([int]::TryParse($text.Trim(), [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$result)) {
        return $result
    }
    return $null
}

function ConvertTo-WUDateTimeUtc {
    # Converts registry strings ("2026-05-15T12:26:40Z", "2026-05-15") and DateTime values to UTC.
    # Returns $null for empty or unparseable input.
    [CmdletBinding()]
    [OutputType([datetime])]
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-WUWorstStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()] [string[]] $Status)

    $worst = 'OK'
    foreach ($item in $Status) {
        if ($script:StatusRank.ContainsKey($item) -and $script:StatusRank[$item] -gt $script:StatusRank[$worst]) {
            $worst = $item
        }
    }
    return $worst
}

function Get-WUHostFromUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $uri = $null
    if ([uri]::TryCreate($Value.Trim(), [System.UriKind]::Absolute, [ref]$uri) -and $uri.Host) {
        return $uri.Host.ToLowerInvariant()
    }
    return $Value.Trim().TrimEnd('/').ToLowerInvariant()
}

function Get-WUMaskedUrl {
    # Webhook URLs contain secrets in the path or query. Only scheme and host are ever logged.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [string] $Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return '<not configured>' }
    $uri = $null
    if ([uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        return '{0}://{1}/***' -f $uri.Scheme, $uri.Authority
    }
    return '<invalid url>'
}

#endregion

#region Configuration

function Get-WUDefaultConfig {
    <#
    .SYNOPSIS
        Returns the built-in default configuration as a hashtable.
    .NOTES
        OsLifecycle dates are Microsoft "end of servicing" dates. Verify them against
        https://learn.microsoft.com/lifecycle before relying on them and keep the table current.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $dataRoot = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($dataRoot)) { $dataRoot = [System.IO.Path]::GetTempPath() }

    return @{
        Webhook            = @{
            Url            = ''
            Format         = 'generic'
            SendOn         = 'Always'
            TimeoutSeconds = 15
            RetryCount     = 3
        }
        Thresholds         = @{
            LastUpdateWarnDays       = 35
            LastUpdateAlertDays      = 60
            PauseAlertDays           = 7
            QualityDeferralWarnDays  = 7
            QualityDeferralAlertDays = 14
            FeatureDeferralWarnDays  = 180
            RebootAlertDays          = 7
            FailureLookbackDays      = 30
            FailureAlertCount        = 3
            OsEndOfServiceWarnDays   = 60
        }
        History            = @{
            QualityUpdatePattern = '(Cumulative|Security|Quality) Update'
            ExcludePattern       = 'Security Intelligence|Defender|\.NET|Malicious Software Removal'
        }
        AllowedWsusServers = @()
        UnknownBuildStatus = 'WARNING'
        OsLifecycle        = @(
            @{ Build = 17763; Release = 'Windows 10 1809 / LTSC 2019 / Server 2019'; Pro = '2020-11-10'; Enterprise = '2021-05-11'; Ltsc = '2029-01-09'; Server = '2029-01-09' }
            @{ Build = 19044; Release = 'Windows 10 21H2 / LTSC 2021'; Pro = '2023-06-13'; Enterprise = '2024-06-11'; Ltsc = '2027-01-12'; Server = $null }
            @{ Build = 19045; Release = 'Windows 10 22H2'; Pro = '2025-10-14'; Enterprise = '2025-10-14'; Ltsc = $null; Server = $null }
            @{ Build = 20348; Release = 'Windows Server 2022'; Pro = $null; Enterprise = $null; Ltsc = $null; Server = '2031-10-14' }
            @{ Build = 22621; Release = 'Windows 11 22H2'; Pro = '2024-10-08'; Enterprise = '2025-10-14'; Ltsc = $null; Server = $null }
            @{ Build = 22631; Release = 'Windows 11 23H2'; Pro = '2025-11-11'; Enterprise = '2026-11-10'; Ltsc = $null; Server = $null }
            @{ Build = 26100; Release = 'Windows 11 24H2 / LTSC 2024 / Server 2025'; Pro = '2026-10-13'; Enterprise = '2027-10-12'; Ltsc = '2029-10-09'; Server = '2034-11-14' }
            @{ Build = 26200; Release = 'Windows 11 25H2'; Pro = '2027-10-12'; Enterprise = '2028-10-10'; Ltsc = $null; Server = $null }
        )
        Logging            = @{
            Path          = (Join-Path $dataRoot 'WUMonitor\Logs')
            RetentionDays = 30
            EventLog      = $true
        }
        Outbox             = @{
            Path       = (Join-Path $dataRoot 'WUMonitor\Outbox')
            MaxAgeDays = 30
        }
        Computers          = @()
    }
}

function ConvertTo-WUHashtable {
    # Windows PowerShell 5.1 has no ConvertFrom-Json -AsHashtable, so convert manually.
    [CmdletBinding()]
    param([AllowNull()] $InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject.GetType().IsValueType) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) { $table[[string]$key] = ConvertTo-WUHashtable -InputObject $InputObject[$key] }
        return $table
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = @(foreach ($item in $InputObject) { , (ConvertTo-WUHashtable -InputObject $item) })
        return , $list
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-WUHashtable -InputObject $property.Value
        }
        return $table
    }
    return $InputObject
}

function Merge-WUConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $Base,
        [Parameter(Mandatory)] [hashtable] $Override
    )

    $result = @{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    foreach ($key in $Override.Keys) {
        if ($key.StartsWith('_')) { continue } # "_comment" style keys are documentation only
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $result[$key] = Merge-WUConfig -Base $result[$key] -Override $Override[$key]
        }
        else {
            $result[$key] = $Override[$key]
        }
    }
    return $result
}

function Assert-WUConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)

    $problems = [System.Collections.Generic.List[string]]::new()

    $formats = @('generic', 'teams', 'slack', 'discord')
    if ($formats -notcontains [string]$Config.Webhook.Format) {
        $problems.Add("Webhook.Format '$($Config.Webhook.Format)' is not one of: $($formats -join ', ')")
    }
    $sendOn = @('Always', 'WarningOrAbove', 'AlertOnly')
    if ($sendOn -notcontains [string]$Config.Webhook.SendOn) {
        $problems.Add("Webhook.SendOn '$($Config.Webhook.SendOn)' is not one of: $($sendOn -join ', ')")
    }
    $url = [string]$Config.Webhook.Url
    if ($url -and $url -notmatch '^https?://') {
        $problems.Add('Webhook.Url must start with https:// (or http:// for local testing)')
    }

    $numbers = @('TimeoutSeconds', 'RetryCount')
    foreach ($name in $numbers) {
        $value = ConvertTo-WUInt $Config.Webhook[$name]
        if ($null -eq $value -or $value -lt 0) { $problems.Add("Webhook.$name must be a number >= 0") }
    }

    foreach ($name in @($Config.Thresholds.Keys)) {
        $value = ConvertTo-WUInt $Config.Thresholds[$name]
        if ($null -eq $value -or $value -lt 1) { $problems.Add("Thresholds.$name must be a whole number >= 1") }
    }
    $pairs = @(
        @('LastUpdateWarnDays', 'LastUpdateAlertDays'),
        @('QualityDeferralWarnDays', 'QualityDeferralAlertDays')
    )
    foreach ($pair in $pairs) {
        $warn = ConvertTo-WUInt $Config.Thresholds[$pair[0]]
        $alert = ConvertTo-WUInt $Config.Thresholds[$pair[1]]
        if ($null -ne $warn -and $null -ne $alert -and $warn -ge $alert) {
            $problems.Add("Thresholds.$($pair[0]) ($warn) must be lower than Thresholds.$($pair[1]) ($alert)")
        }
    }

    if (@('OK', 'WARNING', 'ALERT') -notcontains [string]$Config.UnknownBuildStatus) {
        $problems.Add('UnknownBuildStatus must be OK, WARNING or ALERT')
    }
    foreach ($pattern in @($Config.History.QualityUpdatePattern, $Config.History.ExcludePattern)) {
        try { [void][regex]::new([string]$pattern) }
        catch { $problems.Add("History pattern '$pattern' is not a valid regular expression") }
    }
    foreach ($entry in @($Config.OsLifecycle)) {
        if ($null -eq ((ConvertTo-WUInt (Get-WUProp $entry 'Build')))) { $problems.Add('Every OsLifecycle entry needs a numeric Build') }
    }

    if ($problems.Count -gt 0) {
        throw ('Invalid configuration: ' + ($problems -join '; '))
    }
}

function Get-WUMonitorConfig {
    <#
    .SYNOPSIS
        Loads the configuration: built-in defaults, overridden by the JSON file, overridden by
        the WUMONITOR_WEBHOOK_URL environment variable. Throws if the result is invalid.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string] $Path)

    $config = Get-WUDefaultConfig
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Config file not found: $Path"
        }
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        try {
            $parsed = $json | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Config file '$Path' is not valid JSON: $($_.Exception.Message)"
        }
        $config = Merge-WUConfig -Base $config -Override (ConvertTo-WUHashtable -InputObject $parsed)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:WUMONITOR_WEBHOOK_URL)) {
        $config.Webhook.Url = $env:WUMONITOR_WEBHOOK_URL
    }
    Assert-WUConfig -Config $config
    return $config
}

#endregion

#region Collection

function Get-WURawState {
    <#
    .SYNOPSIS
        Collects raw Windows Update configuration and health data. Read-only.
    .DESCRIPTION
        Self-contained (no calls to other module functions) so that it can be sent to remote
        computers with Invoke-Command -ScriptBlock. Every section is collected independently:
        a failure in one section is recorded in CollectorErrors and the section is $null.
    #>
    [CmdletBinding()]
    param(
        [string] $QualityUpdatePattern = '(Cumulative|Security|Quality) Update',
        [string] $ExcludePattern = 'Security Intelligence|Defender|\.NET|Malicious Software Removal',
        [int] $FailureLookbackDays = 30
    )

    $collectorErrors = [System.Collections.Generic.List[string]]::new()

    function Get-RegistryValueSet {
        param([string] $Path, [string[]] $Name)
        $values = [ordered]@{}
        foreach ($valueName in $Name) { $values[$valueName] = $null }
        if (Test-Path -LiteralPath $Path) {
            $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
            foreach ($valueName in $Name) {
                $property = $item.PSObject.Properties[$valueName]
                if ($null -ne $property) { $values[$valueName] = $property.Value }
            }
        }
        [pscustomobject]$values
    }

    # --- Operating system -------------------------------------------------------------
    $os = $null
    try {
        $cim = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $currentVersion = Get-RegistryValueSet -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name @('DisplayVersion', 'ReleaseId', 'UBR', 'EditionID')
        $displayVersion = [string]$currentVersion.DisplayVersion
        if (-not $displayVersion) { $displayVersion = [string]$currentVersion.ReleaseId }
        $os = [pscustomobject]@{
            Caption        = [string]$cim.Caption
            Version        = [string]$cim.Version
            Build          = [int]$cim.BuildNumber
            UBR            = $currentVersion.UBR
            DisplayVersion = $displayVersion
            EditionID      = [string]$currentVersion.EditionID
            ProductType    = [int]$cim.ProductType
            LastBootUpTime = $cim.LastBootUpTime
        }
    }
    catch { $collectorErrors.Add("OperatingSystem: $($_.Exception.Message)") }

    # --- Services ---------------------------------------------------------------------
    $services = $null
    try {
        $services = @(foreach ($serviceName in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
                $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                if ($service) {
                    [pscustomobject]@{ Name = $serviceName; Exists = $true; Status = [string]$service.Status; StartType = [string]$service.StartType }
                }
                else {
                    [pscustomobject]@{ Name = $serviceName; Exists = $false; Status = $null; StartType = $null }
                }
            })
    }
    catch { $collectorErrors.Add("Services: $($_.Exception.Message)") }

    # --- Group Policy / MDM policy values ---------------------------------------------
    $policy = $null
    try {
        $wuPolicy = Get-RegistryValueSet -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name @(
            'WUServer', 'WUStatusServer', 'DeferQualityUpdates', 'DeferQualityUpdatesPeriodInDays',
            'DeferFeatureUpdates', 'DeferFeatureUpdatesPeriodInDays', 'PauseQualityUpdatesStartTime',
            'PauseFeatureUpdatesStartTime', 'TargetReleaseVersion', 'TargetReleaseVersionInfo', 'ProductVersion',
            'DisableWindowsUpdateAccess', 'DoNotConnectToWindowsUpdateInternetLocations', 'SetDisableUXWUAccess')
        $auPolicy = Get-RegistryValueSet -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name @(
            'NoAutoUpdate', 'AUOptions', 'ScheduledInstallDay', 'ScheduledInstallTime', 'UseWUServer', 'NoAutoRebootWithLoggedOnUsers')
        $merged = [ordered]@{}
        foreach ($source in @($wuPolicy, $auPolicy)) {
            foreach ($property in $source.PSObject.Properties) { $merged[$property.Name] = $property.Value }
        }
        $policy = [pscustomobject]$merged
    }
    catch { $collectorErrors.Add("Policy: $($_.Exception.Message)") }

    # --- User-initiated pause (Settings app) ------------------------------------------
    $pause = $null
    try {
        $pause = Get-RegistryValueSet -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name @(
            'PauseUpdatesStartTime', 'PauseUpdatesExpiryTime', 'PauseQualityUpdatesEndTime', 'PauseFeatureUpdatesEndTime')
    }
    catch { $collectorErrors.Add("Pause: $($_.Exception.Message)") }

    # --- Pending reboot -----------------------------------------------------------------
    $reboot = $null
    try {
        $reboot = [pscustomobject]@{
            WindowsUpdate         = [bool](Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
            ComponentBasedService = [bool](Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        }
    }
    catch { $collectorErrors.Add("Reboot: $($_.Exception.Message)") }

    # --- Update history -----------------------------------------------------------------
    # Primary source: Windows Update Agent COM API (read-only QueryHistory).
    # Fallback: Get-HotFix (no failure information, less precise).
    $history = $null
    try {
        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()
        $total = [int]$searcher.GetTotalHistoryCount()
        $entries = [System.Collections.Generic.List[object]]::new()
        if ($total -gt 0) {
            foreach ($entry in $searcher.QueryHistory(0, [Math]::Min($total, 2000))) {
                # Operation 1 = installation (2 = uninstallation)
                if ([int]$entry.Operation -ne 1) { continue }
                $title = [string]$entry.Title
                if ($ExcludePattern -and $title -match $ExcludePattern) { continue }
                $kb = $null
                if ($title -match 'KB\d+') { $kb = $Matches[0] }
                $entries.Add([pscustomobject]@{
                        Title      = $title
                        KB         = $kb
                        Date       = [datetime]$entry.Date
                        ResultCode = [int]$entry.ResultCode
                        HResult    = '0x{0:X8}' -f [int]$entry.HResult
                    })
            }
        }

        $lastQuality = $null
        $lastAny = $null
        $succeededKeys = @{}
        $failures = [ordered]@{}
        $cutoff = (Get-Date).AddDays(-$FailureLookbackDays)
        foreach ($entry in ($entries | Sort-Object -Property Date -Descending)) {
            $key = $entry.KB
            if (-not $key) { $key = $entry.Title }
            # ResultCode: 2 = Succeeded, 3 = SucceededWithErrors, 4 = Failed, 5 = Aborted
            if ($entry.ResultCode -eq 2 -or $entry.ResultCode -eq 3) {
                $succeededKeys[$key] = $true
                if ($null -eq $lastAny) { $lastAny = $entry }
                if ($null -eq $lastQuality -and $entry.Title -match $QualityUpdatePattern) { $lastQuality = $entry }
            }
            elseif ($entry.ResultCode -eq 4 -or $entry.ResultCode -eq 5) {
                # A failure is "resolved" if the same update later installed successfully.
                if ($entry.Date -ge $cutoff -and -not $succeededKeys.ContainsKey($key) -and -not $failures.Contains($key)) {
                    $failures[$key] = $entry
                }
            }
        }
        $history = [pscustomobject]@{
            Source            = 'WindowsUpdateAgent'
            EntriesScanned    = $entries.Count
            LastQualityUpdate = $lastQuality
            LastAnyUpdate     = $lastAny
            Failures          = @($failures.Values)
        }
    }
    catch {
        $collectorErrors.Add("UpdateHistory (Windows Update Agent): $($_.Exception.Message)")
        try {
            $hotfix = Get-HotFix -ErrorAction Stop |
                Where-Object { $_.InstalledOn } |
                Sort-Object -Property InstalledOn -Descending |
                Select-Object -First 1
            $last = $null
            if ($hotfix) {
                $last = [pscustomobject]@{
                    Title      = '{0} ({1})' -f $hotfix.HotFixID, $hotfix.Description
                    KB         = [string]$hotfix.HotFixID
                    Date       = [datetime]$hotfix.InstalledOn
                    ResultCode = 2
                    HResult    = $null
                }
            }
            $history = [pscustomobject]@{
                Source            = 'Get-HotFix'
                EntriesScanned    = 0
                LastQualityUpdate = $last
                LastAnyUpdate     = $last
                Failures          = @()
            }
        }
        catch { $collectorErrors.Add("UpdateHistory (Get-HotFix): $($_.Exception.Message)") }
    }

    [pscustomobject]@{
        ComputerName    = $env:COMPUTERNAME
        CollectedAtUtc  = (Get-Date).ToUniversalTime()
        Os              = $os
        Services        = $services
        Policy          = $policy
        Pause           = $pause
        Reboot          = $reboot
        History         = $history
        CollectorErrors = $collectorErrors.ToArray()
    }
}

#endregion

#region Evaluation

function New-WUCheck {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('OK', 'WARNING', 'ALERT')] [string] $Status,
        [Parameter(Mandatory)] [string] $Message
    )
    [pscustomobject][ordered]@{ Name = $Name; Status = $Status; Message = $Message }
}

function Test-WUServiceState {
    [CmdletBinding()]
    param([AllowNull()] [object[]] $Services)

    $name = 'ServiceState'
    if ($null -eq $Services -or @($Services).Count -eq 0) {
        return New-WUCheck -Name $name -Status WARNING -Message 'Service state could not be read'
    }

    $status = 'OK'
    $notes = [System.Collections.Generic.List[string]]::new()
    $details = [System.Collections.Generic.List[string]]::new()
    foreach ($service in $Services) {
        $serviceName = [string](Get-WUProp $service 'Name')
        $exists = [bool](Get-WUProp $service 'Exists')
        $startType = [string](Get-WUProp $service 'StartType')
        if (-not $exists) {
            if ($serviceName -eq 'wuauserv') {
                $status = Get-WUWorstStatus @($status, 'ALERT'); $notes.Add('wuauserv (Windows Update) service is missing')
            }
            continue
        }
        $details.Add(('{0}: {1}' -f $serviceName, $startType))
        if ($startType -eq 'Disabled') {
            switch ($serviceName) {
                'wuauserv' { $status = Get-WUWorstStatus @($status, 'ALERT'); $notes.Add('wuauserv (Windows Update) is Disabled') }
                'UsoSvc' { $status = Get-WUWorstStatus @($status, 'ALERT'); $notes.Add('UsoSvc (Update Orchestrator) is Disabled') }
                default { $status = Get-WUWorstStatus @($status, 'WARNING'); $notes.Add("$serviceName is Disabled") }
            }
        }
    }
    if ($notes.Count -gt 0) {
        return New-WUCheck -Name $name -Status $status -Message ($notes -join '; ')
    }
    return New-WUCheck -Name $name -Status OK -Message ('Update services enabled (' + ($details -join ', ') + ')')
}

function Test-WUAutoUpdatePolicy {
    [CmdletBinding()]
    param([AllowNull()] $Policy)

    $name = 'AutoUpdatePolicy'
    if ($null -eq $Policy) { return New-WUCheck -Name $name -Status WARNING -Message 'Update policy could not be read' }

    $noAutoUpdate = (ConvertTo-WUInt (Get-WUProp $Policy 'NoAutoUpdate'))
    $auOptions = (ConvertTo-WUInt (Get-WUProp $Policy 'AUOptions'))

    if ($noAutoUpdate -eq 1) {
        return New-WUCheck -Name $name -Status ALERT -Message 'Automatic Updates disabled by policy (NoAutoUpdate=1)'
    }
    switch ($auOptions) {
        $null { return New-WUCheck -Name $name -Status OK -Message 'No Automatic Updates policy set (Windows default: automatic download and install)' }
        2 { return New-WUCheck -Name $name -Status WARNING -Message 'AUOptions=2: notify before download; updates need manual action' }
        3 { return New-WUCheck -Name $name -Status WARNING -Message 'AUOptions=3: download automatically, notify to install; installs need manual action' }
        4 { return New-WUCheck -Name $name -Status OK -Message 'AUOptions=4: automatic download and scheduled install' }
        5 { return New-WUCheck -Name $name -Status WARNING -Message 'AUOptions=5: local administrator chooses the setting' }
        7 { return New-WUCheck -Name $name -Status WARNING -Message 'AUOptions=7: download automatically, notify to install and restart' }
        default { return New-WUCheck -Name $name -Status WARNING -Message "Unrecognised AUOptions value: $auOptions" }
    }
}

function Test-WUPauseState {
    [CmdletBinding()]
    param(
        [AllowNull()] $Pause,
        [AllowNull()] $Policy,
        [Parameter(Mandatory)] [hashtable] $Thresholds,
        [Parameter(Mandatory)] [datetime] $Now
    )

    $name = 'PauseState'
    if ($null -eq $Pause -and $null -eq $Policy) {
        return New-WUCheck -Name $name -Status WARNING -Message 'Pause settings could not be read'
    }
    $nowUtc = ConvertTo-WUDateTimeUtc $Now

    # Policy-based pauses last 35 days from the configured start date.
    $qualityEnds = @(
        (ConvertTo-WUDateTimeUtc (Get-WUProp $Pause 'PauseUpdatesExpiryTime'))
        (ConvertTo-WUDateTimeUtc (Get-WUProp $Pause 'PauseQualityUpdatesEndTime'))
    )
    $policyQualityStart = ConvertTo-WUDateTimeUtc (Get-WUProp $Policy 'PauseQualityUpdatesStartTime')
    if ($policyQualityStart) { $qualityEnds += $policyQualityStart.AddDays(35) }

    $featureEnds = @((ConvertTo-WUDateTimeUtc (Get-WUProp $Pause 'PauseFeatureUpdatesEndTime')))
    $policyFeatureStart = ConvertTo-WUDateTimeUtc (Get-WUProp $Policy 'PauseFeatureUpdatesStartTime')
    if ($policyFeatureStart) { $featureEnds += $policyFeatureStart.AddDays(35) }

    $qualityEnd = $qualityEnds | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
    $featureEnd = $featureEnds | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1

    if ($qualityEnd -and $qualityEnd -gt $nowUtc) {
        $daysLeft = [int][Math]::Ceiling(($qualityEnd - $nowUtc).TotalDays)
        $status = 'WARNING'
        if ($daysLeft -gt [int]$Thresholds.PauseAlertDays) { $status = 'ALERT' }
        return New-WUCheck -Name $name -Status $status -Message ('Updates paused until {0:yyyy-MM-dd} ({1} days remaining)' -f $qualityEnd, $daysLeft)
    }
    if ($featureEnd -and $featureEnd -gt $nowUtc) {
        return New-WUCheck -Name $name -Status OK -Message ('Quality updates not paused; feature updates paused until {0:yyyy-MM-dd}' -f $featureEnd)
    }
    return New-WUCheck -Name $name -Status OK -Message 'Updates are not paused'
}

function Test-WUDeferralPolicy {
    [CmdletBinding()]
    param(
        [AllowNull()] $Policy,
        [Parameter(Mandatory)] [hashtable] $Thresholds
    )

    $name = 'DeferralPolicy'
    if ($null -eq $Policy) { return New-WUCheck -Name $name -Status WARNING -Message 'Deferral policy could not be read' }

    $qualityDays = $null
    $qualityFlag = (ConvertTo-WUInt (Get-WUProp $Policy 'DeferQualityUpdates'))
    if ($null -eq $qualityFlag -or $qualityFlag -eq 1) { $qualityDays = (ConvertTo-WUInt (Get-WUProp $Policy 'DeferQualityUpdatesPeriodInDays')) }
    $featureDays = $null
    $featureFlag = (ConvertTo-WUInt (Get-WUProp $Policy 'DeferFeatureUpdates'))
    if ($null -eq $featureFlag -or $featureFlag -eq 1) { $featureDays = (ConvertTo-WUInt (Get-WUProp $Policy 'DeferFeatureUpdatesPeriodInDays')) }

    $status = 'OK'
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $qualityDays -and $qualityDays -gt 0) {
        $parts.Add("quality updates deferred $qualityDays days")
        if ($qualityDays -gt [int]$Thresholds.QualityDeferralAlertDays) { $status = Get-WUWorstStatus @($status, 'ALERT') }
        elseif ($qualityDays -gt [int]$Thresholds.QualityDeferralWarnDays) { $status = Get-WUWorstStatus @($status, 'WARNING') }
    }
    if ($null -ne $featureDays -and $featureDays -gt 0) {
        $parts.Add("feature updates deferred $featureDays days")
        if ($featureDays -gt [int]$Thresholds.FeatureDeferralWarnDays) { $status = Get-WUWorstStatus @($status, 'WARNING') }
    }
    if (((ConvertTo-WUInt (Get-WUProp $Policy 'TargetReleaseVersion'))) -eq 1) {
        $parts.Add(('pinned to {0} {1}' -f (Get-WUProp $Policy 'ProductVersion'), (Get-WUProp $Policy 'TargetReleaseVersionInfo')).Trim())
    }
    if ($parts.Count -eq 0) { return New-WUCheck -Name $name -Status OK -Message 'No update deferral configured' }
    $message = ($parts -join '; ')
    return New-WUCheck -Name $name -Status $status -Message ($message.Substring(0, 1).ToUpperInvariant() + $message.Substring(1))
}

function Test-WUUpdateSource {
    [CmdletBinding()]
    param(
        [AllowNull()] $Policy,
        [AllowNull()] [AllowEmptyCollection()] [string[]] $AllowedWsusServers
    )

    $name = 'UpdateSource'
    if ($null -eq $Policy) { return New-WUCheck -Name $name -Status WARNING -Message 'Update source policy could not be read' }

    $useWsus = ((ConvertTo-WUInt (Get-WUProp $Policy 'UseWUServer'))) -eq 1
    $server = [string](Get-WUProp $Policy 'WUServer')
    $noInternet = ((ConvertTo-WUInt (Get-WUProp $Policy 'DoNotConnectToWindowsUpdateInternetLocations'))) -eq 1

    if ($useWsus) {
        if ([string]::IsNullOrWhiteSpace($server)) {
            return New-WUCheck -Name $name -Status ALERT -Message 'UseWUServer=1 but no WUServer is set: the machine has no valid update source'
        }
        $allowedHosts = @($AllowedWsusServers | Where-Object { $_ } | ForEach-Object { Get-WUHostFromUrl $_ })
        if ($allowedHosts -contains (Get-WUHostFromUrl $server)) {
            return New-WUCheck -Name $name -Status OK -Message "Managed by approved WSUS server $server"
        }
        return New-WUCheck -Name $name -Status WARNING -Message "WSUS server '$server' is not in AllowedWsusServers"
    }
    if ($noInternet) {
        return New-WUCheck -Name $name -Status ALERT -Message 'DoNotConnectToWindowsUpdateInternetLocations=1 without WSUS: the machine cannot reach any update source'
    }
    return New-WUCheck -Name $name -Status OK -Message 'Microsoft Windows Update online service'
}

function Test-WULastQualityUpdate {
    [CmdletBinding()]
    param(
        [AllowNull()] $History,
        [Parameter(Mandatory)] [hashtable] $Thresholds,
        [Parameter(Mandatory)] [datetime] $Now
    )

    $name = 'LastQualityUpdate'
    if ($null -eq $History) { return New-WUCheck -Name $name -Status WARNING -Message 'Update history could not be read' }

    $last = Get-WUProp $History 'LastQualityUpdate'
    $lastDate = ConvertTo-WUDateTimeUtc (Get-WUProp $last 'Date')
    if ($null -eq $last -or $null -eq $lastDate) {
        return New-WUCheck -Name $name -Status WARNING -Message 'No successful quality update found in update history'
    }

    $days = [int][Math]::Floor(((ConvertTo-WUDateTimeUtc $Now) - $lastDate).TotalDays)
    if ($days -lt 0) { $days = 0 }
    $status = 'OK'
    if ($days -gt [int]$Thresholds.LastUpdateAlertDays) { $status = 'ALERT' }
    elseif ($days -gt [int]$Thresholds.LastUpdateWarnDays) { $status = 'WARNING' }

    $message = '{0} days ago on {1:yyyy-MM-dd}: {2}' -f $days, $lastDate, (Get-WUProp $last 'Title')
    if ((Get-WUProp $History 'Source') -eq 'Get-HotFix') { $message += ' (source: Get-HotFix, approximate)' }
    return New-WUCheck -Name $name -Status $status -Message $message
}

function Test-WURecentFailure {
    [CmdletBinding()]
    param(
        [AllowNull()] $History,
        [Parameter(Mandatory)] [hashtable] $Thresholds
    )

    $name = 'RecentFailures'
    if ($null -eq $History) { return New-WUCheck -Name $name -Status WARNING -Message 'Update history could not be read' }
    if ((Get-WUProp $History 'Source') -ne 'WindowsUpdateAgent') {
        return New-WUCheck -Name $name -Status WARNING -Message 'Failure history unavailable (Windows Update Agent could not be queried)'
    }

    $lookback = [int]$Thresholds.FailureLookbackDays
    $failures = @(Get-WUProp $History 'Failures' | Where-Object { $_ })
    if ($failures.Count -eq 0) {
        return New-WUCheck -Name $name -Status OK -Message "No unresolved update failures in the last $lookback days"
    }
    $status = 'WARNING'
    if ($failures.Count -ge [int]$Thresholds.FailureAlertCount) { $status = 'ALERT' }
    $listed = @($failures | Select-Object -First 3 | ForEach-Object {
            $label = Get-WUProp $_ 'KB'
            if (-not $label) { $label = Get-WUProp $_ 'Title' }
            '{0} ({1})' -f $label, (Get-WUProp $_ 'HResult')
        })
    $more = ''
    if ($failures.Count -gt 3) { $more = ", +$($failures.Count - 3) more" }
    return New-WUCheck -Name $name -Status $status -Message ('{0} unresolved failed update(s) in the last {1} days: {2}{3}' -f $failures.Count, $lookback, ($listed -join ', '), $more)
}

function Test-WUPendingReboot {
    [CmdletBinding()]
    param(
        [AllowNull()] $Reboot,
        [AllowNull()] $Os,
        [Parameter(Mandatory)] [hashtable] $Thresholds,
        [Parameter(Mandatory)] [datetime] $Now
    )

    $name = 'PendingReboot'
    if ($null -eq $Reboot) { return New-WUCheck -Name $name -Status WARNING -Message 'Reboot state could not be read' }

    $sources = @()
    if (Get-WUProp $Reboot 'WindowsUpdate') { $sources += 'Windows Update' }
    if (Get-WUProp $Reboot 'ComponentBasedService') { $sources += 'Component Based Servicing' }
    if ($sources.Count -eq 0) { return New-WUCheck -Name $name -Status OK -Message 'No reboot pending' }

    $bootTime = ConvertTo-WUDateTimeUtc (Get-WUProp $Os 'LastBootUpTime')
    if ($null -eq $bootTime) {
        return New-WUCheck -Name $name -Status WARNING -Message ('Reboot pending ({0}); uptime unknown' -f ($sources -join ', '))
    }
    # The registry flags carry no timestamp, so uptime is used as the age of the pending reboot.
    $uptimeDays = [int][Math]::Floor(((ConvertTo-WUDateTimeUtc $Now) - $bootTime).TotalDays)
    $status = 'WARNING'
    if ($uptimeDays -ge [int]$Thresholds.RebootAlertDays) { $status = 'ALERT' }
    return New-WUCheck -Name $name -Status $status -Message ('Reboot pending ({0}); last boot {1} days ago' -f ($sources -join ', '), $uptimeDays)
}

function Test-WUOsSupport {
    [CmdletBinding()]
    param(
        [AllowNull()] $Os,
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Lifecycle,
        [Parameter(Mandatory)] [string] $UnknownBuildStatus,
        [Parameter(Mandatory)] [hashtable] $Thresholds,
        [Parameter(Mandatory)] [datetime] $Now
    )

    $name = 'OsSupport'
    if ($null -eq $Os) { return New-WUCheck -Name $name -Status WARNING -Message 'Operating system details could not be read' }

    $build = (ConvertTo-WUInt (Get-WUProp $Os 'Build'))
    $edition = [string](Get-WUProp $Os 'EditionID')
    $channel = 'Pro'
    if (((ConvertTo-WUInt (Get-WUProp $Os 'ProductType'))) -gt 1) { $channel = 'Server' }
    elseif ($edition -match 'EnterpriseS') { $channel = 'Ltsc' }
    elseif ($edition -match 'Enterprise|Education') { $channel = 'Enterprise' }

    $label = '{0} {1} (build {2}.{3})' -f (Get-WUProp $Os 'Caption'), (Get-WUProp $Os 'DisplayVersion'), $build, (Get-WUProp $Os 'UBR')
    $entry = @($Lifecycle | Where-Object { ((ConvertTo-WUInt (Get-WUProp $_ 'Build'))) -eq $build }) | Select-Object -First 1
    if ($null -eq $entry) {
        return New-WUCheck -Name $name -Status $UnknownBuildStatus -Message "$label is not in the OsLifecycle table; add its end-of-servicing dates to the config"
    }
    $endOfService = ConvertTo-WUDateTimeUtc (Get-WUProp $entry $channel)
    if ($null -eq $endOfService) {
        return New-WUCheck -Name $name -Status $UnknownBuildStatus -Message "$label has no '$channel' end-of-servicing date in the OsLifecycle table"
    }
    $daysLeft = [int][Math]::Floor(($endOfService - (ConvertTo-WUDateTimeUtc $Now)).TotalDays)
    if ($daysLeft -lt 0) {
        return New-WUCheck -Name $name -Status ALERT -Message ('{0} reached end of servicing ({1} channel) on {2:yyyy-MM-dd}' -f $label, $channel, $endOfService)
    }
    if ($daysLeft -le [int]$Thresholds.OsEndOfServiceWarnDays) {
        return New-WUCheck -Name $name -Status WARNING -Message ('{0} reaches end of servicing ({1} channel) in {2} days on {3:yyyy-MM-dd}' -f $label, $channel, $daysLeft, $endOfService)
    }
    return New-WUCheck -Name $name -Status OK -Message ('{0} supported until {1:yyyy-MM-dd} ({2} channel)' -f $label, $endOfService, $channel)
}

function Get-WUCheckResult {
    <#
    .SYNOPSIS
        Evaluates raw state against the configured thresholds. Pure function: no I/O.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $RawState,
        [Parameter(Mandatory)] [hashtable] $Config,
        [datetime] $Now = (Get-Date)
    )

    $thresholds = $Config.Thresholds
    $os = Get-WUProp $RawState 'Os'
    $policy = Get-WUProp $RawState 'Policy'
    $history = Get-WUProp $RawState 'History'

    @(
        Test-WUServiceState -Services (Get-WUProp $RawState 'Services')
        Test-WUAutoUpdatePolicy -Policy $policy
        Test-WUPauseState -Pause (Get-WUProp $RawState 'Pause') -Policy $policy -Thresholds $thresholds -Now $Now
        Test-WUDeferralPolicy -Policy $policy -Thresholds $thresholds
        Test-WUUpdateSource -Policy $policy -AllowedWsusServers @($Config.AllowedWsusServers)
        Test-WULastQualityUpdate -History $history -Thresholds $thresholds -Now $Now
        Test-WURecentFailure -History $history -Thresholds $thresholds
        Test-WUPendingReboot -Reboot (Get-WUProp $RawState 'Reboot') -Os $os -Thresholds $thresholds -Now $Now
        Test-WUOsSupport -Os $os -Lifecycle @($Config.OsLifecycle) -UnknownBuildStatus $Config.UnknownBuildStatus -Thresholds $thresholds -Now $Now
    )
}

#endregion

#region Reporting

function New-WUReport {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Checks,
        [AllowNull()] $RawState,
        [datetime] $Now = (Get-Date)
    )

    $os = Get-WUProp $RawState 'Os'
    $osText = 'unknown'
    if ($os) {
        $osText = ('{0} {1} (build {2}.{3})' -f (Get-WUProp $os 'Caption'), (Get-WUProp $os 'DisplayVersion'), (Get-WUProp $os 'Build'), (Get-WUProp $os 'UBR')).Trim()
    }
    $statuses = @($Checks | ForEach-Object { $_.Status })
    $counts = foreach ($level in @('ALERT', 'WARNING', 'OK')) {
        $count = @($statuses | Where-Object { $_ -eq $level }).Count
        if ($count -gt 0) { '{0} {1}' -f $count, $level }
    }
    $collectorErrors = @(Get-WUProp $RawState 'CollectorErrors' | Where-Object { $_ })

    [pscustomobject][ordered]@{
        ComputerName    = $ComputerName
        Status          = Get-WUWorstStatus -Status $statuses
        Summary         = (@($counts) -join ', ')
        TimestampUtc    = (ConvertTo-WUDateTimeUtc $Now).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        OperatingSystem = $osText
        MonitorVersion  = $script:WUMonitorVersion
        Checks          = @($Checks)
        CollectorErrors = $collectorErrors
    }
}

function Get-WUStatusEmoji {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Status)
    # Built at runtime so the source file stays pure ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI).
    switch ($Status) {
        'OK' { return [char]::ConvertFromUtf32(0x2705) }       # white heavy check mark
        'WARNING' { return [char]::ConvertFromUtf32(0x26A0) }  # warning sign
        'ALERT' { return [char]::ConvertFromUtf32(0x1F6A8) }   # rotating light
        default { return '' }
    }
}

function ConvertTo-WUWebhookPayload {
    <#
    .SYNOPSIS
        Formats a report as a JSON webhook body: generic, teams (Workflows / Adaptive Card),
        slack (incoming webhook) or discord (webhook embed).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Report,
        [ValidateSet('generic', 'teams', 'slack', 'discord')] [string] $Format = 'generic'
    )

    $title = '{0} {1}: Windows Update {2}' -f (Get-WUStatusEmoji $Report.Status), $Report.ComputerName, $Report.Status
    $context = '{0} | {1} | WUMonitor {2}' -f $Report.OperatingSystem, $Report.TimestampUtc, $Report.MonitorVersion

    switch ($Format) {
        'generic' {
            $body = [ordered]@{
                source          = 'WUMonitor'
                host            = $Report.ComputerName
                status          = $Report.Status
                summary         = $Report.Summary
                timestamp       = $Report.TimestampUtc
                operatingSystem = $Report.OperatingSystem
                version         = $Report.MonitorVersion
                checks          = @($Report.Checks | ForEach-Object { [ordered]@{ name = $_.Name; status = $_.Status; message = $_.Message } })
                collectorErrors = @($Report.CollectorErrors)
            }
        }
        'slack' {
            $lines = @($Report.Checks | ForEach-Object { '{0} *{1}* - {2}' -f (Get-WUStatusEmoji $_.Status), $_.Name, $_.Message })
            $body = [ordered]@{
                text   = $title
                blocks = @(
                    [ordered]@{ type = 'header'; text = [ordered]@{ type = 'plain_text'; text = $title } }
                    [ordered]@{ type = 'section'; text = [ordered]@{ type = 'mrkdwn'; text = ($lines -join "`n") } }
                    [ordered]@{ type = 'context'; elements = @([ordered]@{ type = 'mrkdwn'; text = $context }) }
                )
            }
        }
        'discord' {
            $colors = @{ OK = 3066993; WARNING = 15965202; ALERT = 15158332 }
            $fields = @($Report.Checks | ForEach-Object {
                    [ordered]@{ name = ('{0} {1}' -f (Get-WUStatusEmoji $_.Status), $_.Name); value = $_.Message; inline = $false }
                })
            $body = [ordered]@{
                username = 'WU Monitor'
                embeds   = @(
                    [ordered]@{
                        title       = $title
                        description = $Report.Summary
                        color       = $colors[$Report.Status]
                        fields      = $fields
                        footer      = [ordered]@{ text = $context }
                        timestamp   = $Report.TimestampUtc
                    }
                )
            }
        }
        'teams' {
            $colors = @{ OK = 'Good'; WARNING = 'Warning'; ALERT = 'Attention' }
            $facts = @($Report.Checks | ForEach-Object { [ordered]@{ title = $_.Name; value = ('{0}: {1}' -f $_.Status, $_.Message) } })
            $card = [ordered]@{
                '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                type      = 'AdaptiveCard'
                version   = '1.4'
                body      = @(
                    [ordered]@{ type = 'TextBlock'; size = 'Large'; weight = 'Bolder'; wrap = $true; color = $colors[$Report.Status]; text = $title }
                    [ordered]@{ type = 'TextBlock'; isSubtle = $true; wrap = $true; spacing = 'None'; text = $context }
                    [ordered]@{ type = 'TextBlock'; wrap = $true; text = $Report.Summary }
                    [ordered]@{ type = 'FactSet'; facts = $facts }
                )
            }
            $body = [ordered]@{
                type        = 'message'
                attachments = @([ordered]@{ contentType = 'application/vnd.microsoft.card.adaptive'; contentUrl = $null; content = $card })
            }
        }
    }
    return ($body | ConvertTo-Json -Depth 12 -Compress)
}

function Test-WUShouldSend {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Status, [string] $SendOn)
    switch ($SendOn) {
        'WarningOrAbove' { return $script:StatusRank[$Status] -ge 1 }
        'AlertOnly' { return $script:StatusRank[$Status] -ge 2 }
        default { return $true }
    }
}

function Get-WUExitCode {
    <#
    .SYNOPSIS
        0 = all OK, 1 = at least one WARNING, 2 = at least one ALERT.
        (3 = the monitor itself failed; set by Invoke-WUMonitor.ps1.)
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowEmptyCollection()] [object[]] $Report)
    $worst = Get-WUWorstStatus -Status @($Report | ForEach-Object { $_.Status })
    return [int]$script:StatusRank[$worst]
}

#endregion

#region Delivery

function Get-WUHttpStatusCode {
    [CmdletBinding()]
    param($ErrorRecord)
    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response) { return [int]$response.StatusCode }
    }
    catch { Write-Verbose 'No HTTP status code available' }
    return $null
}

function Send-WUWebhook {
    <#
    .SYNOPSIS
        POSTs a JSON body to the webhook with retry and exponential backoff (2s, 4s, 8s...).
        Returns $true on success, $false when every attempt failed. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Body,
        [int] $TimeoutSeconds = 15,
        [int] $RetryCount = 3
    )

    if ($PSVersionTable.PSEdition -ne 'Core') {
        # Windows PowerShell 5.1 may default to TLS 1.0; most webhook endpoints require TLS 1.2+.
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    $masked = Get-WUMaskedUrl $Url
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $attempts = [Math]::Max(1, $RetryCount + 1)

    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            $null = Invoke-RestMethod -Uri $Url -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
            Write-WULog -Message "Webhook delivered to $masked (attempt $attempt/$attempts, $($bytes.Length) bytes)"
            return $true
        }
        catch {
            $code = Get-WUHttpStatusCode $_
            $codeText = ''
            if ($code) { $codeText = " HTTP $code" }
            Write-WULog -Level WARN -Message "Webhook attempt $attempt/$attempts to $masked failed:$codeText $($_.Exception.Message)"
            if ($code -and $code -ge 400 -and $code -lt 500 -and $code -ne 408 -and $code -ne 429) {
                Write-WULog -Level ERROR -Message "Webhook rejected the request (HTTP $code); not retrying. Check the URL and payload format."
                return $false
            }
            if ($attempt -lt $attempts) { Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt)) }
        }
    }
    return $false
}

function Save-WUOutboxItem {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] [string] $Body
    )
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop }
    $file = Join-Path $Path ('{0:yyyyMMddHHmmss}_{1}_{2}.json' -f (Get-Date), $ComputerName, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $item = [ordered]@{ CreatedUtc = (Get-Date).ToUniversalTime().ToString('o'); ComputerName = $ComputerName; Body = $Body }
    Set-Content -LiteralPath $file -Value ($item | ConvertTo-Json -Depth 3) -Encoding UTF8 -ErrorAction Stop
    Write-WULog -Level WARN -Message "Report queued in outbox for the next run: $file"
    return $file
}

function Send-WUOutbox {
    <#
    .SYNOPSIS
        Re-sends reports that could not be delivered on earlier runs. Stops at the first failure
        (the endpoint is probably still down). Drops items older than Outbox.MaxAgeDays.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config
    )
    $path = [string]$Config.Outbox.Path
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    $files = @(Get-ChildItem -LiteralPath $path -Filter '*.json' -File | Sort-Object -Property Name)
    if ($files.Count -eq 0) { return }

    Write-WULog -Message "Outbox contains $($files.Count) undelivered report(s); retrying"
    $cutoff = (Get-Date).AddDays(-[int]$Config.Outbox.MaxAgeDays)
    foreach ($file in $files) {
        try {
            if ($file.LastWriteTime -lt $cutoff) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                Write-WULog -Level WARN -Message "Dropped outbox item older than $($Config.Outbox.MaxAgeDays) days: $($file.Name)"
                continue
            }
            $item = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $sent = Send-WUWebhook -Url $Config.Webhook.Url -Body ([string]$item.Body) -TimeoutSeconds ([int]$Config.Webhook.TimeoutSeconds) -RetryCount 0
            if (-not $sent) {
                Write-WULog -Level WARN -Message 'Outbox delivery failed; remaining items kept for the next run'
                return
            }
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            Write-WULog -Message "Delivered queued report $($file.Name)"
        }
        catch {
            Write-WULog -Level ERROR -Message "Could not process outbox item $($file.Name): $($_.Exception.Message)"
        }
    }
}

#endregion

#region Logging

function Initialize-WULog {
    <#
    .SYNOPSIS
        Selects the log directory (falls back to %TEMP%\WUMonitor\Logs if the configured path
        is not writable) and returns the log file path for today.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Path)

    $candidates = @($Path, (Join-Path ([System.IO.Path]::GetTempPath()) 'WUMonitor\Logs')) | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        try {
            if (-not (Test-Path -LiteralPath $candidate)) { $null = New-Item -ItemType Directory -Path $candidate -Force -ErrorAction Stop }
            $file = Join-Path $candidate ('WUMonitor_{0:yyyyMMdd}.log' -f (Get-Date))
            Add-Content -LiteralPath $file -Value '' -NoNewline -ErrorAction Stop
            $script:LogFile = $file
            $script:LogDirectory = $candidate
            return $file
        }
        catch {
            Write-Verbose "Log directory '$candidate' is not writable: $($_.Exception.Message)"
        }
    }
    $script:LogFile = $null
    $script:LogDirectory = $null
    Write-Warning 'No writable log directory found; logging to the verbose stream only'
    return $null
}

function Write-WULog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Message,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff zzz', [System.Globalization.CultureInfo]::InvariantCulture), $Level, $Message
    Write-Verbose $line
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop }
        catch { Write-Warning "Could not write to log file '$($script:LogFile)': $($_.Exception.Message)" }
    }
}

function Remove-WUOldLog {
    [CmdletBinding(SupportsShouldProcess)]
    param([int] $RetentionDays = 30)

    if (-not $script:LogDirectory) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $old = @(Get-ChildItem -LiteralPath $script:LogDirectory -Filter 'WUMonitor_*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff })
    foreach ($file in $old) {
        if ($PSCmdlet.ShouldProcess($file.FullName, 'Delete old log file')) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                Write-WULog -Message "Deleted log older than $RetentionDays days: $($file.Name)"
            }
            catch { Write-WULog -Level WARN -Message "Could not delete old log $($file.Name): $($_.Exception.Message)" }
        }
    }
}

function Write-WUEventLog {
    <#
    .SYNOPSIS
        Writes to the Application event log when the 'WUMonitor' source exists (created by the
        installer). Event IDs: 1000 OK, 1001 WARNING, 1002 ALERT, 1003 monitor error, 1004 delivery failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [Parameter(Mandatory)] [ValidateSet('OK', 'WARNING', 'ALERT', 'ERROR', 'DELIVERY')] [string] $Kind
    )
    $map = @{
        OK       = @{ Id = 1000; Type = [System.Diagnostics.EventLogEntryType]::Information }
        WARNING  = @{ Id = 1001; Type = [System.Diagnostics.EventLogEntryType]::Warning }
        ALERT    = @{ Id = 1002; Type = [System.Diagnostics.EventLogEntryType]::Error }
        ERROR    = @{ Id = 1003; Type = [System.Diagnostics.EventLogEntryType]::Error }
        DELIVERY = @{ Id = 1004; Type = [System.Diagnostics.EventLogEntryType]::Warning }
    }
    try {
        if ([System.Diagnostics.EventLog]::SourceExists($script:EventSource)) {
            [System.Diagnostics.EventLog]::WriteEntry($script:EventSource, $Message, $map[$Kind].Type, $map[$Kind].Id)
        }
    }
    catch {
        Write-WULog -Level DEBUG -Message "Event log not written: $($_.Exception.Message)"
    }
}

#endregion

#region Orchestration

function Invoke-WUTargetCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [datetime] $Now
    )

    $localNames = @('localhost', '.', '127.0.0.1', '::1', $env:COMPUTERNAME)
    $collectArgs = @{
        QualityUpdatePattern = [string]$Config.History.QualityUpdatePattern
        ExcludePattern       = [string]$Config.History.ExcludePattern
        FailureLookbackDays  = [int]$Config.Thresholds.FailureLookbackDays
    }
    try {
        if ($localNames -contains $Target) {
            $raw = Get-WURawState @collectArgs
            $name = $env:COMPUTERNAME
        }
        else {
            $scriptBlock = (Get-Command -Name Get-WURawState).ScriptBlock
            $raw = Invoke-Command -ComputerName $Target -ScriptBlock $scriptBlock -ErrorAction Stop -ArgumentList @(
                $collectArgs.QualityUpdatePattern, $collectArgs.ExcludePattern, $collectArgs.FailureLookbackDays)
            $name = [string]$raw.ComputerName
        }
        foreach ($collectorError in @($raw.CollectorErrors | Where-Object { $_ })) {
            Write-WULog -Level WARN -Message "[$name] Collector: $collectorError"
        }
        $checks = Get-WUCheckResult -RawState $raw -Config $Config -Now $Now
        return New-WUReport -ComputerName $name -Checks $checks -RawState $raw -Now $Now
    }
    catch {
        Write-WULog -Level ERROR -Message "[$Target] Data collection failed: $($_.Exception.Message)"
        $check = New-WUCheck -Name 'Connectivity' -Status WARNING -Message "Could not collect data: $($_.Exception.Message)"
        return New-WUReport -ComputerName $Target -Checks @($check) -Now $Now
    }
}

function Invoke-WUMonitorRun {
    <#
    .SYNOPSIS
        Runs the full monitoring cycle: logging, outbox retry, collection, evaluation, delivery.
    .OUTPUTS
        One object per computer: Report, Payload, Delivery (Sent | Queued | Skipped | NotConfigured | DryRun).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [string[]] $ComputerName,
        [switch] $DryRun,
        [datetime] $Now = (Get-Date)
    )

    $null = Initialize-WULog -Path $Config.Logging.Path
    Write-WULog -Message ('WUMonitor {0} started on {1} as {2}\{3} (PowerShell {4}, dry run: {5})' -f $script:WUMonitorVersion, $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME, $PSVersionTable.PSVersion, [bool]$DryRun)
    Remove-WUOldLog -RetentionDays ([int]$Config.Logging.RetentionDays)

    $url = [string]$Config.Webhook.Url
    $format = [string]$Config.Webhook.Format
    if (-not $url) {
        Write-WULog -Level WARN -Message 'No webhook URL configured (config Webhook.Url or WUMONITOR_WEBHOOK_URL); results are logged only'
    }
    elseif ($url -notmatch '^https://') {
        Write-WULog -Level WARN -Message 'Webhook URL is not HTTPS; use HTTPS outside of local testing'
    }
    if ($url -and -not $DryRun) { Send-WUOutbox -Config $Config }

    $targets = @($ComputerName | Where-Object { $_ })
    if ($targets.Count -eq 0) { $targets = @($Config.Computers | Where-Object { $_ }) }
    if ($targets.Count -eq 0) { $targets = @($env:COMPUTERNAME) }

    foreach ($target in $targets) {
        $report = Invoke-WUTargetCheck -Target $target -Config $Config -Now $Now
        foreach ($check in $report.Checks) {
            Write-WULog -Message ('[{0}] {1,-7} {2}: {3}' -f $report.ComputerName, $check.Status, $check.Name, $check.Message)
        }
        Write-WULog -Message ('[{0}] Overall status {1} ({2})' -f $report.ComputerName, $report.Status, $report.Summary)

        $payload = ConvertTo-WUWebhookPayload -Report $report -Format $format
        $delivery = 'NotConfigured'
        if ($DryRun) {
            $delivery = 'DryRun'
            Write-WULog -Message "[$($report.ComputerName)] Dry run: webhook not sent"
        }
        elseif ($url) {
            if (-not (Test-WUShouldSend -Status $report.Status -SendOn $Config.Webhook.SendOn)) {
                $delivery = 'Skipped'
                Write-WULog -Message "[$($report.ComputerName)] Webhook skipped (SendOn=$($Config.Webhook.SendOn), status $($report.Status))"
            }
            elseif (Send-WUWebhook -Url $url -Body $payload -TimeoutSeconds ([int]$Config.Webhook.TimeoutSeconds) -RetryCount ([int]$Config.Webhook.RetryCount)) {
                $delivery = 'Sent'
            }
            else {
                $delivery = 'Queued'
                try { $null = Save-WUOutboxItem -Path $Config.Outbox.Path -ComputerName $report.ComputerName -Body $payload }
                catch { Write-WULog -Level ERROR -Message "Could not save report to outbox: $($_.Exception.Message)" }
                Write-WUEventLog -Kind DELIVERY -Message "WUMonitor could not deliver the report for $($report.ComputerName) to the webhook; it was queued for the next run."
            }
        }

        if ($Config.Logging.EventLog) {
            $eventText = "Windows Update status for $($report.ComputerName): $($report.Status) ($($report.Summary))`r`n`r`n" +
            (($report.Checks | ForEach-Object { '[{0}] {1}: {2}' -f $_.Status, $_.Name, $_.Message }) -join "`r`n")
            Write-WUEventLog -Kind $report.Status -Message $eventText
        }

        [pscustomobject][ordered]@{ Report = $report; Payload = $payload; Delivery = $delivery }
    }
    Write-WULog -Message 'WUMonitor finished'
}

function Send-WUFailureNotice {
    <#
    .SYNOPSIS
        Best-effort ALERT when the monitor itself fails (bad config, unexpected exception).
        Uses the loaded config when available, otherwise defaults plus WUMONITOR_WEBHOOK_URL.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $ErrorMessage
    )
    try {
        if ($null -eq $Config) {
            $Config = Get-WUDefaultConfig
            if ($env:WUMONITOR_WEBHOOK_URL) { $Config.Webhook.Url = $env:WUMONITOR_WEBHOOK_URL }
        }
        if (-not $script:LogFile) { $null = Initialize-WULog -Path $Config.Logging.Path }
        Write-WULog -Level ERROR -Message "Monitor failure: $ErrorMessage"
        Write-WUEventLog -Kind ERROR -Message "WUMonitor failed: $ErrorMessage"

        $url = [string]$Config.Webhook.Url
        if (-not $url) { return $false }
        $format = [string]$Config.Webhook.Format
        if (@('generic', 'teams', 'slack', 'discord') -notcontains $format) { $format = 'generic' }
        $check = New-WUCheck -Name 'Monitor' -Status ALERT -Message "WUMonitor failed to run: $ErrorMessage"
        $report = New-WUReport -ComputerName $env:COMPUTERNAME -Checks @($check)
        return Send-WUWebhook -Url $url -Body (ConvertTo-WUWebhookPayload -Report $report -Format $format) -TimeoutSeconds 15 -RetryCount 1
    }
    catch {
        Write-Warning "Could not send failure notice: $($_.Exception.Message)"
        return $false
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-WUDefaultConfig'
    'Get-WUMonitorConfig'
    'Get-WURawState'
    'Get-WUCheckResult'
    'New-WUReport'
    'ConvertTo-WUWebhookPayload'
    'Send-WUWebhook'
    'Send-WUOutbox'
    'Invoke-WUMonitorRun'
    'Get-WUExitCode'
    'Send-WUFailureNotice'
    'Initialize-WULog'
    'Write-WULog'
)
