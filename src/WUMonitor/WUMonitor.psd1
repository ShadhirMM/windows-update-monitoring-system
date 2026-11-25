@{
    RootModule           = 'WUMonitor.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'b7d3c2a4-5e61-4f0a-9c8e-2f4d6a1b3e57'
    Author               = 'Mushaff Shadhir'
    Copyright            = '(c) 2026 Mushaff Shadhir. MIT License.'
    Description          = 'Read-only Windows Update configuration monitor. Checks update policy, service state, pauses, deferrals, update history, pending reboots and OS servicing status, then reports OK / WARNING / ALERT to a webhook.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Get-WUDefaultConfig'
        'Get-WUMonitorConfig'
        'Get-WURawState'
        'Get-WUCheckResult'
        'New-WUReport'
        'ConvertTo-WUWebhookPayload'
        'Send-WUWebhook'
        'Send-WUOutbox'
        'Invoke-WUMonitorRun'
        'Get-WUExitCode'
        'Send-WUFailureNotice'
        'Initialize-WULog'
        'Write-WULog'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('WindowsUpdate', 'Monitoring', 'Webhook', 'Compliance', 'ReadOnly')
        }
    }
}
