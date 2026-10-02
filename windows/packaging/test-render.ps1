param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $Output | Out-Null
$arguments=@('--project',(Join-Path $PSScriptRoot '../tools/Pickleball.Preview'),'-c','Release','--')
$hashes=@{}
foreach($preset in @('classic','blacklight','living-court','ink-and-paper','rally-painting')) {
    foreach($format in @('singles','doubles')) {
        $path=Join-Path $Output "$preset-$format.png"
        $frame=if($format -eq 'singles'){800}else{910}
        dotnet run @arguments $path $frame 42 1280x720 '2026-01-01T12:00:00.0000000+00:00' $preset $format slow
        if($LASTEXITCODE -ne 0){throw 'Appearance export failed'}
        if((Get-Item $path).Length -lt 10000){throw 'Rendered PNG suspiciously small'}
        $hashes["$preset-$format"]=(Get-FileHash $path).Hash
    }
}
foreach($format in @('singles','doubles')){
    if(@($hashes.GetEnumerator() | Where-Object {$_.Key.EndsWith("-$format")} | ForEach-Object {$_.Value} | Sort-Object -Unique).Count -ne 5){
        throw 'Appearances must render distinct geometry/effects'
    }
}
foreach($motion in @('standard','slow','still','reduced')) {
    foreach($size in @('1080x1920','3840x2160','5120x1440')) {
        dotnet run @arguments (Join-Path $Output "$motion-$size.png") 3700 42 $size '2026-01-01T12:00:00.0000000+00:00' living-court doubles $motion
        if($LASTEXITCODE -ne 0){throw 'Motion/viewport export failed'}
    }
}
foreach($run in @('a','b')){
    dotnet run @arguments (Join-Path $Output "replay-$run.png") 900 42 1280x720 '2026-01-01T12:00:00.0000000+00:00' rally-painting doubles slow
    if($LASTEXITCODE -ne 0){throw 'Replay export failed'}
}
if((Get-FileHash (Join-Path $Output 'replay-a.png')).Hash -ne (Get-FileHash (Join-Path $Output 'replay-b.png')).Hash){throw 'Seeded PNG replay differs'}
Write-Host 'PASS: five distinct appearances, both formats, mixed viewport shapes, all motion modes, exact offline replay.'
