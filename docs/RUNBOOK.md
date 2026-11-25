# Runbook

What each WARNING / ALERT means and how to fix it. WUMonitor never fixes anything itself. Every change below is a deliberate, manual action. Follow change control: confirm scope, note the current value, make the change, then re-run `Invoke-WUMonitor.ps1 -DryRun` to confirm.

To see the full detail for a machine: `C:\ProgramData\WUMonitor\Logs\WUMonitor_<date>.log`, or Event Viewer > Application > source `WUMonitor`.

---

## ServiceState

| Message | Meaning | Fix |
|---|---|---|
| `wuauserv (Windows Update) is Disabled` | Windows cannot scan for or install updates | `Set-Service wuauserv -StartupType Manual`. Find out who disabled it (tweaking tools, GPO, "debloat" scripts) |
| `UsoSvc (Update Orchestrator) is Disabled` | Scans and installs are never scheduled | `Set-Service UsoSvc -StartupType Automatic` |
| `WaaSMedicSvc is Disabled` | The self-repair service for Windows Update was tampered with | Usually done by third-party tools. Revert via the tool, or a repair install / `DISM /Online /Cleanup-Image /RestoreHealth` |

## AutoUpdatePolicy

| Message | Fix |
|---|---|
| `NoAutoUpdate=1` (ALERT) | Find the source: `gpresult /h report.html` (domain GPO) or local policy (`gpedit.msc` > Computer Configuration > Administrative Templates > Windows Components > Windows Update). Remove or set *Configure Automatic Updates* to *Enabled, option 4* |
| `AUOptions=2/3/5/7` (WARNING) | Updates need a person to act. If intentional (e.g. a kiosk with a maintenance window), document it. Otherwise set option 4 |

## PauseState

| Message | Fix |
|---|---|
| `Updates paused until <date>` | *Settings > Windows Update > Resume updates*. If a Group Policy pause (`PauseQualityUpdatesStartTime`), clear it in the GPO. Ask the user why it was paused, usually a bad update experience worth recording |

## DeferralPolicy

| Message | Fix |
|---|---|
| `quality updates deferred N days` | Security fixes arrive N days late. Keep ≤ 7 days unless there is a documented reason |
| `feature updates deferred N days` (>180) | Risk of running an OS version close to end of servicing. Check `OsSupport` |
| `pinned to <product> <version>` | `TargetReleaseVersion` holds the feature version. Make sure that version is still supported |

## UpdateSource

| Message | Fix |
|---|---|
| `UseWUServer=1 but no WUServer is set` | Broken WSUS policy: scans fail. Fix or remove the WSUS GPO |
| `WSUS server '<x>' is not in AllowedWsusServers` | Either add the server to `AllowedWsusServers` in the config, or investigate a rogue/leftover WSUS setting |
| `DoNotConnectToWindowsUpdateInternetLocations=1 without WSUS` | Machine has no update source. Remove the policy or configure WSUS |

## LastQualityUpdate

| Message | Fix |
|---|---|
| `N days ago` (> 35 / > 60) | Open *Settings > Windows Update* and *Check for updates*. Look for errors there and in `RecentFailures`. Check disk space (`Get-PSDrive C`), the pause and policy checks above, and connectivity. Run `Get-WindowsUpdateLog` for detail |
| `No successful quality update found` | New or rebuilt machine, or history cleared. Run updates and confirm on the next run |
| `(source: Get-HotFix, approximate)` | The Windows Update Agent couldn't be queried (common over WinRM). Run locally for exact data |

## RecentFailures

| Message | Fix |
|---|---|
| `KBxxxxxxx (0x800f0922)` etc. | Search the HRESULT. Common ones: `0x80070643` (install failure: often .NET or WinRE partition size), `0x800f0922` (system reserved partition full, or VPN blocking), `0x80070002` (missing files: run `DISM /Online /Cleanup-Image /RestoreHealth` then `sfc /scannow`), `0x8024402c` (proxy/connectivity). Retry the install, then re-check |
| `Failure history unavailable` | See the `Get-HotFix` note above |

## PendingReboot

| Message | Fix |
|---|---|
| `Reboot pending ...; last boot N days ago` | Schedule a restart with the user. Updates are not active until reboot. ALERT after 7 days of uptime with a pending reboot |

## OsSupport

| Message | Fix |
|---|---|
| `reached end of servicing` (ALERT) | No more security updates. Plan a feature update (e.g. Windows 11 24H2 → 25H2) or hardware replacement. Windows 10 22H2 machines on paid ESU: extend the `19045` dates in `OsLifecycle` |
| `reaches end of servicing in N days` (WARNING) | Schedule the feature update before the date |
| `not in the OsLifecycle table` | New build released after the table was written. Add it from <https://learn.microsoft.com/lifecycle> to `config.json` |

## Connectivity (remote mode)

| Message | Fix |
|---|---|
| `Could not collect data: ...` | Machine off, WinRM disabled (`Enable-PSRemoting`), firewall, or credentials. Prefer the local scheduled task model |

## Monitor (exit code 3)

| Message | Fix |
|---|---|
| `WUMonitor failed to run: Invalid configuration: ...` | Fix the listed keys in `C:\ProgramData\WUMonitor\config.json`, then run `Invoke-WUMonitor.ps1 -DryRun` |
| Any other exception | Check the log file. If the module couldn't load, see `%TEMP%\WUMonitor_fatal.log` (for SYSTEM: `C:\Windows\Temp`) |

## Webhook delivery (event 1004)

Reports are kept in `C:\ProgramData\WUMonitor\Outbox` and re-sent automatically on the next run. Check the URL (HTTP 4xx means the URL or format is wrong, and it is not retried), proxy and firewall. To re-send immediately, run the scheduled task manually.
