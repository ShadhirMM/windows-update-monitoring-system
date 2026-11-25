#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Static proof of the "read-only" promise: parses every file in src/ and fails if any code could
# change Windows settings, services, the registry, scheduled tasks or install updates.
# File writes are allowed only in the functions that own the monitor's log and outbox files.

BeforeDiscovery {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $SourceFiles = @(Get-ChildItem -Path (Join-Path $repoRoot 'src') -Recurse -Include '*.ps1', '*.psm1' |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

BeforeAll {
    $ForbiddenCommands = @(
        # registry writes
        'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Rename-ItemProperty', 'Clear-ItemProperty',
        'Set-Item', 'Clear-Item', 'reg', 'reg.exe', 'regedit', 'regedit.exe',
        # services
        'Set-Service', 'Start-Service', 'Stop-Service', 'Restart-Service', 'Suspend-Service', 'Resume-Service',
        'New-Service', 'Remove-Service', 'sc', 'sc.exe', 'net', 'net.exe',
        # update / system actions
        'wuauclt', 'wuauclt.exe', 'usoclient', 'usoclient.exe', 'Install-WindowsUpdate', 'Get-WindowsUpdate',
        'Install-Module', 'Install-Package', 'Restart-Computer', 'Stop-Computer', 'shutdown', 'shutdown.exe',
        # policy / tasks / WMI writes
        'Set-ExecutionPolicy', 'Set-Acl', 'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Set-ScheduledTask',
        'Enable-ScheduledTask', 'Disable-ScheduledTask', 'Set-WmiInstance', 'Invoke-WmiMethod', 'Remove-WmiObject',
        'Invoke-CimMethod', 'Set-CimInstance', 'New-CimInstance', 'Remove-CimInstance', 'gpupdate', 'gpupdate.exe'
    )
    # .NET / COM methods that write the registry or download/install updates.
    $ForbiddenMethods = @(
        'CreateUpdateInstaller', 'CreateUpdateDownloader', 'Install', 'Uninstall', 'Download', 'Commit',
        'SetValue', 'CreateSubKey', 'DeleteValue', 'DeleteSubKey', 'DeleteSubKeyTree', 'ChangeStartMode'
    )
    $FileWriteCommands = @('Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Remove-Item', 'Copy-Item', 'Move-Item', 'Rename-Item', 'Clear-Content')
    $FileWriteAllowedIn = @('Initialize-WULog', 'Write-WULog', 'Remove-WUOldLog', 'Save-WUOutboxItem', 'Send-WUOutbox')

    function Get-Violation([System.Management.Automation.Language.Ast] $Ast, [string] $FileName) {
        $violations = New-Object System.Collections.Generic.List[string]
        $commands = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($command in $commands) {
            $name = $command.GetCommandName()
            if (-not $name) { continue }
            if ($ForbiddenCommands -contains $name) {
                $violations.Add("line $($command.Extent.StartLineNumber): forbidden command '$name'")
            }
            if ($FileWriteCommands -contains $name) {
                $parent = $command.Parent
                while ($parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
                $owner = $null
                if ($parent) { $owner = $parent.Name }
                $allowed = ($FileWriteAllowedIn -contains $owner) -or
                ($FileName -eq 'Invoke-WUMonitor.ps1' -and $name -eq 'Add-Content' -and -not $owner) # fallback fatal-error log
                if (-not $allowed) {
                    $violations.Add("line $($command.Extent.StartLineNumber): file write '$name' outside the log/outbox functions (in '$owner')")
                }
            }
        }
        $methods = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)
        foreach ($method in $methods) {
            $member = $method.Member.Extent.Text.Trim("'", '"')
            if ($ForbiddenMethods -contains $member) {
                $violations.Add("line $($method.Extent.StartLineNumber): forbidden method call '.$member()'")
            }
        }
        return , $violations.ToArray()
    }
}

Describe 'Read-only guarantee: <Name>' -ForEach $SourceFiles {
    It 'parses without syntax errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
    It 'contains no command or method that changes system state' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        Get-Violation -Ast $ast -FileName $Name | Should -BeNullOrEmpty
    }
    It 'is pure ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'Read-only scanner self-test' {
    # Proves the scanner actually catches violations, so a passing result above means something.
    It 'detects <Case>' -ForEach @(
        @{ Case = 'a registry write'; Code = 'Set-ItemProperty -Path HKLM:\X -Name A -Value 1' }
        @{ Case = 'a service change'; Code = 'Set-Service wuauserv -StartupType Disabled' }
        @{ Case = 'an update install via COM'; Code = '$s = New-Object -ComObject Microsoft.Update.Session; $s.CreateUpdateInstaller()' }
        @{ Case = 'a .NET registry write'; Code = '$key.SetValue("NoAutoUpdate", 1)' }
        @{ Case = 'reg.exe'; Code = 'reg add HKLM\Software\X /v A /d 1 /f' }
        @{ Case = 'a file write outside the log functions'; Code = 'function Get-Thing { Remove-Item C:\Windows\x }' }
    ) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$null)
        @(Get-Violation -Ast $ast -FileName 'sample.ps1').Count | Should -BeGreaterThan 0
    }
    It 'allows file writes inside Write-WULog' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput('function Write-WULog { Add-Content -Path x -Value y }', [ref]$null, [ref]$null)
        Get-Violation -Ast $ast -FileName 'sample.ps1' | Should -BeNullOrEmpty
    }
}
