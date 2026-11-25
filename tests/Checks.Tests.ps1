#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Unit tests for every evaluation rule (pure functions, no system access).

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src/WUMonitor/WUMonitor.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $Defaults = Get-WUDefaultConfig
    $Thresholds = $Defaults.Thresholds
}

Describe 'Test-WUServiceState' {
    It 'is OK when all update services are enabled' {
        $services = (New-TestRawState).Services
        (Invoke-WUInternal Test-WUServiceState @{ Services = $services }).Status | Should -Be 'OK'
    }
    It 'is ALERT when <Name> is Disabled' -ForEach @(
        @{ Name = 'wuauserv' }
        @{ Name = 'UsoSvc' }
    ) {
        $services = @(
            New-TestService -Name 'wuauserv' -StartType $(if ($Name -eq 'wuauserv') { 'Disabled' } else { 'Manual' })
            New-TestService -Name 'UsoSvc' -StartType $(if ($Name -eq 'UsoSvc') { 'Disabled' } else { 'Automatic' })
            New-TestService -Name 'WaaSMedicSvc'
        )
        $check = Invoke-WUInternal Test-WUServiceState @{ Services = $services }
        $check.Status | Should -Be 'ALERT'
        $check.Message | Should -Match $Name
    }
    It 'is WARNING when only WaaSMedicSvc is Disabled' {
        $services = @((New-TestService 'wuauserv'), (New-TestService 'UsoSvc' 'Automatic'), (New-TestService 'WaaSMedicSvc' 'Disabled'))
        (Invoke-WUInternal Test-WUServiceState @{ Services = $services }).Status | Should -Be 'WARNING'
    }
    It 'is ALERT when the wuauserv service is missing' {
        $services = @((New-TestService 'wuauserv' -Exists $false), (New-TestService 'UsoSvc' 'Automatic'))
        (Invoke-WUInternal Test-WUServiceState @{ Services = $services }).Status | Should -Be 'ALERT'
    }
    It 'is WARNING when service data could not be collected' {
        (Invoke-WUInternal Test-WUServiceState @{ Services = $null }).Status | Should -Be 'WARNING'
    }
}

Describe 'Test-WUAutoUpdatePolicy' {
    It 'returns <Expected> for <Case>' -ForEach @(
        @{ Case = 'no policy'; Policy = @{}; Expected = 'OK' }
        @{ Case = 'NoAutoUpdate=1'; Policy = @{ NoAutoUpdate = 1; AUOptions = 4 }; Expected = 'ALERT' }
        @{ Case = 'NoAutoUpdate=0'; Policy = @{ NoAutoUpdate = 0 }; Expected = 'OK' }
        @{ Case = 'AUOptions=2'; Policy = @{ AUOptions = 2 }; Expected = 'WARNING' }
        @{ Case = 'AUOptions=3'; Policy = @{ AUOptions = 3 }; Expected = 'WARNING' }
        @{ Case = 'AUOptions=4'; Policy = @{ AUOptions = 4 }; Expected = 'OK' }
        @{ Case = 'AUOptions=5'; Policy = @{ AUOptions = 5 }; Expected = 'WARNING' }
        @{ Case = 'AUOptions=7'; Policy = @{ AUOptions = 7 }; Expected = 'WARNING' }
        @{ Case = 'AUOptions=9 (unknown)'; Policy = @{ AUOptions = 9 }; Expected = 'WARNING' }
    ) {
        (Invoke-WUInternal Test-WUAutoUpdatePolicy @{ Policy = [pscustomobject]$Policy }).Status | Should -Be $Expected
    }
    It 'does not treat a missing AUOptions value as 0 (regression: $null -as [int] is 0)' {
        $policy = [pscustomobject]@{ AUOptions = $null; NoAutoUpdate = $null }
        $check = Invoke-WUInternal Test-WUAutoUpdatePolicy @{ Policy = $policy }
        $check.Status | Should -Be 'OK'
        $check.Message | Should -Not -Match 'Unrecognised'
    }
    It 'is WARNING when the policy could not be read' {
        (Invoke-WUInternal Test-WUAutoUpdatePolicy @{ Policy = $null }).Status | Should -Be 'WARNING'
    }
}

