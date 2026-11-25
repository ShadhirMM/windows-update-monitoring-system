#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src/WUMonitor/WUMonitor.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $ManifestVersion = (Import-PowerShellDataFile (Join-Path $repoRoot 'src/WUMonitor/WUMonitor.psd1')).ModuleVersion

    function New-Check([string] $Name, [string] $Status) {
        [pscustomobject]@{ Name = $Name; Status = $Status; Message = "$Name is $Status" }
    }
    function New-SampleReport([string[]] $Statuses = @('OK', 'WARNING', 'ALERT')) {
        $i = 0
        $checks = @($Statuses | ForEach-Object { $i++; New-Check "Check$i" $_ })
        New-WUReport -ComputerName 'TESTPC' -Checks $checks -RawState (New-TestRawState) -Now $TestNow
    }
}

Describe 'New-WUReport' {
    It 'takes the worst check status as the overall status (<Expected>)' -ForEach @(
        @{ Statuses = @('OK', 'OK'); Expected = 'OK' }
        @{ Statuses = @('OK', 'WARNING'); Expected = 'WARNING' }
        @{ Statuses = @('WARNING', 'ALERT', 'OK'); Expected = 'ALERT' }
    ) {
        (New-SampleReport $Statuses).Status | Should -Be $Expected
    }
    It 'fills the summary, timestamp, OS and version' {
        $report = New-SampleReport @('OK', 'WARNING', 'WARNING', 'ALERT')
        $report.Summary | Should -Be '1 ALERT, 2 WARNING, 1 OK'
        $report.TimestampUtc | Should -Be '2026-11-25T12:00:00Z'
        $report.OperatingSystem | Should -Be 'Microsoft Windows 11 Pro 25H2 (build 26200.7171)'
        $report.MonitorVersion | Should -Be $ManifestVersion
    }
    It 'works without raw state (unreachable computer)' {
        $report = New-WUReport -ComputerName 'OFFLINE01' -Checks @(New-Check 'Connectivity' 'WARNING') -Now $TestNow
        $report.OperatingSystem | Should -Be 'unknown'
        $report.Status | Should -Be 'WARNING'
    }
}

Describe 'Get-WUExitCode' {
    It 'returns <Expected> for <Case>' -ForEach @(
        @{ Case = 'all OK'; Statuses = @('OK', 'OK'); Expected = 0 }
        @{ Case = 'a WARNING'; Statuses = @('OK', 'WARNING'); Expected = 1 }
        @{ Case = 'an ALERT'; Statuses = @('WARNING', 'ALERT'); Expected = 2 }
    ) {
        $reports = @($Statuses | ForEach-Object { [pscustomobject]@{ Status = $_ } })
        Get-WUExitCode -Report $reports | Should -Be $Expected
    }
}

Describe 'ConvertTo-WUWebhookPayload' {
    BeforeAll { $Report = New-SampleReport @('OK', 'WARNING', 'ALERT') }

    It 'produces valid JSON for the <Format> format' -ForEach @(
        @{ Format = 'generic' }, @{ Format = 'teams' }, @{ Format = 'slack' }, @{ Format = 'discord' }
    ) {
        $json = ConvertTo-WUWebhookPayload -Report $Report -Format $Format
        { $json | ConvertFrom-Json } | Should -Not -Throw
        $json | Should -Match 'TESTPC'
    }
    It 'generic: contains every check and the overall status' {
        $body = ConvertTo-WUWebhookPayload -Report $Report -Format generic | ConvertFrom-Json
        $body.source | Should -Be 'WUMonitor'
        $body.status | Should -Be 'ALERT'
        @($body.checks).Count | Should -Be 3
        $body.checks[2].status | Should -Be 'ALERT'
    }
    It 'generic: a single check is still serialized as a JSON array (Windows PowerShell 5.1 pitfall)' {
        $single = New-SampleReport @('OK')
        $json = ConvertTo-WUWebhookPayload -Report $single -Format generic
        $json | Should -Match '"checks":\[\{'
        $json | Should -Not -Match '"value":'
    }
    It 'discord: uses a red embed for ALERT and one field per check' {
        $body = ConvertTo-WUWebhookPayload -Report $Report -Format discord | ConvertFrom-Json
        $body.embeds[0].color | Should -Be 15158332
        @($body.embeds[0].fields).Count | Should -Be 3
    }
    It 'slack: has fallback text and blocks' {
        $body = ConvertTo-WUWebhookPayload -Report $Report -Format slack | ConvertFrom-Json
        $body.text | Should -Match 'Windows Update ALERT'
        $body.blocks[0].type | Should -Be 'header'
    }
    It 'teams: wraps an Adaptive Card for Teams Workflows' {
        $body = ConvertTo-WUWebhookPayload -Report $Report -Format teams | ConvertFrom-Json
        $body.type | Should -Be 'message'
        $body.attachments[0].contentType | Should -Be 'application/vnd.microsoft.card.adaptive'
        $body.attachments[0].content.type | Should -Be 'AdaptiveCard'
        @($body.attachments[0].content.body[3].facts).Count | Should -Be 3
    }
    It 'survives special characters in messages' {
        $checks = @([pscustomobject]@{ Name = 'Test'; Status = 'OK'; Message = 'Quotes " backslash \ newline' + "`n" + 'tab' + "`t" + 'unicode ' + [char]0x00E9 })
        $report = New-WUReport -ComputerName 'TESTPC' -Checks $checks -Now $TestNow
        $body = ConvertTo-WUWebhookPayload -Report $report -Format generic | ConvertFrom-Json
        $body.checks[0].message | Should -Be $checks[0].Message
    }
}

Describe 'Test-WUShouldSend' {
    It 'SendOn=<SendOn>, status <Status> -> <Expected>' -ForEach @(
        @{ SendOn = 'Always'; Status = 'OK'; Expected = $true }
        @{ SendOn = 'WarningOrAbove'; Status = 'OK'; Expected = $false }
        @{ SendOn = 'WarningOrAbove'; Status = 'WARNING'; Expected = $true }
        @{ SendOn = 'AlertOnly'; Status = 'WARNING'; Expected = $false }
        @{ SendOn = 'AlertOnly'; Status = 'ALERT'; Expected = $true }
    ) {
        Invoke-WUInternal Test-WUShouldSend @{ Status = $Status; SendOn = $SendOn } | Should -Be $Expected
    }
}
