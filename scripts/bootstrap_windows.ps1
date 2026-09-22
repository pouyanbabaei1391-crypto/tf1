$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

Write-Host "[1/5] Checking Flutter..." -ForegroundColor Cyan
flutter --version

$Backup = Join-Path $env:TEMP ("nexadrop_src_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Backup | Out-Null
Copy-Item -Recurse -Force "$Root\lib" "$Backup\lib"
Copy-Item -Force "$Root\pubspec.yaml" "$Backup\pubspec.yaml"
Copy-Item -Force "$Root\analysis_options.yaml" "$Backup\analysis_options.yaml"
Copy-Item -Recurse -Force "$Root\test" "$Backup\test"

Write-Host "[2/5] Generating Android + Windows platform runners..." -ForegroundColor Cyan
flutter create --overwrite --platforms=android,windows --org com.nexadrop --project-name nexadrop .

Write-Host "[3/5] Restoring NexaDrop source..." -ForegroundColor Cyan
Remove-Item -Recurse -Force "$Root\lib"
Copy-Item -Recurse -Force "$Backup\lib" "$Root\lib"
Copy-Item -Force "$Backup\pubspec.yaml" "$Root\pubspec.yaml"
Copy-Item -Force "$Backup\analysis_options.yaml" "$Root\analysis_options.yaml"
Remove-Item -Recurse -Force "$Root\test" -ErrorAction SilentlyContinue
Copy-Item -Recurse -Force "$Backup\test" "$Root\test"
Remove-Item -Recurse -Force $Backup

Write-Host "[4/5] Applying platform configuration..." -ForegroundColor Cyan
Copy-Item -Force "$Root\platform\android\AndroidManifest.xml" "$Root\android\app\src\main\AndroidManifest.xml"

$CMake = "$Root\windows\CMakeLists.txt"
if (Test-Path $CMake) {
    $c = Get-Content $CMake -Raw
    $c = $c -replace 'set\(BINARY_NAME "nexadrop"\)', 'set(BINARY_NAME "NexaDrop")'
    Set-Content -Path $CMake -Value $c -Encoding UTF8
}

Write-Host "[5/5] Resolving packages..." -ForegroundColor Cyan
flutter pub get
Write-Host "Bootstrap complete." -ForegroundColor Green
Write-Host "Next: .\scripts\build_release.ps1" -ForegroundColor Yellow