Describe 'Test-WUPauseState' {
    BeforeAll {
        function Get-PauseCheck($Pause, $Policy = [pscustomobject]@{}) {
            Invoke-WUInternal Test-WUPauseState @{ Pause = $Pause; Policy = $Policy; Thresholds = $Thresholds; Now = $TestNow }
        }
    }
    It 'is OK when no pause is configured' {
        (Get-PauseCheck ([pscustomobject]@{})).Status | Should -Be 'OK'
    }
    It 'is OK when an old pause has expired' {
        $pause = [pscustomobject]@{ PauseUpdatesExpiryTime = '2026-05-15T12:26:40Z'; PauseQualityUpdatesEndTime = '2026-05-15T12:26:40Z' }
        (Get-PauseCheck $pause).Message | Should -Be 'Updates are not paused'
    }
    It 'is WARNING for a short pause (3 days left)' {
        $pause = [pscustomobject]@{ PauseUpdatesExpiryTime = $TestNow.AddDays(3).ToString('yyyy-MM-ddTHH:mm:ssZ') }
        $check = Get-PauseCheck $pause
        $check.Status | Should -Be 'WARNING'
        $check.Message | Should -Match '3 days remaining'
    }
    It 'is ALERT for a long pause (20 days left)' {
        $pause = [pscustomobject]@{ PauseQualityUpdatesEndTime = $TestNow.AddDays(20).ToString('yyyy-MM-ddTHH:mm:ssZ') }
        (Get-PauseCheck $pause).Status | Should -Be 'ALERT'
    }
    It 'detects a Group Policy pause (35 days from the start date)' {
        $policy = [pscustomobject]@{ PauseQualityUpdatesStartTime = $TestNow.AddDays(-10).ToString('yyyy-MM-dd') }
        $check = Get-PauseCheck ([pscustomobject]@{}) $policy
        $check.Status | Should -Be 'ALERT'
        $check.Message | Should -Match '2026-12-2'
    }
    It 'is OK but mentions a feature-update-only pause' {
        $pause = [pscustomobject]@{ PauseFeatureUpdatesEndTime = $TestNow.AddDays(30).ToString('yyyy-MM-ddTHH:mm:ssZ') }
        $check = Get-PauseCheck $pause
        $check.Status | Should -Be 'OK'
        $check.Message | Should -Match 'feature updates paused'
    }
    It 'ignores unparseable dates' {
        (Get-PauseCheck ([pscustomobject]@{ PauseUpdatesExpiryTime = 'not-a-date' })).Status | Should -Be 'OK'
    }
}

Describe 'Test-WUDeferralPolicy' {
    It 'returns <Expected> for <Case>' -ForEach @(
        @{ Case = 'no deferral'; Policy = @{}; Expected = 'OK' }
        @{ Case = 'quality 5 days'; Policy = @{ DeferQualityUpdates = 1; DeferQualityUpdatesPeriodInDays = 5 }; Expected = 'OK' }
        @{ Case = 'quality 14 days (boundary)'; Policy = @{ DeferQualityUpdates = 1; DeferQualityUpdatesPeriodInDays = 14 }; Expected = 'WARNING' }
        @{ Case = 'quality 15 days'; Policy = @{ DeferQualityUpdatesPeriodInDays = 15 }; Expected = 'ALERT' }
        @{ Case = 'quality 30 days (Windows maximum)'; Policy = @{ DeferQualityUpdatesPeriodInDays = 30 }; Expected = 'ALERT' }
        @{ Case = 'quality deferral switched off'; Policy = @{ DeferQualityUpdates = 0; DeferQualityUpdatesPeriodInDays = 30 }; Expected = 'OK' }
        @{ Case = 'feature 180 days'; Policy = @{ DeferFeatureUpdatesPeriodInDays = 180 }; Expected = 'OK' }
        @{ Case = 'feature 365 days'; Policy = @{ DeferFeatureUpdatesPeriodInDays = 365 }; Expected = 'WARNING' }
    ) {
        (Invoke-WUInternal Test-WUDeferralPolicy @{ Policy = [pscustomobject]$Policy; Thresholds = $Thresholds }).Status | Should -Be $Expected
    }
    It 'reports a target release version pin' {
        $policy = [pscustomobject]@{ TargetReleaseVersion = 1; ProductVersion = 'Windows 11'; TargetReleaseVersionInfo = '24H2' }
        (Invoke-WUInternal Test-WUDeferralPolicy @{ Policy = $policy; Thresholds = $Thresholds }).Message | Should -Match 'pinned to Windows 11 24H2'
    }
}

