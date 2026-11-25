# Testing evidence

## Automated quality gate

`.\build\Invoke-QualityGate.ps1`, last run 2026-11-25 on Windows 11 Pro (build 26300), Windows PowerShell 5.1.26100, Pester 6.2.0, PSScriptAnalyzer 1.25.0:

```text
==> Summary
  PowerShell      : Desktop 5.1.26100.10068
  Analyzer        : 0 finding(s)
  Tests           : 164 passed, 0 failed, 0 skipped
  Code coverage   : 92.6% of WUMonitor.psm1 commands
QUALITY GATE PASSED
```

CI (`.github/workflows/ci.yml`) runs the same gate on GitHub's `windows-latest` under **both** Windows PowerShell 5.1 and PowerShell 7, then builds the release zip.

| Suite | Tests | Type |
|---|---|---|
| Checks | 69 | Unit: every evaluation rule and boundary, with a fixed clock |
| Config | 27 | Unit: loading, merging, env override, validation errors |
| Report | 23 | Unit: roll-up, exit codes, Teams/Slack/Discord/generic payloads |
| Delivery | 20 | Unit (mocked HTTP): retry/backoff, 4xx handling, secret masking, outbox, retention |
| Collector | 6 | Unit (mocked Windows Update Agent COM): history parsing, failure resolution, fallback |
| ReadOnly | 13 | Static AST proof of the read-only guarantee + scanner self-test |
| Integration | 6 | Real machine, separate `powershell.exe` per run, local HTTP listener as the webhook |

## Integration scenarios (automated)

| Scenario | Result |
|---|---|
| Live collection: all 7 data sections collected, no collector errors | Pass |
| Read-only proof: snapshot of WU policy keys, UX pause settings, service start types and scheduled tasks is identical before and after a full run | Pass |
| Full run delivers one valid 9-check report to the webhook; exit code matches the reported status; log contains the delivery but not the URL secret | Pass |
| `-DryRun` prints the payload and sends nothing | Pass |
| Webhook down: run still exits with the status code, report saved to the outbox; next run delivers the queued report and the new one, and the outbox is emptied | Pass |
| Invalid config: exit code 3 and an ALERT "Monitor" webhook is delivered (via `WUMONITOR_WEBHOOK_URL`) | Pass |

All integration runs log to Pester's temporary `TestDrive`, except the invalid-config scenario. By design, a run whose config cannot be loaded logs to the default `C:\ProgramData\WUMonitor\Logs` (where an admin would look), so that test leaves a few `[ERROR] Monitor failure` lines there.

## Bugs found by testing during development

| Found by | Bug | Fix |
|---|---|---|
| First end-to-end dry run on a real machine | `AUOptions value: 0` WARNING on a machine with no policy: `$null -as [int]` returns `0` in PowerShell. The same bug hid `DeferQualityUpdatesPeriodInDays` when the `DeferQualityUpdates` flag was absent | Added null-safe `ConvertTo-WUInt`; regression test *"does not treat a missing AUOptions value as 0"* |
| Collector tests on Pester 6 | Filtered `New-Object` mocks no longer fall through to the real cmdlet | Internal lists now use `[List[T]]::new()`, so only the COM call goes through `New-Object` |
| Quality gate | Under `$ErrorActionPreference = 'Stop'`, Windows PowerShell 5.1 turns a child process's stderr into a terminating error | Test helper collects stderr with a local `Continue` preference |
| Real update history review | Defender signature updates (several per day) would mask an unpatched OS | `History.ExcludePattern`, plus a collector test proving they are skipped |

## Manual verification in a VM (installer and failure scenarios)

The automated suite does not change system settings (by design). Verify the installer and the ALERT scenarios in a disposable **Windows 11 VM** (Hyper-V / VirtualBox) with a checkpoint, from an **elevated** PowerShell. Use a Discord or webhook.site URL to see the messages.

```powershell
# 0. Checkpoint the VM first. Then install and run once:
.\install\Install-WUMonitor.ps1 -WebhookUrl '<url>' -WebhookFormat discord -RunNow
#    Expect: all verification checks PASS, task result 0 or 1, a message in the channel.

# 1. Disable the Windows Update service             -> ServiceState ALERT
Set-Service wuauserv -StartupType Disabled

# 2. Disable Automatic Updates by policy            -> AutoUpdatePolicy ALERT
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' NoAutoUpdate 1 -Type DWord

# 3. Long quality-update deferral                   -> DeferralPolicy ALERT
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' DeferQualityUpdatesPeriodInDays 30 -Type DWord
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' DeferQualityUpdates 1 -Type DWord

# 4. Pause updates for 5 weeks: Settings > Windows Update > Pause    -> PauseState ALERT

# Run and look at the result:
Start-ScheduledTask 'WUMonitor - Weekly Windows Update Check'
Get-Content (Get-ChildItem C:\ProgramData\WUMonitor\Logs\*.log | Sort LastWriteTime | Select -Last 1) -Tail 15

# 5. Webhook outage: set a wrong host in config.json, run (event 1004, file in Outbox),
#    restore the URL, run again (queued report delivered, Outbox empty).

# Revert: restore the VM checkpoint, or undo each change and run .\install\Uninstall-WUMonitor.ps1 -RemoveData
```

Record the results (and screenshots of the channel messages, Task Scheduler *Last Run Result*, and Event Viewer) in the table below.

| # | Scenario | Expected | Result |
|---|---|---|---|
| 0 | Install + `-RunNow` | Verification PASS, message received | *to record* |
| 1 | `wuauserv` disabled | ServiceState ALERT, exit 2, event 1002 | *to record* |
| 2 | `NoAutoUpdate=1` | AutoUpdatePolicy ALERT | *to record* |
| 3 | Quality deferral 30 days | DeferralPolicy ALERT | *to record* |
| 4 | Paused 5 weeks | PauseState ALERT | *to record* |
| 5 | Webhook outage and recovery | Event 1004, outbox, then delivered | *to record* |
| 6 | `Uninstall-WUMonitor.ps1` | Task and program removed, data kept | *to record* |
