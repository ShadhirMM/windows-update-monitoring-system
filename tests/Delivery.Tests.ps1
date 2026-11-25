#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Webhook delivery, retry/backoff, secret masking, outbox and log retention. Network calls are mocked.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src/WUMonitor/WUMonitor.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    if (-not ('WUTestHttpException' -as [type])) {
        Add-Type -TypeDefinition @'
public class WUTestHttpResponse {
    public WUTestHttpResponse(int code) { StatusCode = code; }
    public int StatusCode { get; private set; }
}
public class WUTestHttpException : System.Exception {
    public WUTestHttpException(string message, int code) : base(message) { Response = new WUTestHttpResponse(code); }
    public WUTestHttpResponse Response { get; private set; }
}
'@
    }
    $SecretUrl = 'https://hooks.example.invalid/services/T000/B000/SuperSecretToken123'
}

Describe 'Send-WUWebhook' {
    BeforeEach {
        $null = Initialize-WULog -Path (Join-Path $TestDrive 'logs')
        Mock -ModuleName WUMonitor Start-Sleep { }
    }

    It 'returns $true and posts once when the endpoint accepts the request' {
        Mock -ModuleName WUMonitor Invoke-RestMethod { }
        Send-WUWebhook -Url $SecretUrl -Body '{"a":1}' | Should -BeTrue
        Should -Invoke -ModuleName WUMonitor Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $ContentType -like 'application/json*' -and $Uri -eq $SecretUrl
        }
    }
    It 'sends the body as UTF-8 bytes' {
        Mock -ModuleName WUMonitor Invoke-RestMethod { }
        $text = '{"m":"caf' + [char]0x00E9 + '"}'
        $null = Send-WUWebhook -Url $SecretUrl -Body $text
        Should -Invoke -ModuleName WUMonitor Invoke-RestMethod -ParameterFilter {
            [System.Text.Encoding]::UTF8.GetString([byte[]]$Body) -eq $text
        }
    }
    It 'retries with exponential backoff and succeeds on the third attempt' {
        $script:calls = 0
        Mock -ModuleName WUMonitor Invoke-RestMethod {
            $script:calls++
            if ($script:calls -lt 3) { throw [WUTestHttpException]::new('Service Unavailable', 503) }
        }
        Send-WUWebhook -Url $SecretUrl -Body '{}' -RetryCount 3 | Should -BeTrue
        Should -Invoke -ModuleName WUMonitor Invoke-RestMethod -Times 3 -Exactly
        Should -Invoke -ModuleName WUMonitor Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
        Should -Invoke -ModuleName WUMonitor Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 4 }
    }
    It 'gives up after RetryCount + 1 attempts and returns $false' {
        Mock -ModuleName WUMonitor Invoke-RestMethod { throw [System.Net.WebException]::new('Unable to connect to the remote server') }
        Send-WUWebhook -Url $SecretUrl -Body '{}' -RetryCount 2 | Should -BeFalse
        Should -Invoke -ModuleName WUMonitor Invoke-RestMethod -Times 3 -Exactly
        Should -Invoke -ModuleName WUMonitor Start-Sleep -Times 2 -Exactly
    }
    It 'does not retry a client error (HTTP <Code>)' -ForEach @(@{ Code = 400 }, @{ Code = 401 }, @{ Code = 404 }) {
        Mock -ModuleName WUMonitor Invoke-RestMethod { throw [WUTestHttpException]::new('Client error', $Code) }
        Send-WUWebhook -Url $SecretUrl -Body '{}' -RetryCount 3 | Should -BeFalse
        Should -Invoke -ModuleName WUMonitor Invoke-RestMethod -Times 1 -Exactly
    }
    It 'does retry HTTP 429 (rate limited)' {
        Mock -ModuleName WUMonitor Invoke-RestMethod { throw [WUTestHttpException]::new('Too Many Requests', 429) }
        Send-WUWebhook -Url $SecretUrl -Body '{}' -RetryCount 1 | Should -BeFalse
        Should -Invoke -ModuleName WUMonitor Invoke-RestMethod -Times 2 -Exactly
    }
    It 'never writes the secret part of the webhook URL to the log' {
        Mock -ModuleName WUMonitor Invoke-RestMethod { throw [WUTestHttpException]::new('Bad Request', 400) }
        $null = Send-WUWebhook -Url $SecretUrl -Body '{}'
        $log = Get-Content -Raw -LiteralPath (Get-ChildItem (Join-Path $TestDrive 'logs') -Filter *.log | Select-Object -First 1).FullName
        $log | Should -Match 'hooks.example.invalid'
        $log | Should -Not -Match 'SuperSecretToken123'
    }
}