Describe 'Test-WUUpdateSource' {
    It 'is OK for the Microsoft online service' {
        (Invoke-WUInternal Test-WUUpdateSource @{ Policy = [pscustomobject]@{}; AllowedWsusServers = @() }).Status | Should -Be 'OK'
    }
    It 'is OK for an approved WSUS server (allow-list given as <Form>)' -ForEach @(
        @{ Form = 'URL'; Allowed = 'http://wsus.corp.local:8530' }
        @{ Form = 'host name'; Allowed = 'WSUS.corp.local' }
    ) {
        $policy = [pscustomobject]@{ UseWUServer = 1; WUServer = 'http://wsus.corp.local:8530' }
        (Invoke-WUInternal Test-WUUpdateSource @{ Policy = $policy; AllowedWsusServers = @($Allowed) }).Status | Should -Be 'OK'
    }
    It 'is WARNING for a WSUS server that is not approved' {
        $policy = [pscustomobject]@{ UseWUServer = 1; WUServer = 'http://rogue:8530' }
        (Invoke-WUInternal Test-WUUpdateSource @{ Policy = $policy; AllowedWsusServers = @('wsus.corp.local') }).Status | Should -Be 'WARNING'
    }
    It 'is ALERT when UseWUServer=1 but no server is set' {
        (Invoke-WUInternal Test-WUUpdateSource @{ Policy = [pscustomobject]@{ UseWUServer = 1 }; AllowedWsusServers = @() }).Status | Should -Be 'ALERT'
    }
    It 'is ALERT when internet locations are blocked and there is no WSUS' {
        $policy = [pscustomobject]@{ DoNotConnectToWindowsUpdateInternetLocations = 1 }
        (Invoke-WUInternal Test-WUUpdateSource @{ Policy = $policy; AllowedWsusServers = @() }).Status | Should -Be 'ALERT'
    }
}

Describe 'Test-WULastQualityUpdate' {
    It 'returns <Expected> when the last update was <Days> days ago' -ForEach @(
        @{ Days = 10; Expected = 'OK' }
        @{ Days = 35; Expected = 'OK' }
        @{ Days = 36; Expected = 'WARNING' }
        @{ Days = 60; Expected = 'WARNING' }
        @{ Days = 61; Expected = 'ALERT' }
    ) {
        $history = [pscustomobject]@{ Source = 'WindowsUpdateAgent'; LastQualityUpdate = (New-TestUpdate -Date $TestNow.AddDays(-$Days)) }
        $check = Invoke-WUInternal Test-WULastQualityUpdate @{ History = $history; Thresholds = $Thresholds; Now = $TestNow }
        $check.Status | Should -Be $Expected
        $check.Message | Should -Match "^$Days days ago"
    }
    It 'is WARNING when no quality update exists in history' {
        $history = [pscustomobject]@{ Source = 'WindowsUpdateAgent'; LastQualityUpdate = $null }
        (Invoke-WUInternal Test-WULastQualityUpdate @{ History = $history; Thresholds = $Thresholds; Now = $TestNow }).Status | Should -Be 'WARNING'
    }
    It 'is WARNING when history could not be read' {
        (Invoke-WUInternal Test-WULastQualityUpdate @{ History = $null; Thresholds = $Thresholds; Now = $TestNow }).Status | Should -Be 'WARNING'
    }
    It 'marks Get-HotFix data as approximate' {
        $history = [pscustomobject]@{ Source = 'Get-HotFix'; LastQualityUpdate = (New-TestUpdate -Title 'KB5000001 (Update)' -Date $TestNow.AddDays(-3)) }
        (Invoke-WUInternal Test-WULastQualityUpdate @{ History = $history; Thresholds = $Thresholds; Now = $TestNow }).Message | Should -Match 'approximate'
    }
}

