#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the full quality gate: PSScriptAnalyzer, then Pester (unit + integration) with code coverage.
    Exits non-zero if anything fails. Used locally and by CI.

.PARAMETER SkipIntegration
    Run unit tests only (no live collection, no child processes, no local HTTP listener).

.EXAMPLE
    .\build\Invoke-QualityGate.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Build console output')]
[CmdletBinding()]
param([switch] $SkipIntegration)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$resultsDir = Join-Path $repoRoot 'TestResults'
$null = New-Item -ItemType Directory -Path $resultsDir -Force

Import-Module PSScriptAnalyzer -ErrorAction Stop
Import-Module Pester -MinimumVersion 5.5.0 -ErrorAction Stop

# --- 1. Static analysis ---------------------------------------------------------------------
Write-Host '==> PSScriptAnalyzer' -ForegroundColor Cyan
$settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
$findings = @(foreach ($folder in @('src', 'install', 'build')) {
        Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot $folder) -Recurse -Settings $settings
    })
if ($findings.Count -gt 0) {
    $findings | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    Write-Host "PSScriptAnalyzer: $($findings.Count) finding(s)" -ForegroundColor Red
}
else {
    Write-Host 'PSScriptAnalyzer: no findings' -ForegroundColor Green
}

# --- 2. Tests ---------------------------------------------------------------------------------
Write-Host '==> Pester' -ForegroundColor Cyan
$config = New-PesterConfiguration
$config.Run.Path = Join-Path $repoRoot 'tests'
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Normal'
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = Join-Path $resultsDir 'pester-results.xml'
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = @(Join-Path $repoRoot 'src/WUMonitor/WUMonitor.psm1')
$config.CodeCoverage.OutputPath = Join-Path $resultsDir 'coverage.xml'
if ($SkipIntegration) { $config.Filter.ExcludeTag = @('Integration') }

$result = Invoke-Pester -Configuration $config

$coverage = 0
if ($result.CodeCoverage -and $result.CodeCoverage.CommandsAnalyzedCount -gt 0) {
    $coverage = [Math]::Round(100 * $result.CodeCoverage.CommandsExecutedCount / $result.CodeCoverage.CommandsAnalyzedCount, 1)
}

# --- Summary --------------------------------------------------------------------------------
Write-Host ''
Write-Host '==> Summary' -ForegroundColor Cyan
Write-Host ("  PowerShell      : {0} {1}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
Write-Host ("  Analyzer        : {0} finding(s)" -f $findings.Count)
Write-Host ("  Tests           : {0} passed, {1} failed, {2} skipped" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount)
Write-Host ("  Code coverage   : {0}% of WUMonitor.psm1 commands" -f $coverage)
Write-Host ("  Results         : {0}" -f $resultsDir)

if ($findings.Count -gt 0 -or $result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
    Write-Host 'QUALITY GATE FAILED' -ForegroundColor Red
    exit 1
}
Write-Host 'QUALITY GATE PASSED' -ForegroundColor Green
exit 0