Describe 'Outbox' {
    BeforeEach {
        $null = Initialize-WULog -Path (Join-Path $TestDrive 'logs')
        $OutboxPath = Join-Path $TestDrive ('outbox_' + [guid]::NewGuid().ToString('N'))
        $Config = Get-WUDefaultConfig
        $Config.Webhook.Url = $SecretUrl
        $Config.Outbox.Path = $OutboxPath
        Mock -ModuleName WUMonitor Start-Sleep { }
    }

    It 'saves an undelivered report and delivers it on the next run' {
        $file = Invoke-WUInternal Save-WUOutboxItem @{ Path = $OutboxPath; ComputerName = 'PC1'; Body = '{"queued":true}' }
        Test-Path $file | Should -BeTrue

        Mock -ModuleName WUMonitor Invoke-RestMethod { }
        Send-WUOutbox -Config $Config
        Should -Invoke -ModuleName WUMonitor Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            [System.Text.Encoding]::UTF8.GetString([byte[]]$Body) -eq '{"queued":true}'
        }
        Test-Path $file | Should -BeFalse
    }
    It 'keeps items and stops at the first failure while the endpoint is down' {
        1..3 | ForEach-Object { $null = Invoke-WUInternal Save-WUOutboxItem @{ Path = $OutboxPath; ComputerName = "PC$_"; Body = '{}' } }
        Mock -ModuleName WUMonitor Invoke-RestMethod { throw [System.Net.WebException]::new('down') }
        Send-WUOutbox -Config $Config
        Should -Invoke -ModuleName WUMonitor Invoke-RestMethod -Times 1 -Exactly
        @(Get-ChildItem $OutboxPath -Filter *.json).Count | Should -Be 3
    }
    It 'drops items older than MaxAgeDays without sending them' {
        $file = Invoke-WUInternal Save-WUOutboxItem @{ Path = $OutboxPath; ComputerName = 'OLD'; Body = '{}' }
        (Get-Item $file).LastWriteTime = (Get-Date).AddDays(-40)
        Mock -ModuleName WUMonitor Invoke-RestMethod { }
        Send-WUOutbox -Config $Config
        Should -Invoke -ModuleName WUMonitor Invoke-RestMethod -Times 0 -Exactly
        Test-Path $file | Should -BeFalse
    }
}

Describe 'Invoke-WUMonitorRun delivery decisions' {
    BeforeEach {
        $Config = Get-WUDefaultConfig
        $Config.Logging.Path = Join-Path $TestDrive 'runlogs'
        $Config.Logging.EventLog = $false
        $Config.Outbox.Path = Join-Path $TestDrive ('outbox_' + [guid]::NewGuid().ToString('N'))
        $Config.Webhook.Url = $SecretUrl
        Mock -ModuleName WUMonitor Get-WURawState { New-TestRawState -Now (Get-Date).ToUniversalTime() }
        Mock -ModuleName WUMonitor Start-Sleep { }
    }

    It 'sends the report when the webhook is up (Delivery = Sent)' {
        Mock -ModuleName WUMonitor Invoke-RestMethod { }
        $result = Invoke-WUMonitorRun -Config $Config
        $result.Delivery | Should -Be 'Sent'
        $result.Report.Status | Should -Be 'OK'
    }
    It 'queues the report in the outbox when delivery fails (Delivery = Queued)' {
        Mock -ModuleName WUMonitor Invoke-RestMethod { throw [System.Net.WebException]::new('down') }
        $result = Invoke-WUMonitorRun -Config $Config
        $result.Delivery | Should -Be 'Queued'
        @(Get-ChildItem $Config.Outbox.Path -Filter *.json).Count | Should -Be 1
    }
    It 'does not send anything in dry-run mode' {
        Mock -ModuleName WUMonitor Invoke-RestMethod { }
        $result = Invoke-WUMonitorRun -Config $Config -DryRun
        $result.Delivery | Should -Be 'DryRun'
        $result.Payload | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName WUMonitor Invoke-RestMethod -Times 0 -Exactly
    }
    It 'skips sending OK reports when SendOn = WarningOrAbove' {
        $Config.Webhook.SendOn = 'WarningOrAbove'
        Mock -ModuleName WUMonitor Invoke-RestMethod { }
        (Invoke-WUMonitorRun -Config $Config).Delivery | Should -Be 'Skipped'
        Should -Invoke -ModuleName WUMonitor Invoke-RestMethod -Times 0 -Exactly
    }
    It 'reports NotConfigured when there is no webhook URL' {
        $Config.Webhook.Url = ''
        (Invoke-WUMonitorRun -Config $Config).Delivery | Should -Be 'NotConfigured'
    }
    It 'reports an unreachable remote computer as WARNING instead of failing the run' {
        Mock -ModuleName WUMonitor Invoke-Command { throw 'WinRM cannot complete the operation' }
        Mock -ModuleName WUMonitor Invoke-RestMethod { }
        $result = Invoke-WUMonitorRun -Config $Config -ComputerName 'OFFLINE-PC-01'
        $result.Report.ComputerName | Should -Be 'OFFLINE-PC-01'
        $result.Report.Status | Should -Be 'WARNING'
        $result.Report.Checks[0].Name | Should -Be 'Connectivity'
    }
}

Describe 'Log retention' {
    It 'deletes only WUMonitor logs older than RetentionDays' {
        $dir = Join-Path $TestDrive 'retention'
        $null = Initialize-WULog -Path $dir
        $old = Join-Path $dir 'WUMonitor_20200101.log'
        $other = Join-Path $dir 'unrelated.log'
        Set-Content $old 'old'; Set-Content $other 'keep'
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-45)
        (Get-Item $other).LastWriteTime = (Get-Date).AddDays(-45)
        Invoke-WUInternal Remove-WUOldLog @{ RetentionDays = 30 }
        Test-Path $old | Should -BeFalse
        Test-Path $other | Should -BeTrue
    }
    It 'falls back to the temp folder when the configured log path is not writable' {
        $blocker = Join-Path $TestDrive 'iamafile'
        Set-Content $blocker 'x'
        $file = Initialize-WULog -Path (Join-Path $blocker 'logs')
        $file | Should -BeLike ((Join-Path ([System.IO.Path]::GetTempPath()) 'WUMonitor\Logs') + '*')
    }
}
