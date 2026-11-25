# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-25

### Added
- Read-only collection of Windows Update configuration and health: services, Automatic Updates policy, pauses, deferrals, update source (WSUS), update history via the Windows Update Agent (with `Get-HotFix` fallback), pending reboot, OS build/edition.
- Nine checks with configurable thresholds: ServiceState, AutoUpdatePolicy, PauseState, DeferralPolicy, UpdateSource, LastQualityUpdate, RecentFailures, PendingReboot, OsSupport.
- Webhook delivery in generic JSON, Microsoft Teams (Workflows / Adaptive Card), Slack and Discord formats, with retry and exponential backoff.
- Outbox: undelivered reports are queued and re-sent on the next run.
- Daily log files with retention, Application event log entries (IDs 1000-1004), exit codes 0/1/2/3.
- Fatal-error ALERT notification, including when the configuration is invalid.
- `-DryRun`, `-ComputerName` (remote via WinRM), `-PassThru`.
- Installer with ACL-restricted config, weekly SYSTEM scheduled task, post-install verification, `-RunNow` and `-WhatIf`; uninstaller for rollback.
- 164 Pester tests (unit + integration), static read-only proof, PSScriptAnalyzer gate, CI on Windows PowerShell 5.1 and PowerShell 7, release packaging with SHA-256 checksum.
