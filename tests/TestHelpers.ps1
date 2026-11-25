# Shared fixtures for the Pester tests. Dot-source inside BeforeAll.

$TestNow = [datetime]::new(2026, 11, 25, 12, 0, 0, [System.DateTimeKind]::Utc)

function Invoke-WUInternal {
    # Calls a private (non-exported) module function inside the module's scope.
    param(
        [Parameter(Mandatory)] [string] $Command,
        [hashtable] $Parameters = @{}
    )
    & (Get-Module -Name WUMonitor) { param($c, $p) & $c @p } $Command $Parameters
}

function New-TestService {
    param([string] $Name, [string] $StartType = 'Manual', [bool] $Exists = $true)
    if (-not $Exists) { return [pscustomobject]@{ Name = $Name; Exists = $false; Status = $null; StartType = $null } }
    [pscustomobject]@{ Name = $Name; Exists = $true; Status = 'Running'; StartType = $StartType }
}

function New-TestUpdate {
    param([string] $Title = '2026-11 Security Update (KB5000001)', [datetime] $Date, [int] $ResultCode = 2, [string] $HResult = '0x00000000')
    $kb = $null
    if ($Title -match 'KB\d+') { $kb = $Matches[0] }
    [pscustomobject]@{ Title = $Title; KB = $kb; Date = $Date; ResultCode = $ResultCode; HResult = $HResult }
}

function New-TestRawState {
    # A healthy machine: every check should return OK against the default config at $TestNow.
    param([datetime] $Now = [datetime]::new(2026, 11, 25, 12, 0, 0, [System.DateTimeKind]::Utc))
    $lastUpdate = New-TestUpdate -Date $Now.AddDays(-10)
    [pscustomobject]@{
        ComputerName    = 'TESTPC'
        CollectedAtUtc  = $Now
        Os              = [pscustomobject]@{
            Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.26200'; Build = 26200; UBR = 7171
            DisplayVersion = '25H2'; EditionID = 'Professional'; ProductType = 1; LastBootUpTime = $Now.AddDays(-2)
        }
        Services        = @(
            New-TestService -Name 'wuauserv' -StartType 'Manual'
            New-TestService -Name 'UsoSvc' -StartType 'Automatic'
            New-TestService -Name 'WaaSMedicSvc' -StartType 'Manual'
        )
        Policy          = [pscustomobject]@{}
        Pause           = [pscustomobject]@{}
        Reboot          = [pscustomobject]@{ WindowsUpdate = $false; ComponentBasedService = $false }
        History         = [pscustomobject]@{
            Source            = 'WindowsUpdateAgent'
            EntriesScanned    = 50
            LastQualityUpdate = $lastUpdate
            LastAnyUpdate     = $lastUpdate
            Failures          = @()
        }
        CollectorErrors = @()
    }
}
