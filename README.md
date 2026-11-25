# WUMonitor: Windows Update Configuration Monitor

![CI](https://github.com/ShadhirMM/windows-update-monitoring-system/actions/workflows/ci.yml/badge.svg)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE)
![Tests](https://img.shields.io/badge/tests-164%20passing-brightgreen)
![Coverage](https://img.shields.io/badge/coverage-92.6%25-brightgreen)
![License](https://img.shields.io/badge/license-MIT-blue)

A **read-only** PowerShell tool that checks Windows Update configuration and health on Windows machines, runs **weekly as a scheduled task**, and reports **OK / WARNING / ALERT** to a webhook (Microsoft Teams, Slack, Discord or any JSON endpoint). It never changes a setting.

> Built with Claude Code as the AI pair-programmer. Every line was reviewed, and the behaviour is covered by 164 automated tests, a static "read-only" proof, and end-to-end runs on a real Windows 11 machine. See [How AI was used](#how-ai-was-used).

---

## Why

Silent update problems are common and costly: a user pauses updates "for a week" and forgets, a policy left behind by an old tool disables Automatic Updates, a cumulative update fails every night, a machine waits on a reboot for a month, or the OS version quietly reaches end of servicing. None of these show up until something breaks.

WUMonitor checks all of these on a fixed schedule, sends one clear message per machine, and keeps a local audit log, **without touching the configuration it is checking**.

## What a report looks like

Console output for a machine with problems (sample data):

```text
OFFICE-PC-01  ALERT  (1 ALERT, 4 WARNING, 4 OK)
  Microsoft Windows 11 Pro 25H2 (build 26200.7171)
  [OK     ] ServiceState       Update services enabled (wuauserv: Manual, UsoSvc: Automatic, WaaSMedicSvc: Manual)
  [WARNING] AutoUpdatePolicy   AUOptions=3: download automatically, notify to install; installs need manual action
  [ALERT  ] PauseState         Updates paused until 2026-12-16 (21 days remaining)
  [OK     ] DeferralPolicy     No update deferral configured
  [OK     ] UpdateSource       Microsoft Windows Update online service
  [WARNING] LastQualityUpdate  41 days ago on 2026-10-15: 2026-10 Security Update (KB5000001) (26200.7019)
  [WARNING] RecentFailures     1 unresolved failed update(s) in the last 30 days: KB5000002 (0x80070643)
  [WARNING] PendingReboot      Reboot pending (Windows Update); last boot 2 days ago
  [OK     ] OsSupport          Microsoft Windows 11 Pro 25H2 (build 26200.7171) supported until 2027-10-12 (Pro channel)
  Webhook: Sent
```

The same report as webhook payloads: [generic JSON](docs/samples/payload-generic.json) · [Teams](docs/samples/payload-teams.json) · [Slack](docs/samples/payload-slack.json) · [Discord](docs/samples/payload-discord.json)

## The nine checks

| Check | Reads (read-only) | OK | WARNING | ALERT |
|---|---|---|---|---|
| **ServiceState** | `wuauserv`, `UsoSvc`, `WaaSMedicSvc` start type | Enabled | `WaaSMedicSvc` disabled | `wuauserv` / `UsoSvc` disabled or missing |
| **AutoUpdatePolicy** | `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU` | No policy, or `AUOptions=4` | `AUOptions` 2, 3, 5, 7 | `NoAutoUpdate=1` |
| **PauseState** | `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings` + policy pauses | Not paused | Paused ≤ 7 days | Paused > 7 days |
| **DeferralPolicy** | `DeferQualityUpdatesPeriodInDays`, `DeferFeatureUpdatesPeriodInDays` | Quality ≤ 7 d, feature ≤ 180 d | Quality 8–14 d, feature > 180 d | Quality > 14 d (Windows allows up to 30) |
| **UpdateSource** | `UseWUServer`, `WUServer`, `DoNotConnectToWindowsUpdateInternetLocations` | Microsoft Update or approved WSUS | Unapproved WSUS server | No reachable update source |
| **LastQualityUpdate** | Windows Update Agent history (`QueryHistory`), fallback `Get-HotFix` | ≤ 35 days | 36–60 days | > 60 days |
| **RecentFailures** | Failed installs in the last 30 days not later fixed by a success | None | 1–2 | ≥ 3 |
| **PendingReboot** | `RebootRequired` / CBS `RebootPending` + uptime | None | Pending < 7 days | Pending ≥ 7 days |
| **OsSupport** | Build + edition vs. Microsoft lifecycle table | Supported | ≤ 60 days to end of servicing, or unknown build | Past end of servicing |

The **overall status** is the worst check. Every threshold is configurable.

## Quick start

Requirements: Windows 10/11 or Server 2019+, Windows PowerShell 5.1 (built in) or PowerShell 7. No modules to install.

```powershell
# 1. Try it: collects and evaluates, prints the payload, sends nothing
.\src\Invoke-WUMonitor.ps1 -DryRun

# 2. Install (elevated PowerShell): copies files, secures the config, registers the weekly task
.\install\Install-WUMonitor.ps1 -WebhookUrl 'https://discord.com/api/webhooks/...' -WebhookFormat discord -RunNow

# Preview the install without changing anything
.\install\Install-WUMonitor.ps1 -WhatIf

# 3. Roll back (keeps logs and config unless -RemoveData)
.\install\Uninstall-WUMonitor.ps1
```

The installer:

| Step | Detail |
|---|---|
| Program | `C:\Program Files\WUMonitor` |
| Data | `C:\ProgramData\WUMonitor\{config.json, Logs, Outbox}`, with ACL limited to **SYSTEM + Administrators** (the config holds the webhook secret) |
| Task | `WUMonitor - Weekly Windows Update Check`, Monday 09:00, runs as SYSTEM, *run as soon as possible after a missed start*, 30-minute limit. Options: `-DayOfWeek`, `-At`, `-RandomDelayMinutes` for fleets |
| Event log | Registers source `WUMonitor` in the Application log |
| Checks | Verifies files, config validity and task registration. `-RunNow` runs the task once and shows the result and log tail |

### Checking several machines from one admin PC

```powershell
.\src\Invoke-WUMonitor.ps1 -ComputerName PC-01, PC-02, PC-03
```

This uses WinRM (`Invoke-Command`). The collector function is self-contained, so it is sent to each machine as a script block. An unreachable machine becomes a `WARNING` (Connectivity) report instead of failing the run. Installing locally on each machine is still the recommended model; see [design decisions](docs/ARCHITECTURE.md#design-decisions).

## Configuration

`config.json` (from [`config/config.example.json`](config/config.example.json)). Any key you leave out uses the built-in default.

| Key | Default | Meaning |
|---|---|---|
| `Webhook.Url` | *(empty)* | Webhook URL. The `WUMONITOR_WEBHOOK_URL` environment variable overrides it |
| `Webhook.Format` | `generic` | `generic`, `teams` (Workflows / Adaptive Card), `slack`, `discord` |
| `Webhook.SendOn` | `Always` | `Always` (a weekly heartbeat proves the monitor is alive), `WarningOrAbove`, `AlertOnly` |
| `Webhook.RetryCount` | `3` | Retries with exponential backoff (2 s, 4 s, 8 s). No retry on HTTP 4xx except 408/429 |
| `Thresholds.*` | see table above | All day/count thresholds, validated at start-up (warn must be < alert) |
| `History.QualityUpdatePattern` | `(Cumulative\|Security\|Quality) Update` | Which history titles count as OS quality updates |
| `History.ExcludePattern` | `Security Intelligence\|Defender\|\.NET\|...` | Ignored titles (daily Defender signatures would otherwise hide a stalled OS) |
| `AllowedWsusServers` | `[]` | Approved WSUS servers (URL or host name) |
| `OsLifecycle` | Win10 1809 → Win11 25H2, Server 2019–2025 | End-of-servicing dates per build and channel (Pro / Enterprise / LTSC / Server) |
| `UnknownBuildStatus` | `WARNING` | Status for builds not in the lifecycle table |
| `Logging.Path` / `RetentionDays` | `C:\ProgramData\WUMonitor\Logs` / `30` | Daily log files, old ones deleted automatically |
| `Outbox.Path` / `MaxAgeDays` | `C:\ProgramData\WUMonitor\Outbox` / `30` | Undelivered reports, re-sent on the next run |
| `Computers` | `[]` | Default remote targets when `-ComputerName` is not given |

## Exit codes and events

| Exit code | Meaning | Event ID (Application log, source `WUMonitor`) |
|---|---|---|
| `0` | All checks OK | 1000 (Information) |
| `1` | At least one WARNING | 1001 (Warning) |
| `2` | At least one ALERT | 1002 (Error) |
| `3` | The monitor itself failed (bad config, crash). An ALERT webhook is still attempted | 1003 (Error) |
| | Webhook delivery failed; report queued in the outbox | 1004 (Warning) |

Task Scheduler's *Last Run Result* therefore shows the machine's status at a glance.

## Reliability and security

- **Read-only, and proven.** [`tests/ReadOnly.Tests.ps1`](tests/ReadOnly.Tests.ps1) parses every source file and fails the build if it finds any registry or service write, `reg.exe`/`sc.exe`, a COM update install or download, a scheduled-task change, or a file write outside the log/outbox functions. A self-test proves the scanner catches each of these. An end-to-end test also compares a snapshot of the Windows Update policy keys, service start types and scheduled tasks before and after a real run.
- **Never loses a report.** If the webhook is down, the payload goes to the outbox and is delivered on the next run. Items older than 30 days are dropped.
- **Fails loudly.** An invalid config or unexpected exception gives exit code 3, an event log entry, and a best-effort ALERT webhook.
- **One failure doesn't stop the rest.** Each data source is collected independently. A failed source becomes a `WARNING` with the reason, and the other checks still run.
- **Secrets stay secret.** Webhook URLs are never logged (only `https://host/***`), the config is ACL-restricted, the real `config.json` is git-ignored, and an environment-variable override is supported.
- **Compatible.** Pure-ASCII sources (Windows PowerShell 5.1 reads BOM-less files as ANSI), TLS 1.2 forced on 5.1, and CI runs on both Windows PowerShell 5.1 and PowerShell 7.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
.\build\Invoke-QualityGate.ps1            # lint + 164 tests + coverage
.\build\New-WUMonitorPackage.ps1          # quality gate, then dist\WUMonitor-1.0.0.zip + .sha256
```

| Suite | Tests | What it covers |
|---|---|---|
| `Checks.Tests.ps1` | 69 | Every rule, every boundary (35/36/60/61 days...), missing data |
| `Config.Tests.ps1` | 27 | Defaults, merge, env override, every validation error |
| `Report.Tests.ps1` | 23 | Status roll-up, exit codes, all four payload formats, JSON edge cases |
| `Delivery.Tests.ps1` | 20 | Retry/backoff, 4xx vs 5xx/429, secret masking, outbox, log retention, unreachable hosts |
| `Collector.Tests.ps1` | 6 | Update history parsing with a mocked Windows Update Agent, Get-HotFix fallback |
| `ReadOnly.Tests.ps1` | 13 | Static read-only proof + scanner self-test + ASCII check |
| `Integration.Tests.ps1` | 6 | Real runs in a child process: local webhook listener, outbox recovery, exit code 3 path, before/after system snapshot |

Full evidence: [docs/TESTING.md](docs/TESTING.md).

## How AI was used

This project was built with **Claude Code** as a pair-programmer, following the same discipline I would apply to any AI-written code:

1. **I wrote the plan and the requirements first** ([docs/PLAN.md](docs/PLAN.md)): read-only, weekly, webhook, error handling, logging.
2. **I checked real data before writing rules.** The registry, services and update history were inspected on a real Windows 11 machine. That showed that daily Defender signature updates would hide a stalled OS (hence `ExcludePattern`), and that newer cumulative updates are titled "Security Update", not "Cumulative Update".
3. **Tests caught real bugs in AI-written code.** The first end-to-end run reported `AUOptions value: 0` on a machine with no policy, because in PowerShell `$null -as [int]` is `0`, not `$null`. That would have produced false warnings and broken the deferral logic. It was fixed with a null-safe helper and locked in with a regression test. Pester 6 also exposed a mock fall-through difference, which led to cleaner code.
4. **Nothing was trusted without evidence**: 164 tests, 92.6% code coverage, zero PSScriptAnalyzer findings, and a static proof that the code cannot change system state.

## Project structure

```text
src/
  Invoke-WUMonitor.ps1          entry point (scheduled task runs this)
  WUMonitor/WUMonitor.psm1      collection, evaluation, reporting, delivery, logging
  WUMonitor/WUMonitor.psd1      module manifest (version source of truth)
install/                        Install-WUMonitor.ps1, Uninstall-WUMonitor.ps1 (rollback)
config/config.example.json      documented configuration template
tests/                          Pester 5/6 suites (unit + integration)
build/                          quality gate + release packaging
docs/                           architecture, runbook, testing evidence, plan, sample payloads
.github/workflows/ci.yml        CI on Windows PowerShell 5.1 and PowerShell 7
```

## Documentation

- [Architecture and design decisions](docs/ARCHITECTURE.md)
- [Runbook: what to do for each WARNING/ALERT](docs/RUNBOOK.md)
- [Testing evidence](docs/TESTING.md)
- [Implementation plan](docs/PLAN.md)
- [Changelog](CHANGELOG.md)

## Limitations

- `OsLifecycle` dates must be maintained as Microsoft releases new builds. Unknown builds are flagged so you notice.
- The pending-reboot age is approximated by uptime, because the registry flags carry no timestamp.
- Machines on paid Windows 10 ESU still show `OsSupport` ALERT unless you extend the `19045` dates in the config.

## License

MIT, see [LICENSE](LICENSE).
