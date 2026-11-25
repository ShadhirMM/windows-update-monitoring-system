#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# End-to-end tests against the real machine. Read-only: they run the monitor and compare the
# system state before and after. The webhook endpoint is a local HTTP listener (no internet).
# Each run is a separate powershell.exe process, exactly as Task Scheduler would start it.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $EntryScript = Join-Path $repoRoot 'src/Invoke-WUMonitor.ps1'
    $HostExe = (Get-Process -Id $PID).Path   # powershell.exe or pwsh.exe, matching the test host
    Import-Module (Join-Path $repoRoot 'src/WUMonitor/WUMonitor.psd1') -Force

    function Get-FreePort {
        $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $tcp.Start(); $port = $tcp.LocalEndpoint.Port; $tcp.Stop()
        return $port
    }

    function Start-TestWebhook([int] $Port, [int] $StatusCode = 204) {
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:$Port/")
        $listener.Start()
        $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $ps = [powershell]::Create()
        $null = $ps.AddScript({
                param($l, $q, $code)
                while ($l.IsListening) {
                    try { $context = $l.GetContext() } catch { break }
                    $reader = New-Object System.IO.StreamReader($context.Request.InputStream, [System.Text.Encoding]::UTF8)
                    $q.Enqueue($reader.ReadToEnd())
                    $context.Response.StatusCode = $code
                    $context.Response.Close()
                }
            }).AddArgument($listener).AddArgument($queue).AddArgument($StatusCode)
        $null = $ps.BeginInvoke()
        [pscustomobject]@{ Listener = $listener; Queue = $queue; PowerShell = $ps; Url = "http://localhost:$Port/hook/SecretToken" }
    }

    function Stop-TestWebhook($Hook) {
        $Hook.Listener.Stop(); $Hook.Listener.Close()
        $Hook.PowerShell.Dispose()
    }

    function Get-ReceivedPayload($Hook) {
        $items = @(); $item = $null
        while ($Hook.Queue.TryDequeue([ref]$item)) { $items += ($item | ConvertFrom-Json) }
        return , $items
    }

    function New-RunConfig([string] $Url, [int] $RetryCount = 1) {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        $config = Get-Content (Join-Path $repoRoot 'config/config.example.json') -Raw | ConvertFrom-Json
        $config.Webhook.Url = $Url
        $config.Webhook.RetryCount = $RetryCount
        $config.Webhook.TimeoutSeconds = 5
        $config.Logging.Path = Join-Path $dir 'Logs'
        $config.Logging.EventLog = $false
        $config.Outbox.Path = Join-Path $dir 'Outbox'
        $path = Join-Path $dir 'config.json'
        Set-Content -LiteralPath $path -Value ($config | ConvertTo-Json -Depth 10) -Encoding UTF8
        [pscustomobject]@{ Path = $path; Dir = $dir; Logs = $config.Logging.Path; Outbox = $config.Outbox.Path }
    }

    function Invoke-Monitor([string[]] $Arguments) {
        # In Windows PowerShell 5.1, stderr from a native process becomes an ErrorRecord; with an
        # inherited 'Stop' preference that would abort the test, so collect it instead.
        $ErrorActionPreference = 'Continue'
        $output = & $HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $EntryScript @Arguments 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }

    function Get-SystemSnapshot {
        # Everything the monitor reads and that a misbehaving script could change.
        $keys = @(
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
            'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        )
        $registry = foreach ($key in $keys) {
            if (Test-Path $key) {
                $item = Get-ItemProperty -LiteralPath $key
                $item.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { '{0}|{1}={2}' -f $key, $_.Name, $_.Value }
            }
            else { "$key|<missing>" }
        }
        # StartType only: the Windows Update Agent API can trigger-start wuauserv on demand,
        # which is normal Windows behaviour (the same happens when opening Settings > Windows Update).
        $services = Get-Service wuauserv, UsoSvc, WaaSMedicSvc -ErrorAction SilentlyContinue | ForEach-Object { '{0}={1}' -f $_.Name, $_.StartType }
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object TaskName -like '*WUMonitor*').Count
        return (@($registry) + @($services) + "WUMonitorTasks=$tasks") -join "`n"
    }
}

