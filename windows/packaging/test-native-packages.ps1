param([Parameter(Mandatory)][string]$Msi,[Parameter(Mandatory)][string]$Output,[string]$UpgradeMsi,[switch]$IsolatedRunner)
$ErrorActionPreference = 'Stop'
if (-not $IsolatedRunner -or $env:GITHUB_ACTIONS -ne 'true') { throw 'Destructive install tests require an explicitly isolated GitHub runner' }
$directory=[IO.Path]::GetFullPath($Output);New-Item -ItemType Directory -Force $directory | Out-Null
$desktop='HKCU:\Control Panel\Desktop'
$before=Get-ItemProperty $desktop
$keys=@('SCRNSAVE.EXE','ScreenSaveActive','ScreenSaveTimeOut','ScreenSaverIsSecure')
$backup=@{}
foreach($key in $keys){$backup[$key]=$before.$key}
function Invoke-Msi([string[]]$arguments) {
    $process=Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru
    if($process.ExitCode -notin @(0,3010)){throw "MSI failed ($($process.ExitCode)); inspect isolated MSI log"}
}
$installed=Join-Path $env:LOCALAPPDATA 'Programs\PickleballScreensaver'
$saver=Join-Path $installed 'PickleballScreensaver.scr'
try {
    Invoke-Msi @('/i',"`"$([IO.Path]::GetFullPath($Msi))`"",'/qn','/l*v',"`"$(Join-Path $directory 'install.log')`"")
    if(-not(Test-Path -LiteralPath $saver)){throw 'Current-user stable saver path missing'}
    foreach($key in $keys){if((Get-ItemProperty $desktop).$key -ne $backup[$key]){throw "Install changed protected $key"}}
    Set-Content -LiteralPath (Join-Path $installed 'unowned-sentinel.txt') 'Must survive uninstall'
    Invoke-Msi @('/fa',"`"$([IO.Path]::GetFullPath($Msi))`"",'/qn','/l*v',"`"$(Join-Path $directory 'repair.log')`"")
    if(-not(Test-Path -LiteralPath $saver)){throw 'Repair failed'}
    $uninstallMsi=$Msi
    if($UpgradeMsi) {
        Set-ItemProperty $desktop 'SCRNSAVE.EXE' $saver
        Invoke-Msi @('/i',"`"$([IO.Path]::GetFullPath($UpgradeMsi))`"",'/qn','/l*v',"`"$(Join-Path $directory 'upgrade.log')`"")
        if(-not(Test-Path -LiteralPath $saver)){throw 'Upgrade lost stable saver'}
        if((Get-ItemPropertyValue $desktop 'SCRNSAVE.EXE') -ne $saver){throw 'Upgrade cleared owned selection'}
        $uninstallMsi=$UpgradeMsi
    }
    Set-ItemProperty $desktop 'SCRNSAVE.EXE' 'C:\UnrelatedScreensaver.scr'
    Invoke-Msi @('/x',"`"$([IO.Path]::GetFullPath($uninstallMsi))`"",'/qn','/l*v',"`"$(Join-Path $directory 'uninstall-alternative.log')`"")
    if((Get-ItemPropertyValue $desktop 'SCRNSAVE.EXE') -ne 'C:\UnrelatedScreensaver.scr'){throw 'Uninstall stomped alternative selection'}
    if(Test-Path -LiteralPath $saver){throw 'Uninstall left owned saver'}
    if(-not(Test-Path -LiteralPath (Join-Path $installed 'unowned-sentinel.txt'))){throw 'Uninstall deleted an unowned file'}
    Invoke-Msi @('/i',"`"$([IO.Path]::GetFullPath($Msi))`"",'/qn','/l*v',"`"$(Join-Path $directory 'reinstall.log')`"")
    Set-ItemProperty $desktop 'SCRNSAVE.EXE' $saver
    Invoke-Msi @('/x',"`"$([IO.Path]::GetFullPath($Msi))`"",'/qn','/l*v',"`"$(Join-Path $directory 'uninstall-owned.log')`"")
    if((Get-ItemProperty $desktop).'SCRNSAVE.EXE' -eq $saver){throw 'Owned selection left dangling'}
    Write-Host 'PASS: current-user install/repair/uninstall, no automatic selection or policy changes, alternative and unowned file preserved.'
} finally {
    foreach($key in $keys) {
        if($null -eq $backup[$key]){Remove-ItemProperty $desktop $key -ErrorAction SilentlyContinue}
        else{Set-ItemProperty $desktop $key $backup[$key]}
    }
    Remove-Item -LiteralPath (Join-Path $installed 'unowned-sentinel.txt') -ErrorAction SilentlyContinue
}
