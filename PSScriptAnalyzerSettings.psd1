@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @()
    Rules        = @{
        # The tool must run on the Windows PowerShell 5.1 that ships with Windows and on PowerShell 7.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSUseCompatibleCmdlets = @{
            Compatibility = @('desktop-5.1.14393.206-windows')
        }
    }
}
