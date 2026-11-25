#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the release package dist\WUMonitor-<version>.zip plus a SHA-256 checksum file.
    Runs the quality gate first unless -SkipQualityGate is given.

.DESCRIPTION
    The zip contains everything needed to deploy: src\, install\, config\config.example.json,
    docs\, README.md, CHANGELOG.md and LICENSE. Store the zip and the .sha256 file together in
    the program library; verify the hash before deploying.

.EXAMPLE
    .\build\New-WUMonitorPackage.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Build console output')]
[CmdletBinding()]
param([switch] $SkipQualityGate)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

if (-not $SkipQualityGate) {
    & (Join-Path $PSScriptRoot 'Invoke-QualityGate.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Quality gate failed; package not built.' }
}

$version = (Import-PowerShellDataFile -Path (Join-Path $repoRoot 'src/WUMonitor/WUMonitor.psd1')).ModuleVersion
$dist = Join-Path $repoRoot 'dist'
$staging = Join-Path $dist "WUMonitor-$version"
$zip = Join-Path $dist "WUMonitor-$version.zip"

if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
$null = New-Item -ItemType Directory -Path (Join-Path $staging 'config') -Force

foreach ($item in @('src', 'install', 'docs', 'README.md', 'CHANGELOG.md', 'LICENSE')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $item) -Destination $staging -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'config/config.example.json') -Destination (Join-Path $staging 'config') -Force

# Entries are added one by one with '/' separators: on Windows PowerShell 5.1 both Compress-Archive
# and ZipFile.CreateFromDirectory write '\', which produces broken paths when extracted on macOS/Linux.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in Get-ChildItem -LiteralPath $staging -Recurse -File) {
        $entryName = $file.FullName.Substring($staging.Length).TrimStart('\', '/').Replace('\', '/')
        $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
    }
}
finally { $archive.Dispose() }
Remove-Item -LiteralPath $staging -Recurse -Force

$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$zip.sha256" -Value ('{0}  {1}' -f $hash, (Split-Path $zip -Leaf)) -Encoding ASCII

Write-Host "Package : $zip" -ForegroundColor Green
Write-Host "SHA-256 : $hash"
