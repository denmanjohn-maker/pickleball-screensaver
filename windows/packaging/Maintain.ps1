param(
    [ValidateSet('Select','Uninstall','Classic','Blacklight','Configure')][string]$Action = 'Configure',
    [string]$Saver = (Join-Path $PSScriptRoot 'PickleballScreensaver.scr')
)
$ErrorActionPreference = 'Stop'
$desktop = 'HKCU:\Control Panel\Desktop'
$owned = [IO.Path]::GetFullPath($Saver)
switch ($Action) {
    'Uninstall' {
        $current = Get-ItemPropertyValue $desktop 'SCRNSAVE.EXE' -ErrorAction SilentlyContinue
        if ($current -and [string]::Equals([IO.Path]::GetFullPath($current.Trim('"')), $owned, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-ItemProperty $desktop 'SCRNSAVE.EXE'
        }
        # Never change activation, idle timeout, password protection or another selected saver.
    }
    'Select' {
        if (-not (Test-Path -LiteralPath $owned)) { throw 'Installed screensaver unavailable' }
        Add-Type -AssemblyName PresentationFramework
        $answer = [Windows.MessageBox]::Show('Select Pickleball as your screensaver? Idle timeout, activation, sleep and password policies will not be changed.', 'Pickleball — explicit selection', 'YesNo')
        if ($answer -eq 'Yes') { Set-ItemProperty $desktop 'SCRNSAVE.EXE' ('"' + $owned + '"') }
    }
    'Configure' { Start-Process -FilePath $owned -ArgumentList '/c' }
    'Classic' { Start-Process -FilePath (Join-Path $PSScriptRoot 'Pickleball-Classic.deskthemepack') }
    'Blacklight' { Start-Process -FilePath (Join-Path $PSScriptRoot 'Pickleball-BlackLight.deskthemepack') }
}
