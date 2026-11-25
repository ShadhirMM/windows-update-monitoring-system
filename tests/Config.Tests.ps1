#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src/WUMonitor/WUMonitor.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $ExampleConfig = Join-Path $repoRoot 'config/config.example.json'

    function New-ConfigFile([string] $Json) {
        $path = Join-Path $TestDrive ('config_{0}.json' -f ([guid]::NewGuid().ToString('N')))
        Set-Content -LiteralPath $path -Value $Json -Encoding UTF8
        return $path
    }
}

Describe 'Get-WUMonitorConfig' {
    BeforeEach { $savedUrl = $env:WUMONITOR_WEBHOOK_URL; $env:WUMONITOR_WEBHOOK_URL = $null }
    AfterEach { $env:WUMONITOR_WEBHOOK_URL = $savedUrl }

    It 'returns valid built-in defaults when no file is given' {
        $config = Get-WUMonitorConfig
        $config.Webhook.Format | Should -Be 'generic'
        $config.Thresholds.LastUpdateAlertDays | Should -Be 60
        @($config.OsLifecycle).Count | Should -BeGreaterThan 5
    }
    It 'loads the shipped config.example.json' {
        { Get-WUMonitorConfig -Path $ExampleConfig } | Should -Not -Throw
    }
    It 'config.example.json thresholds match the built-in defaults' {
        $example = Get-WUMonitorConfig -Path $ExampleConfig
        $defaults = Get-WUDefaultConfig
        foreach ($key in $defaults.Thresholds.Keys) {
            [int]$example.Thresholds[$key] | Should -Be $defaults.Thresholds[$key] -Because "threshold $key"
        }
        @($example.OsLifecycle).Count | Should -Be @($defaults.OsLifecycle).Count
    }
    It 'merges a partial file over the defaults' {
        $path = New-ConfigFile '{ "Thresholds": { "LastUpdateWarnDays": 20 }, "Webhook": { "Format": "discord" } }'
        $config = Get-WUMonitorConfig -Path $path
        $config.Thresholds.LastUpdateWarnDays | Should -Be 20
        $config.Thresholds.LastUpdateAlertDays | Should -Be 60
        $config.Webhook.Format | Should -Be 'discord'
        $config.Webhook.RetryCount | Should -Be 3
    }
    It 'ignores documentation keys that start with an underscore' {
        $path = New-ConfigFile '{ "_comment": "hello", "Webhook": { "_note": "x", "Format": "slack" } }'
        $config = Get-WUMonitorConfig -Path $path
        $config.ContainsKey('_comment') | Should -BeFalse
        $config.Webhook.ContainsKey('_note') | Should -BeFalse
    }
    It 'keeps single-item and empty arrays as arrays' {
        $path = New-ConfigFile '{ "AllowedWsusServers": ["wsus01"], "Computers": [] }'
        $config = Get-WUMonitorConfig -Path $path
        , $config.AllowedWsusServers | Should -BeOfType [object[]]
        $config.AllowedWsusServers[0] | Should -Be 'wsus01'
        @($config.Computers).Count | Should -Be 0
    }
    It 'lets WUMONITOR_WEBHOOK_URL override the file' {
        $env:WUMONITOR_WEBHOOK_URL = 'https://example.invalid/hook/secret'
        (Get-WUMonitorConfig -Path $ExampleConfig).Webhook.Url | Should -Be 'https://example.invalid/hook/secret'
    }
    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an unknown webhook format'; Json = '{ "Webhook": { "Format": "email" } }'; Pattern = 'Webhook.Format' }
        @{ Case = 'an unknown SendOn value'; Json = '{ "Webhook": { "SendOn": "Sometimes" } }'; Pattern = 'Webhook.SendOn' }
        @{ Case = 'a non-http URL'; Json = '{ "Webhook": { "Url": "ftp://x" } }'; Pattern = 'Webhook.Url' }
        @{ Case = 'warn >= alert'; Json = '{ "Thresholds": { "LastUpdateWarnDays": 60, "LastUpdateAlertDays": 30 } }'; Pattern = 'must be lower' }
        @{ Case = 'a non-numeric threshold'; Json = '{ "Thresholds": { "RebootAlertDays": "soon" } }'; Pattern = 'RebootAlertDays' }
        @{ Case = 'an invalid regex'; Json = '{ "History": { "ExcludePattern": "([unclosed" } }'; Pattern = 'regular expression' }
        @{ Case = 'an invalid UnknownBuildStatus'; Json = '{ "UnknownBuildStatus": "MAYBE" }'; Pattern = 'UnknownBuildStatus' }
    ) {
        $path = New-ConfigFile $Json
        { Get-WUMonitorConfig -Path $path } | Should -Throw -ExpectedMessage "*$Pattern*"
    }
    It 'throws a clear error for a missing file' {
        { Get-WUMonitorConfig -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw -ExpectedMessage 'Config file not found*'
    }
    It 'throws a clear error for invalid JSON' {
        $path = New-ConfigFile '{ "Webhook": '
        { Get-WUMonitorConfig -Path $path } | Should -Throw -ExpectedMessage '*is not valid JSON*'
    }
}

Describe 'ConvertTo-WUInt' {
    It 'converts <Value> to <Expected>' -ForEach @(
        @{ Value = $null; Expected = $null }
        @{ Value = ''; Expected = $null }
        @{ Value = 'abc'; Expected = $null }
        @{ Value = 0; Expected = 0 }
        @{ Value = 4; Expected = 4 }
        @{ Value = '7'; Expected = 7 }
        @{ Value = [long]30; Expected = 30 }
    ) {
        Invoke-WUInternal ConvertTo-WUInt @{ Value = $Value } | Should -Be $Expected
    }
}

Describe 'ConvertTo-WUDateTimeUtc' {
    It 'parses registry ISO strings as UTC' {
        $result = Invoke-WUInternal ConvertTo-WUDateTimeUtc @{ Value = '2026-05-15T12:26:40Z' }
        $result.Kind | Should -Be 'Utc'
        $result.Hour | Should -Be 12
    }
    It 'returns $null for <Value>' -ForEach @(@{ Value = $null }, @{ Value = '' }, @{ Value = 'garbage' }) {
        Invoke-WUInternal ConvertTo-WUDateTimeUtc @{ Value = $Value } | Should -BeNullOrEmpty
    }
}
