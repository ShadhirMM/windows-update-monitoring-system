# Implementation plan

**Goal:** a PowerShell script that checks Windows Update configuration across machines and reports OK, WARNING or ALERT to a webhook.

**Requirements:** read-only monitoring · weekly scheduled execution · error handling and logging.

| Phase | Scope | Status |
|---|---|---|
| 0. Setup | Repo layout, `.gitignore` (secrets, logs), Pester + PSScriptAnalyzer, target Windows PowerShell 5.1 and PowerShell 7 | Done |
| 1. Data collection | `Get-WURawState`: services, AU policy, pauses, deferrals, WSUS, update history (WUA COM + Get-HotFix fallback), pending reboot, OS build/edition. Each source isolated in its own try/catch. Self-contained for remote use | Done |
| 2. Evaluation and output | Nine pure `Test-WU*` rules, configurable thresholds, worst-status roll-up, exit codes 0/1/2/3 | Done |
| 3. Webhook, logging, error handling | Generic/Teams/Slack/Discord payloads; retry with backoff; outbox for failed deliveries; daily log with retention; Application event log; fatal-error ALERT; `-DryRun` | Done |
| 4. Testing | 164 Pester tests (unit + integration), static read-only proof, 92.6% coverage, zero analyzer findings, CI on 5.1 and 7 | Done |
| 5. Deployment | Installer (ACL-secured config, event source, weekly SYSTEM task, verification, `-RunNow`, `-WhatIf`) and uninstaller (rollback) | Done; VM verification checklist in [TESTING.md](TESTING.md) |
| 6. Documentation | README, architecture and design decisions, runbook, testing evidence, changelog, release packaging with SHA-256 | Done |

## Status rules

| Status | Meaning |
|---|---|
| OK | Configuration healthy; no action |
| WARNING | Needs attention soon, or data could not be read |
| ALERT | Updates are blocked, badly overdue, or the OS is unsupported; act now |

Overall status = worst check. Exit code = 0 / 1 / 2, or 3 if the monitor itself failed.
