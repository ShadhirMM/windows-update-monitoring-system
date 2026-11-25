#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Update-history logic in Get-WURawState, with the Windows Update Agent COM API mocked.
# The registry/service reads in this function are read-only and run against the real machine.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src/WUMonitor/WUMonitor.psd1') -Force

    function New-HistoryEntry([string] $Title, [int] $DaysAgo, [int] $ResultCode = 2, [int] $Operation = 1, [int] $HResult = 0) {
        [pscustomobject]@{ Title = $Title; Date = (Get-Date).AddDays(-$DaysAgo); ResultCode = $ResultCode; Operation = $Operation; HResult = $HResult }
    }
    function New-FakeUpdateSession([object[]] $Entries) {
        $searcher = [pscustomobject]@{ Entries = $Entries }
        $searcher | Add-Member -MemberType ScriptMethod -Name GetTotalHistoryCount -Value { @($this.Entries).Count }
        $searcher | Add-Member -MemberType ScriptMethod -Name QueryHistory -Value { param($start, $count) $this.Entries }
        $session = [pscustomobject]@{ Searcher = $searcher }
        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { $this.Searcher } -PassThru
    }
}

Describe 'Get-WURawState update history' {
    It 'picks the newest successful quality update regardless of order and skips excluded titles' {
        $entries = @(
            New-HistoryEntry '2026-09 Security Update (KB5000009)' 60
            New-HistoryEntry 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602' 0
            New-HistoryEntry '2026-11 .NET Framework Security Update (KB5000011)' 1
            New-HistoryEntry '2026-11 Security Update (KB5000010)' 5
            New-HistoryEntry '9NRZT3Q9R3DL-Microsoft.WindowsAppRuntime.2' 2
        )
        $session = New-FakeUpdateSession $entries
        Mock -ModuleName WUMonitor New-Object { $session } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }

        $history = (Get-WURawState).History
        $history.Source | Should -Be 'WindowsUpdateAgent'
        $history.LastQualityUpdate.KB | Should -Be 'KB5000010'
        $history.LastAnyUpdate.Title | Should -Be '9NRZT3Q9R3DL-Microsoft.WindowsAppRuntime.2'
        $history.EntriesScanned | Should -Be 3
    }
    It 'counts only unresolved failures inside the lookback window, once per KB' {
        $entries = @(
            New-HistoryEntry 'Update A (KB5000001)' 3 -ResultCode 4 -HResult 0x80070643   # unresolved
            New-HistoryEntry 'Update A (KB5000001)' 4 -ResultCode 4 -HResult 0x80070643   # same KB again
            New-HistoryEntry 'Update B (KB5000002)' 2 -ResultCode 2                        # B succeeded later...
            New-HistoryEntry 'Update B (KB5000002)' 6 -ResultCode 4                        # ...so this failure is resolved
            New-HistoryEntry 'Update C (KB5000003)' 45 -ResultCode 4                       # outside 30-day window
            New-HistoryEntry 'Update D (KB5000004)' 1 -ResultCode 5                        # aborted counts as failure
            New-HistoryEntry 'Update E (KB5000005)' 1 -ResultCode 4 -Operation 2           # uninstall, ignored
        )
        $session = New-FakeUpdateSession $entries
        Mock -ModuleName WUMonitor New-Object { $session } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }

        $failures = @((Get-WURawState -FailureLookbackDays 30).History.Failures)
        $failures.KB | Sort-Object | Should -Be @('KB5000001', 'KB5000004')
        ($failures | Where-Object KB -eq 'KB5000001').HResult | Should -Be '0x80070643'
    }
    It 'handles an empty update history' {
        $session = New-FakeUpdateSession @()
        Mock -ModuleName WUMonitor New-Object { $session } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }
        $history = (Get-WURawState).History
        $history.LastQualityUpdate | Should -BeNullOrEmpty
        @($history.Failures).Count | Should -Be 0
    }
    It 'falls back to Get-HotFix when the Windows Update Agent cannot be queried' {
        Mock -ModuleName WUMonitor New-Object { throw 'Access is denied. (0x80070005)' } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }
        Mock -ModuleName WUMonitor Get-HotFix {
            [pscustomobject]@{ HotFixID = 'KB5000020'; Description = 'Security Update'; InstalledOn = (Get-Date).AddDays(-3) }
            [pscustomobject]@{ HotFixID = 'KB5000019'; Description = 'Update'; InstalledOn = (Get-Date).AddDays(-30) }
            [pscustomobject]@{ HotFixID = 'KB5000018'; Description = 'Update'; InstalledOn = $null }
        }
        $raw = Get-WURawState
        $raw.History.Source | Should -Be 'Get-HotFix'
        $raw.History.LastQualityUpdate.KB | Should -Be 'KB5000020'
        $raw.CollectorErrors | Should -Match 'Access is denied'
    }
    It 'returns $null history and two collector errors when both sources fail' {
        Mock -ModuleName WUMonitor New-Object { throw 'COM failure' } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }
        Mock -ModuleName WUMonitor Get-HotFix { throw 'WMI failure' }
        $raw = Get-WURawState
        $raw.History | Should -BeNullOrEmpty
        @($raw.CollectorErrors | Where-Object { $_ -like 'UpdateHistory*' }).Count | Should -Be 2
    }
}

Describe 'Get-WURawState is portable to remote sessions' {
    It 'does not call any other WUMonitor function (it is shipped as a standalone script block)' {
        # All module-level functions, including private ones.
        $moduleFunctions = @(& (Get-Module WUMonitor) { Get-ChildItem function: | Where-Object ModuleName -eq 'WUMonitor' | ForEach-Object Name })
        $moduleFunctions | Should -Contain 'Get-WUProp'
        $ast = (Get-Command Get-WURawState).ScriptBlock.Ast
        $called = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }
        $called | Where-Object { $moduleFunctions -contains $_ -and $_ -ne 'Get-WURawState' } | Should -BeNullOrEmpty
    }
}
