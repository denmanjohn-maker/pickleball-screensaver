param(
    [Parameter(Mandatory)][ValidateSet('win-x64','win-arm64')][string]$Rid,
    [Parameter(Mandatory)][string]$Payload,
    [Parameter(Mandatory)][string]$Themes,
    [Parameter(Mandatory)][string]$Output,
    [string]$Version = '1.5.0'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$payloadPath = [IO.Path]::GetFullPath($Payload)
$outputPath = [IO.Path]::GetFullPath($Output)
foreach ($path in @($payloadPath,$outputPath,[IO.Path]::GetFullPath($Themes))) {
    if (-not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'All paths must be inside windows/' }
}
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne $(if($Rid -eq 'win-arm64'){'Arm64'}else{'X64'})) { throw 'Build MSI on its native OS architecture' }
New-Item -ItemType Directory -Force $outputPath | Out-Null
foreach ($theme in @('Pickleball-Classic.deskthemepack','Pickleball-BlackLight.deskthemepack')) {
    Copy-Item -LiteralPath (Join-Path $Themes $theme) -Destination $payloadPath
}
$msi = Join-Path $outputPath "PickleballScreensaver-$Version-$Rid.msi"
if (Test-Path -LiteralPath $msi) { throw 'MSI already exists; use a fresh output directory' }
function Call($object,[string]$method,[object[]]$arguments) {
    $target = $object.PSObject.BaseObject
    $raw = [object[]]::new($arguments.Count)
    for($i=0;$i -lt $arguments.Count;$i++){if($null -ne $arguments[$i]){$raw[$i]=$arguments[$i].PSObject.BaseObject}}
    try { $target.GetType().InvokeMember($method,[Reflection.BindingFlags]::InvokeMethod,$null,$target,$raw) }
    catch { throw "Windows Installer method $method failed: $($_.Exception.Message) at $($_.ScriptStackTrace)" }
}
function Set-Com($object,[string]$property,[object[]]$arguments) {
    $target = $object.PSObject.BaseObject
    $raw = [object[]]::new($arguments.Count)
    for($i=0;$i -lt $arguments.Count;$i++){if($null -ne $arguments[$i]){$raw[$i]=$arguments[$i].PSObject.BaseObject}}
    try { $target.GetType().InvokeMember($property,[Reflection.BindingFlags]::SetProperty,$null,$target,$raw) | Out-Null }
    catch { throw "Windows Installer property $property failed: $($_.Exception.Message) at $($_.ScriptStackTrace)" }
}
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = Call $installer 'OpenDatabase' @($msi,3)
function Sql([string]$sql) {
    $view = Call $db 'OpenView' @($sql)
    try { Call $view 'Execute' @() | Out-Null } finally { Call $view 'Close' @() | Out-Null }
}
function Row([string]$table,[string[]]$columns,[object[]]$values) {
    $names = ($columns | ForEach-Object { '`' + $_ + '`' }) -join ','
    $parameters = (@('?') * $values.Count) -join ','
    $view = Call $db 'OpenView' @("INSERT INTO ``$table`` ($names) VALUES ($parameters)")
    $record = Call $installer 'CreateRecord' @($values.Count)
    for ($i=0;$i -lt $values.Count;$i++) {
        if ($null -eq $values[$i]) { continue }
        if ($values[$i] -is [int]) { Set-Com $record 'IntegerData' @(([int]($i+1)),$values[$i]) }
        else { Set-Com $record 'StringData' @(([int]($i+1)),[string]$values[$i]) }
    }
    try { Call $view 'Execute' @($record) | Out-Null } finally { Call $view 'Close' @() | Out-Null }
}
function Guid-For([string]$text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("Pickleball/$text")) }
    finally { $sha.Dispose() }
    $bytes[6] = ($bytes[6] -band 15) -bor 80; $bytes[8] = ($bytes[8] -band 63) -bor 128
    '{' + ([Guid]::new([byte[]]$bytes[0..15])).ToString().ToUpperInvariant() + '}'
}
$schemas = @(
    'CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(0) NOT NULL PRIMARY KEY `Property`)',
    'CREATE TABLE `Directory` (`Directory` CHAR(72) NOT NULL, `Directory_Parent` CHAR(72), `DefaultDir` CHAR(255) NOT NULL PRIMARY KEY `Directory`)',
    'CREATE TABLE `Component` (`Component` CHAR(72) NOT NULL, `ComponentId` CHAR(38), `Directory_` CHAR(72) NOT NULL, `Attributes` SHORT NOT NULL, `Condition` CHAR(255), `KeyPath` CHAR(72) PRIMARY KEY `Component`)',
    'CREATE TABLE `Feature` (`Feature` CHAR(38) NOT NULL, `Feature_Parent` CHAR(38), `Title` CHAR(64), `Description` CHAR(255), `Display` SHORT, `Level` SHORT NOT NULL, `Directory_` CHAR(72), `Attributes` SHORT NOT NULL PRIMARY KEY `Feature`)',
    'CREATE TABLE `FeatureComponents` (`Feature_` CHAR(38) NOT NULL, `Component_` CHAR(72) NOT NULL PRIMARY KEY `Feature_`, `Component_`)',
    'CREATE TABLE `File` (`File` CHAR(72) NOT NULL, `Component_` CHAR(72) NOT NULL, `FileName` CHAR(255) NOT NULL LOCALIZABLE, `FileSize` LONG NOT NULL, `Version` CHAR(72), `Language` CHAR(20), `Attributes` SHORT, `Sequence` LONG NOT NULL PRIMARY KEY `File`)',
    'CREATE TABLE `Media` (`DiskId` SHORT NOT NULL, `LastSequence` LONG NOT NULL, `DiskPrompt` CHAR(64) LOCALIZABLE, `Cabinet` CHAR(255), `VolumeLabel` CHAR(32), `Source` CHAR(72) PRIMARY KEY `DiskId`)',
    'CREATE TABLE `InstallExecuteSequence` (`Action` CHAR(72) NOT NULL, `Condition` CHAR(255), `Sequence` SHORT PRIMARY KEY `Action`)',
    'CREATE TABLE `InstallUISequence` (`Action` CHAR(72) NOT NULL, `Condition` CHAR(255), `Sequence` SHORT PRIMARY KEY `Action`)',
    'CREATE TABLE `CustomAction` (`Action` CHAR(72) NOT NULL, `Type` SHORT NOT NULL, `Source` CHAR(72), `Target` CHAR(255) PRIMARY KEY `Action`)',
    'CREATE TABLE `LaunchCondition` (`Condition` CHAR(255) NOT NULL, `Description` CHAR(255) NOT NULL LOCALIZABLE PRIMARY KEY `Condition`)',
    'CREATE TABLE `AppSearch` (`Property` CHAR(72) NOT NULL, `Signature_` CHAR(72) NOT NULL PRIMARY KEY `Property`, `Signature_`)',
    'CREATE TABLE `RegLocator` (`Signature_` CHAR(72) NOT NULL, `Root` SHORT NOT NULL, `Key` CHAR(255) NOT NULL, `Name` CHAR(255), `Type` SHORT PRIMARY KEY `Signature_`)',
    'CREATE TABLE `Signature` (`Signature` CHAR(72) NOT NULL, `FileName` CHAR(255) NOT NULL LOCALIZABLE, `MinVersion` CHAR(20), `MaxVersion` CHAR(20), `MinSize` LONG, `MaxSize` LONG, `MinDate` LONG, `MaxDate` LONG, `Languages` CHAR(255) PRIMARY KEY `Signature`)',
    'CREATE TABLE `Registry` (`Registry` CHAR(72) NOT NULL, `Root` SHORT NOT NULL, `Key` CHAR(255) NOT NULL LOCALIZABLE, `Name` CHAR(255) LOCALIZABLE, `Value` CHAR(0) LOCALIZABLE, `Component_` CHAR(72) NOT NULL PRIMARY KEY `Registry`)',
    'CREATE TABLE `Shortcut` (`Shortcut` CHAR(72) NOT NULL, `Directory_` CHAR(72) NOT NULL, `Name` CHAR(128) NOT NULL LOCALIZABLE, `Component_` CHAR(72) NOT NULL, `Target` CHAR(255) NOT NULL LOCALIZABLE, `Arguments` CHAR(255) LOCALIZABLE, `Description` CHAR(255) LOCALIZABLE, `Hotkey` SHORT, `Icon_` CHAR(72), `IconIndex` SHORT, `ShowCmd` SHORT, `WkDir` CHAR(72) PRIMARY KEY `Shortcut`)',
    'CREATE TABLE `Upgrade` (`UpgradeCode` CHAR(38) NOT NULL, `VersionMin` CHAR(20), `VersionMax` CHAR(20), `Language` CHAR(255), `Attributes` LONG NOT NULL, `Remove` CHAR(255), `ActionProperty` CHAR(72) NOT NULL PRIMARY KEY `UpgradeCode`,`VersionMin`,`VersionMax`,`Language`,`Attributes`)',
    'CREATE TABLE `RemoveFile` (`FileKey` CHAR(72) NOT NULL, `Component_` CHAR(72) NOT NULL, `FileName` CHAR(255) LOCALIZABLE, `DirProperty` CHAR(72) NOT NULL, `InstallMode` SHORT NOT NULL PRIMARY KEY `FileKey`)'
)
foreach ($schema in $schemas) { Sql $schema }
$productCode = Guid-For "product/$Rid/$Version"
$upgradeCode = Guid-For 'upgrade'
foreach ($entry in @{
    ProductCode=$productCode; UpgradeCode=$upgradeCode; ProductVersion=$Version; ProductLanguage='1033';
    ProductName='Pickleball screensaver'; Manufacturer='denmanjohn-maker'; MSIINSTALLPERUSER='1';
    ARPNOMODIFY='1'; ARPHELPLINK='https://github.com/denmanjohn-maker/pickleball-screensaver';
    SecureCustomProperties='OLDPRODUCTS;NEWERPRODUCTS;NATIVEARCH;WINDOWSBUILD'; REINSTALLMODE='amus'
}.GetEnumerator()) { Row Property @('Property','Value') @($entry.Key,$entry.Value) }
Row Directory @('Directory','Directory_Parent','DefaultDir') @('TARGETDIR',$null,'SourceDir')
Row Directory @('Directory','Directory_Parent','DefaultDir') @('LocalAppDataFolder','TARGETDIR','.')
Row Directory @('Directory','Directory_Parent','DefaultDir') @('Programs','LocalAppDataFolder','Programs')
Row Directory @('Directory','Directory_Parent','DefaultDir') @('INSTALLFOLDER','Programs','PICKLE~1|PickleballScreensaver')
Row Directory @('Directory','Directory_Parent','DefaultDir') @('ProgramMenuFolder','TARGETDIR','.')
Row Directory @('Directory','Directory_Parent','DefaultDir') @('MenuFolder','ProgramMenuFolder','PICKLE~1|Pickleball Screensaver')
Row Directory @('Directory','Directory_Parent','DefaultDir') @('System64Folder','TARGETDIR','.')
Row Feature @('Feature','Title','Level','Directory_','Attributes') @('Main','Pickleball screensaver',1,'INSTALLFOLDER',0)
Row RegLocator @('Signature_','Root','Key','Name','Type') @('NativeArch',2,'SYSTEM\CurrentControlSet\Control\Session Manager\Environment','PROCESSOR_ARCHITECTURE',18)
Row AppSearch @('Property','Signature_') @('NATIVEARCH','NativeArch')
Row RegLocator @('Signature_','Root','Key','Name','Type') @('WindowsBuild',2,'SOFTWARE\Microsoft\Windows NT\CurrentVersion','CurrentBuildNumber',18)
Row AppSearch @('Property','Signature_') @('WINDOWSBUILD','WindowsBuild')
$architecture = if($Rid -eq 'win-arm64'){'ARM64'}else{'AMD64'}
Row LaunchCondition @('Condition','Description') @("NATIVEARCH = `"$architecture`"",'Choose the package matching the native OS architecture (no emulation).')
Row LaunchCondition @('Condition','Description') @('NOT ALLUSERS','This installer is current-user only. Do not request ALLUSERS.')
Row LaunchCondition @('Condition','Description') @('WINDOWSBUILD >= 22000','Windows 11 (build 22000 or later) is required.')
Row LaunchCondition @('Condition','Description') @('NOT NEWERPRODUCTS','A newer version is already installed.')
Row Upgrade @('UpgradeCode','VersionMax','Attributes','ActionProperty') @($upgradeCode,$Version,1,'OLDPRODUCTS')
Row Upgrade @('UpgradeCode','VersionMin','Attributes','ActionProperty') @($upgradeCode,$Version,258,'NEWERPRODUCTS')
$cab = Join-Path $outputPath 'payload.cab'
$ddf = Join-Path $outputPath 'payload.ddf'
$lines = @('.OPTION EXPLICIT','.Set Cabinet=on','.Set Compress=on','.Set CompressionType=LZX','.Set MaxDiskSize=0',
    '.Set CabinetNameTemplate=payload.cab',".Set DiskDirectoryTemplate=$outputPath",
    ".Set RptFileName=$(Join-Path $outputPath 'msi-cab-report.txt')", ".Set InfFileName=$(Join-Path $outputPath 'msi-cab-info.txt')")
$files = @(Get-ChildItem -LiteralPath $payloadPath -File | Sort-Object Name)
if (@(Get-ChildItem -LiteralPath $payloadPath -Directory).Count -ne 0) { throw 'MSI payload must be the complete flat bundled publish folder' }
$sequence=0
foreach ($file in $files) {
    $sequence++;$id='F'+$sequence.ToString('0000');$component='C'+$sequence.ToString('0000')
    Row Component @('Component','ComponentId','Directory_','Attributes','KeyPath') @($component,(Guid-For "component/$Rid/$($file.Name)"),'INSTALLFOLDER',256,$id)
    Row FeatureComponents @('Feature_','Component_') @('Main',$component)
    Row File @('File','Component_','FileName','FileSize','Attributes','Sequence') @($id,$component,("P"+$sequence.ToString('0000')+"|"+$file.Name),[int]$file.Length,512,$sequence)
    $lines += "`"$($file.FullName)`" `"$id`""
    if ($file.Name -eq 'PickleballScreensaver.scr') { $scrId = $id; $scrComponent = $component }
}
if (-not $scrId) { throw 'No published .scr in payload' }
$lines | Set-Content -LiteralPath $ddf -Encoding ASCII
& makecab.exe /F $ddf | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'MSI CAB creation failed' }
Row Media @('DiskId','LastSequence','Cabinet') @(1,$sequence,'#payload.cab')
$view = Call $db 'OpenView' @('INSERT INTO `_Streams` (`Name`,`Data`) VALUES (?,?)')
$stream = Call $installer 'CreateRecord' @(2)
Set-Com $stream 'StringData' @(1,'payload.cab'); Call $stream 'SetStream' @(2,$cab) | Out-Null
Call $view 'Execute' @($stream) | Out-Null;Call $view 'Close' @() | Out-Null
# HKCU key path for user-specific shortcuts follows Windows Installer per-user rules.
Row Component @('Component','ComponentId','Directory_','Attributes','KeyPath') @('Menu',(Guid-For 'menu'),'MenuFolder',260,'MenuKey')
Row Registry @('Registry','Root','Key','Name','Value','Component_') @('MenuKey',1,'Software\PickleballScreensaver','InstalledVersion',$Version,'Menu')
Row FeatureComponents @('Feature_','Component_') @('Main','Menu')
Row RemoveFile @('FileKey','Component_','DirProperty','InstallMode') @('RemoveMenu','Menu','MenuFolder',2)
Row Shortcut @('Shortcut','Directory_','Name','Component_','Target','Arguments','ShowCmd','WkDir') @('Configure','MenuFolder','CONFIG~1|Pickleball settings','Menu',"[#$scrId]",'/c',1,'INSTALLFOLDER')
$shortcutIndex = 0
foreach ($action in @('Select','Classic','Blacklight')) {
    $shortcutIndex++
    Row Shortcut @('Shortcut','Directory_','Name','Component_','Target','Arguments','ShowCmd','WkDir') @(
        $action,'MenuFolder',("SC"+$shortcutIndex+"|Pickleball $action (opt in)"),'Menu','[System64Folder]WindowsPowerShell\v1.0\powershell.exe',
        "-NoProfile -ExecutionPolicy Bypass -File `"[INSTALLFOLDER]Maintain.ps1`" -Action $action",1,'INSTALLFOLDER')
}
Row CustomAction @('Action','Type','Source','Target') @('CleanupSelection',34,'System64Folder',
    'WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "[INSTALLFOLDER]Maintain.ps1" -Action Uninstall -Saver "[INSTALLFOLDER]PickleballScreensaver.scr"')
$actions = @{
    FindRelatedProducts=25; AppSearch=50; LaunchConditions=100; CostInitialize=800; FileCost=900; CostFinalize=1000;
    MigrateFeatureStates=1200; InstallValidate=1400; InstallInitialize=1500; RemoveExistingProducts=1550;
    ProcessComponents=1600; UnpublishFeatures=1800; RemoveShortcuts=3200; RemoveFiles=3500; InstallFiles=4000;
    CreateShortcuts=4500; WriteRegistryValues=5000; RemoveRegistryValues=2600; RegisterUser=6000; RegisterProduct=6100;
    PublishFeatures=6300; PublishProduct=6400; InstallFinalize=6600
}
foreach ($action in $actions.GetEnumerator()) {
    $condition = if($action.Key -eq 'RemoveExistingProducts'){'OLDPRODUCTS'}else{$null}
    Row InstallExecuteSequence @('Action','Condition','Sequence') @($action.Key,$condition,[int]$action.Value)
}
# Related-product detection must precede the launch condition checking newer versions.
Sql 'UPDATE `InstallExecuteSequence` SET `Sequence`=25 WHERE `Action`=''FindRelatedProducts'''
Row InstallExecuteSequence @('Action','Condition','Sequence') @('CleanupSelection','REMOVE="ALL" AND NOT UPGRADINGPRODUCTCODE',3400)
foreach ($action in @('FindRelatedProducts','AppSearch','LaunchConditions','CostInitialize','FileCost','CostFinalize')) {
    Row InstallUISequence @('Action','Sequence') @($action,[int]$(if($action -eq 'FindRelatedProducts'){25}else{$actions[$action]}))
}
Row InstallUISequence @('Action','Sequence') @('ExecuteAction',1300)
$summary = $db.GetType().InvokeMember('SummaryInformation',[Reflection.BindingFlags]::GetProperty,$null,$db,@(20))
Set-Com $summary 'Property' @(2,'Pickleball screensaver current-user installer')
Set-Com $summary 'Property' @(3,'Unsigned development package; does not activate a screensaver or apply a theme')
Set-Com $summary 'Property' @(7,($(if($Rid -eq 'win-arm64'){'Arm64'}else{'x64'})+';1033'))
Set-Com $summary 'Property' @(9,(Guid-For "package/$Rid/$Version"))
Set-Com $summary 'Property' @(14,500);Set-Com $summary 'Property' @(15,10);Set-Com $summary 'Property' @(16,0)
Call $summary 'Persist' @() | Out-Null
Call $db 'Commit' @() | Out-Null
Write-Host "Created per-user $Rid MSI: $msi"