Describe 'Live collection on this machine' -Tag 'Integration' {
    It 'collects every section without errors' {
        $raw = Get-WURawState
        $raw.ComputerName | Should -Be $env:COMPUTERNAME
        $raw.Os | Should -Not -BeNullOrEmpty
        $raw.Os.Build | Should -BeGreaterThan 10000
        @($raw.Services).Count | Should -Be 3
        $raw.Policy | Should -Not -BeNullOrEmpty
        $raw.Pause | Should -Not -BeNullOrEmpty
        $raw.Reboot | Should -Not -BeNullOrEmpty
        $raw.History | Should -Not -BeNullOrEmpty
        $raw.CollectorErrors | Should -BeNullOrEmpty
    }
}

Describe 'End-to-end runs' -Tag 'Integration' {
    BeforeAll {
        $Port = Get-FreePort
        $Hook = Start-TestWebhook -Port $Port
    }
    AfterAll { Stop-TestWebhook $Hook }

    It 'leaves Windows Update settings, services and scheduled tasks unchanged (read-only proof)' {
        $before = Get-SystemSnapshot
        $config = New-RunConfig -Url $Hook.Url
        $run = Invoke-Monitor @('-ConfigPath', $config.Path)
        $after = Get-SystemSnapshot
        $run.ExitCode | Should -BeIn @(0, 1, 2)
        $after | Should -BeExactly $before
        $null = Get-ReceivedPayload $Hook
    }

    It 'delivers a valid report to the webhook and exits with the status code' {
        $config = New-RunConfig -Url $Hook.Url
        $run = Invoke-Monitor @('-ConfigPath', $config.Path)
        $payloads = Get-ReceivedPayload $Hook
        $payloads.Count | Should -Be 1
        $payloads[0].source | Should -Be 'WUMonitor'
        $payloads[0].host | Should -Be $env:COMPUTERNAME
        @($payloads[0].checks).Count | Should -Be 9
        $expected = @{ OK = 0; WARNING = 1; ALERT = 2 }[$payloads[0].status]
        $run.ExitCode | Should -Be $expected
        $log = Get-Content -Raw (Get-ChildItem $config.Logs -Filter 'WUMonitor_*.log').FullName
        $log | Should -Match 'Webhook delivered'
        $log | Should -Not -Match 'SecretToken'
    }

    It 'sends nothing in -DryRun mode but prints the payload' {
        $config = New-RunConfig -Url $Hook.Url
        $run = Invoke-Monitor @('-ConfigPath', $config.Path, '-DryRun')
        (Get-ReceivedPayload $Hook).Count | Should -Be 0
        $run.Output | Should -Match '"source":"WUMonitor"'
        $run.ExitCode | Should -BeIn @(0, 1, 2)
    }

    It 'queues the report while the webhook is down and delivers it on the next run' {
        $downPort = Get-FreePort
        $config = New-RunConfig -Url "http://localhost:$downPort/hook" -RetryCount 0
        $first = Invoke-Monitor @('-ConfigPath', $config.Path)
        $first.ExitCode | Should -BeIn @(0, 1, 2) -Because 'a delivery failure must not hide the monitoring status'
        @(Get-ChildItem $config.Outbox -Filter *.json).Count | Should -Be 1

        # Endpoint "comes back": point the same config at the live listener.
        $json = Get-Content $config.Path -Raw | ConvertFrom-Json
        $json.Webhook.Url = $Hook.Url
        Set-Content -LiteralPath $config.Path -Value ($json | ConvertTo-Json -Depth 10) -Encoding UTF8
        $second = Invoke-Monitor @('-ConfigPath', $config.Path)
        $second.ExitCode | Should -BeIn @(0, 1, 2)
        (Get-ReceivedPayload $Hook).Count | Should -Be 2 -Because 'the queued report plus the current one'
        @(Get-ChildItem $config.Outbox -Filter *.json).Count | Should -Be 0
    }

    It 'exits with code 3 and sends an ALERT when the monitor itself fails (invalid config)' {
        $bad = Join-Path $TestDrive 'bad-config.json'
        Set-Content -LiteralPath $bad -Value '{ "Webhook": { "Format": "carrier-pigeon" } }' -Encoding UTF8
        $saved = $env:WUMONITOR_WEBHOOK_URL
        try {
            $env:WUMONITOR_WEBHOOK_URL = $Hook.Url   # inherited by the child process
            $run = Invoke-Monitor @('-ConfigPath', $bad)
        }
        finally { $env:WUMONITOR_WEBHOOK_URL = $saved }
        $run.ExitCode | Should -Be 3
        $payloads = Get-ReceivedPayload $Hook
        $payloads.Count | Should -Be 1
        $payloads[0].status | Should -Be 'ALERT'
        $payloads[0].checks[0].name | Should -Be 'Monitor'
        $payloads[0].checks[0].message | Should -Match 'Webhook.Format'
    }
}
