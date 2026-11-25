#Requires -Version 5.1
<#
.SYNOPSIS
    Removes WUMonitor (rollback for Install-WUMonitor.ps1). Run as Administrator.

.DESCRIPTION
    Removes the scheduled task and the program folder. Config and logs in DataPath are kept
    by default so the evidence trail is preserved; add -RemoveData to delete them as well.
    Add -RemoveEventSource to unregister the 'WUMonitor' event log source. Supports -WhatIf.

.EXAMPLE
    .\Uninstall-WUMonitor.ps1
.EXAMPLE
    .\Uninstall-WUMonitor.ps1 -RemoveData -RemoveEventSource
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive uninstaller output')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $InstallPath = (Join-Path $env:ProgramFiles 'WUMonitor'),
    [string] $DataPath = (Join-Path $env:ProgramData 'WUMonitor'),
    [string] $TaskName = 'WUMonitor - Weekly Windows Update Check',
    [switch] $RemoveData,
    [switch] $RemoveEventSource
)

$ErrorActionPreference = 'Stop'

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator) -and -not $WhatIfPreference) {
    throw 'Run this script from an elevated PowerShell (Run as Administrator), or add -WhatIf to preview.'
}

# Folders are deleted recursively, so only accept dedicated WUMonitor folders.
foreach ($path in @($InstallPath, $DataPath)) {
    if ((Split-Path -Path $path -Leaf) -notmatch 'WUMonitor') { throw "Refusing to use '$path': the folder name must contain 'WUMonitor'." }
}

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'"
    }
}
else { Write-Host "Scheduled task '$TaskName' not found (already removed)" }

if (Test-Path -LiteralPath $InstallPath) {
    if ($PSCmdlet.ShouldProcess($InstallPath, 'Delete program folder')) {
        Remove-Item -LiteralPath $InstallPath -Recurse -Force
        Write-Host "Removed $InstallPath"
    }
}

if ($RemoveData) {
    if ((Test-Path -LiteralPath $DataPath) -and $PSCmdlet.ShouldProcess($DataPath, 'Delete config, logs and outbox')) {
        Remove-Item -LiteralPath $DataPath -Recurse -Force
        Write-Host "Removed $DataPath"
    }
}
elseif (Test-Path -LiteralPath $DataPath) {
    Write-Host "Kept config and logs in $DataPath (use -RemoveData to delete)"
}

if ($RemoveEventSource) {
    try {
        if ([System.Diagnostics.EventLog]::SourceExists('WUMonitor') -and $PSCmdlet.ShouldProcess('WUMonitor', 'Remove event log source')) {
            [System.Diagnostics.EventLog]::DeleteEventSource('WUMonitor')
            Write-Host "Removed event log source 'WUMonitor'"
        }
    }
    catch { Write-Warning "Could not remove event source: $($_.Exception.Message)" }
}

Write-Host 'WUMonitor uninstalled.' -ForegroundColor Green
