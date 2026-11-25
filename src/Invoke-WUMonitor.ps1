#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only Windows Update configuration monitor. Reports OK / WARNING / ALERT to a webhook.

.DESCRIPTION
    Checks Windows Update service state, Automatic Updates policy, pauses, deferrals, update
    source (WSUS), last successful quality update, unresolved update failures, pending reboot
    and OS servicing status. Sends one report per computer to the configured webhook and
    writes a local log. It never changes any setting.

    Designed to run weekly as a scheduled task (see install\Install-WUMonitor.ps1).

.PARAMETER ConfigPath
    Path to config.json. If omitted, uses %ProgramData%\WUMonitor\config.json, then
    ..\config\config.json next to this script, then built-in defaults (no webhook).

.PARAMETER ComputerName
    Remote computers to check over WinRM (Invoke-Command). Defaults to the local computer
    (or the "Computers" list in the config).

.PARAMETER DryRun
    Collect and evaluate, print the webhook payload, but do not send it.

.PARAMETER PassThru
    Output the result objects (Report, Payload, Delivery) to the pipeline.

.EXAMPLE
    .\Invoke-WUMonitor.ps1 -DryRun
    Checks this computer and prints the result and the payload without sending anything.

.EXAMPLE
    .\Invoke-WUMonitor.ps1 -ConfigPath C:\ProgramData\WUMonitor\config.json
    Normal scheduled run.

.NOTES
    Exit codes: 0 = OK, 1 = WARNING, 2 = ALERT, 3 = the monitor itself failed.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Coloured console summary for interactive runs; scheduled runs use the log file')]
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string[]] $ComputerName,
    [switch] $DryRun,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$exitCode = 3
$config = $null

try {
    Import-Module -Name (Join-Path $PSScriptRoot 'WUMonitor\WUMonitor.psd1') -Force

    if (-not $ConfigPath) {
        $candidates = @(
            (Join-Path $env:ProgramData 'WUMonitor\config.json')
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\config.json')
        )
        $ConfigPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    }
    $config = Get-WUMonitorConfig -Path $ConfigPath

    $results = @(Invoke-WUMonitorRun -Config $config -ComputerName $ComputerName -DryRun:$DryRun)

    $colors = @{ OK = 'Green'; WARNING = 'Yellow'; ALERT = 'Red' }
    foreach ($result in $results) {
        $report = $result.Report
        Write-Host ''
        Write-Host ('{0}  {1}  ({2})' -f $report.ComputerName, $report.Status, $report.Summary) -ForegroundColor $colors[$report.Status]
        Write-Host ('  {0}' -f $report.OperatingSystem) -ForegroundColor DarkGray
        foreach ($check in $report.Checks) {
            Write-Host ('  [{0,-7}] {1,-18} {2}' -f $check.Status, $check.Name, $check.Message) -ForegroundColor $colors[$check.Status]
        }
        Write-Host ('  Webhook: {0}' -f $result.Delivery) -ForegroundColor DarkGray
        if ($DryRun) {
            Write-Host ''
            Write-Host ('Payload ({0}):' -f $config.Webhook.Format) -ForegroundColor DarkGray
            Write-Host $result.Payload
        }
    }
    if ($ConfigPath) { Write-Host ("`nConfig: {0}" -f $ConfigPath) -ForegroundColor DarkGray }
    else { Write-Host "`nConfig: built-in defaults (no config file found)" -ForegroundColor DarkGray }

    $exitCode = Get-WUExitCode -Report @($results | ForEach-Object { $_.Report })
    if ($PassThru) { $results }
}
catch {
    $message = $_.Exception.Message
    if (Get-Command -Name Send-WUFailureNotice -ErrorAction SilentlyContinue) {
        $null = Send-WUFailureNotice -Config $config -ErrorMessage $message
    }
    else {
        # The module could not be loaded: write a minimal log line so the failure is visible.
        try {
            $fallback = Join-Path ([System.IO.Path]::GetTempPath()) 'WUMonitor_fatal.log'
            Add-Content -LiteralPath $fallback -Value ('{0:o} [ERROR] {1}' -f (Get-Date), $message)
        }
        catch { Write-Verbose 'Fallback log not writable' }
    }
    Write-Error -Message "WUMonitor failed: $message" -ErrorAction Continue
    $exitCode = 3
}

exit $exitCode
