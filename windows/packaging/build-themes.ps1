param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputPath = [IO.Path]::GetFullPath($Output)
if (-not $outputPath.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Output must be inside windows/' }
New-Item -ItemType Directory -Force $outputPath | Out-Null
foreach ($preset in @('classic','blacklight')) {
    $label = if ($preset -eq 'classic') { 'Classic' } else { 'BlackLight' }
    $work = Join-Path $outputPath $label
    New-Item -ItemType Directory -Force (Join-Path $work 'DesktopBackground') | Out-Null
    foreach ($size in @('3840x2160','5120x2160')) {
        dotnet run --project (Join-Path $root 'tools/Pickleball.Preview') -c Release -- (Join-Path $work "DesktopBackground\$label-$size.png") 0 42 $size '2026-01-01T12:00:00.0000000+00:00' $preset doubles still wallpaper
        if ($LASTEXITCODE -ne 0) { throw 'Wallpaper export failed' }
    }
    $color = if ($preset -eq 'classic') { '0xFFF5D10D' } else { '0xFFFF8C1A' }
    @"
[Theme]
DisplayName=Pickleball $label

[Control Panel\Desktop]
Wallpaper=DesktopBackground\$label-3840x2160.png
TileWallpaper=0
WallpaperStyle=10

[VisualStyles]
Path=%ResourceDir%\Themes\Aero\Aero.msstyles
ColorStyle=NormalColor
Size=NormalSize
AutoColorization=0
ColorizationColor=$color

[MasterThemeSelector]
MTSM=DABJDKT
"@ | Set-Content -LiteralPath (Join-Path $work "Pickleball-$label.theme") -Encoding Unicode
    $cabName = "Pickleball-$label.deskthemepack"
    $lines = @('.OPTION EXPLICIT', '.Set Cabinet=on', '.Set Compress=on', '.Set CompressionType=LZX',
        ".Set CabinetNameTemplate=$cabName", ".Set DiskDirectoryTemplate=$outputPath", '.Set MaxDiskSize=0',
        ".Set RptFileName=$(Join-Path $work 'cab-report.txt')", ".Set InfFileName=$(Join-Path $work 'cab-info.txt')",
        "`"$(Join-Path $work "Pickleball-$label.theme")`" `"Pickleball-$label.theme`"", '.Set DestinationDir=DesktopBackground')
    foreach ($size in @('3840x2160','5120x2160')) { $lines += "`"$(Join-Path $work "DesktopBackground\$label-$size.png")`" `"$label-$size.png`"" }
    $ddf = Join-Path $work 'theme.ddf'; $lines | Set-Content -LiteralPath $ddf -Encoding ASCII
    & makecab.exe /F $ddf | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Theme CAB creation failed' }
    $bytes = [IO.File]::ReadAllBytes((Join-Path $outputPath $cabName))
    if ([Text.Encoding]::ASCII.GetString($bytes,0,4) -ne 'MSCF') { throw 'Theme pack must be a real CAB, not a ZIP' }
    $hash = (Get-FileHash (Join-Path $outputPath $cabName) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $cabName" | Set-Content (Join-Path $outputPath "$cabName.sha256") -Encoding ASCII
}