Describe 'Test-WURecentFailure' {
    It 'returns <Expected> with <Count> unresolved failure(s)' -ForEach @(
        @{ Count = 0; Expected = 'OK' }
        @{ Count = 1; Expected = 'WARNING' }
        @{ Count = 2; Expected = 'WARNING' }
        @{ Count = 3; Expected = 'ALERT' }
        @{ Count = 5; Expected = 'ALERT' }
    ) {
        $failures = @(for ($i = 1; $i -le $Count; $i++) { New-TestUpdate -Title "Update (KB500000$i)" -Date $TestNow.AddDays(-$i) -ResultCode 4 -HResult '0x80070643' })
        $history = [pscustomobject]@{ Source = 'WindowsUpdateAgent'; Failures = $failures }
        $check = Invoke-WUInternal Test-WURecentFailure @{ History = $history; Thresholds = $Thresholds }
        $check.Status | Should -Be $Expected
        if ($Count -gt 0) { $check.Message | Should -Match 'KB5000001 \(0x80070643\)' }
        if ($Count -gt 3) { $check.Message | Should -Match '\+2 more' }
    }
    It 'is WARNING when failure history is unavailable (Get-HotFix fallback)' {
        $history = [pscustomobject]@{ Source = 'Get-HotFix'; Failures = @() }
        (Invoke-WUInternal Test-WURecentFailure @{ History = $history; Thresholds = $Thresholds }).Status | Should -Be 'WARNING'
    }
}

Describe 'Test-WUPendingReboot' {
    BeforeAll {
        function Get-RebootCheck($Reboot, $UptimeDays) {
            $os = $null
            if ($null -ne $UptimeDays) { $os = [pscustomobject]@{ LastBootUpTime = $TestNow.AddDays(-$UptimeDays) } }
            Invoke-WUInternal Test-WUPendingReboot @{ Reboot = $Reboot; Os = $os; Thresholds = $Thresholds; Now = $TestNow }
        }
    }
    It 'is OK when no reboot is pending' {
        (Get-RebootCheck ([pscustomobject]@{ WindowsUpdate = $false; ComponentBasedService = $false }) 30).Status | Should -Be 'OK'
    }
    It 'is WARNING for a recent pending reboot' {
        $check = Get-RebootCheck ([pscustomobject]@{ WindowsUpdate = $true; ComponentBasedService = $false }) 2
        $check.Status | Should -Be 'WARNING'
        $check.Message | Should -Match 'Windows Update'
    }
    It 'is ALERT when the reboot has been pending for 7+ days of uptime' {
        (Get-RebootCheck ([pscustomobject]@{ WindowsUpdate = $false; ComponentBasedService = $true }) 7).Status | Should -Be 'ALERT'
    }
    It 'is WARNING when uptime is unknown' {
        (Get-RebootCheck ([pscustomobject]@{ WindowsUpdate = $true }) $null).Message | Should -Match 'uptime unknown'
    }
}

