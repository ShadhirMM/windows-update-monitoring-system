#Requires -Version 5.1
<#
.SYNOPSIS
    Installs WUMonitor and registers the weekly scheduled task. Run as Administrator.

.DESCRIPTION
    1. Copies the program to InstallPath (default: C:\Program Files\WUMonitor).
    2. Creates DataPath (default: C:\ProgramData\WUMonitor) with config.json, Logs and Outbox,
       restricted to SYSTEM and Administrators because config.json holds the webhook secret.
    3. Registers the 'WUMonitor' Application event log source.
    4. Registers a weekly scheduled task that runs as SYSTEM.
    5. Verifies the installation and optionally runs the task once (-RunNow).

    An existing config.json is kept. -WebhookUrl / -WebhookFormat update it in place.
    Use -ResetConfig to replace it with the example config. Supports -WhatIf.

.EXAMPLE
    .\Install-WUMonitor.ps1 -WebhookUrl 'https://discord.com/api/webhooks/...' -WebhookFormat discord -RunNow

.EXAMPLE
    .\Install-WUMonitor.ps1 -DayOfWeek Friday -At '14:30' -RandomDelayMinutes 30 -WhatIf
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive installer output')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $WebhookUrl,
    [ValidateSet('generic', 'teams', 'slack', 'discord')] [string] $WebhookFormat,
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')] [string] $DayOfWeek = 'Monday',
    [ValidatePattern('^([01]?\d|2[0-3]):[0-5]\d$')] [string] $At = '09:00',
    [ValidateRange(0, 720)] [int] $RandomDelayMinutes = 0,
    [string] $InstallPath = (Join-Path $env:ProgramFiles 'WUMonitor'),
    [string] $DataPath = (Join-Path $env:ProgramData 'WUMonitor'),
    [string] $TaskName = 'WUMonitor - Weekly Windows Update Check',
    [switch] $ResetConfig,
    [switch] $RunNow
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$sourcePath = Join-Path $repoRoot 'src'
$exampleConfig = Join-Path $repoRoot 'config\config.example.json'
$configPath = Join-Path $DataPath 'config.json'
$entryScript = Join-Path $InstallPath 'Invoke-WUMonitor.ps1'

function Write-Step([string] $Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

# --- Pre-flight checks ------------------------------------------------------------------
$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIfPreference) {
    throw 'Run this installer from an elevated PowerShell (Run as Administrator), or add -WhatIf to preview.'
}
foreach ($required in @((Join-Path $sourcePath 'Invoke-WUMonitor.ps1'), (Join-Path $sourcePath 'WUMonitor\WUMonitor.psm1'), $exampleConfig)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Package is incomplete, missing: $required" }
}
if ($WebhookUrl -and $WebhookUrl -notmatch '^https?://') { throw 'WebhookUrl must start with https://' }
# The installer replaces InstallPath recursively, so only accept dedicated WUMonitor folders.
foreach ($path in @($InstallPath, $DataPath)) {
    if ((Split-Path -Path $path -Leaf) -notmatch 'WUMonitor') { throw "Refusing to use '$path': the folder name must contain 'WUMonitor'." }
}
$version = (Import-PowerShellDataFile -Path (Join-Path $sourcePath 'WUMonitor\WUMonitor.psd1')).ModuleVersion
Write-Host "Installing WUMonitor $version" -ForegroundColor White