Describe 'Test-WUOsSupport' {
    BeforeAll {
        function Get-OsCheck([int]$Build, [string]$Edition = 'Professional', [int]$ProductType = 1, $Lifecycle = $Defaults.OsLifecycle) {
            $os = [pscustomobject]@{ Caption = 'Test Windows'; DisplayVersion = 'X'; Build = $Build; UBR = 1; EditionID = $Edition; ProductType = $ProductType }
            Invoke-WUInternal Test-WUOsSupport @{ Os = $os; Lifecycle = @($Lifecycle); UnknownBuildStatus = 'WARNING'; Thresholds = $Thresholds; Now = $TestNow }
        }
    }
    It 'returns <Expected> for build <Build> <Edition> (<Note>)' -ForEach @(
        @{ Build = 26200; Edition = 'Professional'; ProductType = 1; Expected = 'OK'; Note = '25H2 Pro supported to 2027' }
        @{ Build = 26100; Edition = 'Professional'; ProductType = 1; Expected = 'ALERT'; Note = '24H2 Pro ended 2026-10-13' }
        @{ Build = 26100; Edition = 'Enterprise'; ProductType = 1; Expected = 'OK'; Note = '24H2 Enterprise supported to 2027' }
        @{ Build = 19045; Edition = 'Professional'; ProductType = 1; Expected = 'ALERT'; Note = 'Windows 10 ended 2025-10-14' }
        @{ Build = 19044; Edition = 'EnterpriseS'; ProductType = 1; Expected = 'WARNING'; Note = 'LTSC 2021 ends in 48 days' }
        @{ Build = 20348; Edition = 'ServerStandard'; ProductType = 3; Expected = 'OK'; Note = 'Server 2022' }
        @{ Build = 99999; Edition = 'Professional'; ProductType = 1; Expected = 'WARNING'; Note = 'unknown build' }
    ) {
        (Get-OsCheck -Build $Build -Edition $Edition -ProductType $ProductType).Status | Should -Be $Expected
    }
    It 'uses the configured status for unknown builds' {
        $os = [pscustomobject]@{ Build = 99999; EditionID = 'Professional'; ProductType = 1 }
        (Invoke-WUInternal Test-WUOsSupport @{ Os = $os; Lifecycle = @($Defaults.OsLifecycle); UnknownBuildStatus = 'OK'; Thresholds = $Thresholds; Now = $TestNow }).Status | Should -Be 'OK'
    }
    It 'is WARNING when the lifecycle entry has no date for the channel' {
        (Get-OsCheck -Build 19045 -Edition 'ServerStandard' -ProductType 3).Message | Should -Match "no 'Server' end-of-servicing date"
    }
}

Describe 'Get-WUCheckResult' {
    It 'runs all nine checks and a healthy machine is OK everywhere' {
        $checks = Get-WUCheckResult -RawState (New-TestRawState) -Config $Defaults -Now $TestNow
        $checks.Count | Should -Be 9
        $checks.Name | Should -Be @('ServiceState', 'AutoUpdatePolicy', 'PauseState', 'DeferralPolicy', 'UpdateSource', 'LastQualityUpdate', 'RecentFailures', 'PendingReboot', 'OsSupport')
        $checks | Where-Object Status -ne 'OK' | ForEach-Object { "$($_.Name): $($_.Message)" } | Should -BeNullOrEmpty
    }
    It 'turns sections that failed to collect into WARNING instead of crashing' {
        $raw = New-TestRawState
        $raw.Policy = $null; $raw.History = $null; $raw.Os = $null
        $checks = Get-WUCheckResult -RawState $raw -Config $Defaults -Now $TestNow
        $checks.Count | Should -Be 9
        ($checks | Where-Object Status -eq 'WARNING').Count | Should -BeGreaterOrEqual 5
    }
    It 'works with a hashtable-based config loaded from JSON (deserialized lifecycle)' {
        $json = Get-WUDefaultConfig | ConvertTo-Json -Depth 10
        $roundTrip = & (Get-Module WUMonitor) { param($j) ConvertTo-WUHashtable -InputObject ($j | ConvertFrom-Json) } $json
        $checks = Get-WUCheckResult -RawState (New-TestRawState) -Config $roundTrip -Now $TestNow
        ($checks | Where-Object Name -eq 'OsSupport').Status | Should -Be 'OK'
    }
}