# --- 1. Program files ---------------------------------------------------------------------
Write-Step "Copying program files to $InstallPath"
if ($PSCmdlet.ShouldProcess($InstallPath, 'Copy program files')) {
    if (Test-Path -LiteralPath $InstallPath) { Remove-Item -LiteralPath $InstallPath -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $InstallPath -Force
    Copy-Item -Path (Join-Path $sourcePath '*') -Destination $InstallPath -Recurse -Force
    Get-ChildItem -LiteralPath $InstallPath -Recurse -File | Unblock-File
}

# --- 2. Data folder, config and permissions ----------------------------------------------
Write-Step "Preparing data folder $DataPath"
if ($PSCmdlet.ShouldProcess($DataPath, 'Create data folders and restrict access to SYSTEM and Administrators')) {
    foreach ($folder in @($DataPath, (Join-Path $DataPath 'Logs'), (Join-Path $DataPath 'Outbox'))) {
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    }
    # Only SYSTEM (S-1-5-18) and Administrators (S-1-5-32-544); inheritance from ProgramData removed.
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $DataPath -AclObject $acl
}

$configExists = Test-Path -LiteralPath $configPath
if (-not $configExists -or $ResetConfig) {
    Write-Step 'Creating config.json from config.example.json'
    if ($PSCmdlet.ShouldProcess($configPath, 'Create config file')) {
        Copy-Item -LiteralPath $exampleConfig -Destination $configPath -Force
    }
}
else {
    Write-Step 'Keeping existing config.json (use -ResetConfig to replace it)'
}

if ($WebhookUrl -or $WebhookFormat -or -not $configExists -or $ResetConfig) {
    if ($PSCmdlet.ShouldProcess($configPath, 'Set webhook and data paths in config')) {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($WebhookUrl) { $config.Webhook.Url = $WebhookUrl }
        if ($WebhookFormat) { $config.Webhook.Format = $WebhookFormat }
        $config.Logging.Path = Join-Path $DataPath 'Logs'
        $config.Outbox.Path = Join-Path $DataPath 'Outbox'
        Set-Content -LiteralPath $configPath -Value ($config | ConvertTo-Json -Depth 10) -Encoding UTF8
        Write-Host '    config.json updated' -ForegroundColor DarkGray
    }
}

# --- 3. Event log source ----------------------------------------------------------------
Write-Step "Registering event log source 'WUMonitor' (Application log)"
if ($PSCmdlet.ShouldProcess('Application log', "Create event source 'WUMonitor'")) {
    if (-not [System.Diagnostics.EventLog]::SourceExists('WUMonitor')) {
        [System.Diagnostics.EventLog]::CreateEventSource('WUMonitor', 'Application')
    }
}

# --- 4. Scheduled task ------------------------------------------------------------------
Write-Step "Registering scheduled task '$TaskName' ($DayOfWeek $At, runs as SYSTEM)"
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $entryScript, $configPath
if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
    $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments -WorkingDirectory $InstallPath
    $triggerArgs = @{ Weekly = $true; WeeksInterval = 1; DaysOfWeek = $DayOfWeek; At = [datetime]::ParseExact($At, 'H:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($RandomDelayMinutes -gt 0) { $triggerArgs.RandomDelay = New-TimeSpan -Minutes $RandomDelayMinutes }
    $trigger = New-ScheduledTaskTrigger @triggerArgs
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings `
        -Description "WUMonitor $version - read-only Windows Update configuration check. Reports OK/WARNING/ALERT to a webhook. Exit codes: 0 OK, 1 WARNING, 2 ALERT, 3 monitor error."
    $null = Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force
}

if ($WhatIfPreference) {
    Write-Host "`nWhatIf: no changes were made." -ForegroundColor Yellow
    return
}

# --- 5. Verification ------------------------------------------------------------------------
Write-Step 'Verifying installation'
$checks = [ordered]@{
    'Entry script present'  = Test-Path -LiteralPath $entryScript
    'Module present'        = Test-Path -LiteralPath (Join-Path $InstallPath 'WUMonitor\WUMonitor.psd1')
    'Config present'        = Test-Path -LiteralPath $configPath
    'Config is valid'       = $false
    'Scheduled task exists' = $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}
try {
    Import-Module (Join-Path $InstallPath 'WUMonitor\WUMonitor.psd1') -Force
    $null = Get-WUMonitorConfig -Path $configPath
    $checks['Config is valid'] = $true
}
catch { Write-Warning "Config validation failed: $($_.Exception.Message)" }

$failed = 0
foreach ($name in $checks.Keys) {
    if ($checks[$name]) { Write-Host "    [PASS] $name" -ForegroundColor Green }
    else { Write-Host "    [FAIL] $name" -ForegroundColor Red; $failed++ }
}
if ($failed -gt 0) { throw "Installation verification failed ($failed check(s)). See messages above." }

if (-not (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).Webhook.Url) {
    Write-Warning "No webhook URL configured. Results will only be logged. Re-run with -WebhookUrl or edit $configPath."
}

if ($RunNow) {
    Write-Step 'Running the task once now'
    Start-ScheduledTask -TaskName $TaskName
    $deadline = (Get-Date).AddMinutes(3)
    do {
        Start-Sleep -Seconds 2
        $state = (Get-ScheduledTask -TaskName $TaskName).State
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    $meaning = @{ 0 = 'OK'; 1 = 'WARNING'; 2 = 'ALERT'; 3 = 'MONITOR ERROR' }
    Write-Host ('    Last result: {0} ({1})' -f $info.LastTaskResult, $meaning[[int]$info.LastTaskResult])
    $latestLog = Get-ChildItem -LiteralPath (Join-Path $DataPath 'Logs') -Filter 'WUMonitor_*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestLog) {
        Write-Host "    Log: $($latestLog.FullName)" -ForegroundColor DarkGray
        Get-Content -LiteralPath $latestLog.FullName -Tail 15 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    }
}

Write-Host "`nWUMonitor $version installed." -ForegroundColor Green
Write-Host "  Program : $InstallPath"
Write-Host "  Config  : $configPath"
Write-Host "  Logs    : $(Join-Path $DataPath 'Logs')"
Write-Host "  Task    : $TaskName ($DayOfWeek $At)"
Write-Host "  Rollback: .\Uninstall-WUMonitor.ps1"
