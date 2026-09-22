$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

if (-not (Test-Path "$Root\android") -or -not (Test-Path "$Root\windows")) {
    throw "Platform folders are missing. Run .\scripts\bootstrap_windows.ps1 first."
}

Write-Host "[1/6] Packages" -ForegroundColor Cyan
flutter pub get

Write-Host "[2/6] Static analysis" -ForegroundColor Cyan
flutter analyze

Write-Host "[3/6] Tests" -ForegroundColor Cyan
flutter test

Write-Host "[4/6] Android release APK" -ForegroundColor Cyan
flutter build apk --release

Write-Host "[5/6] Windows x64 release" -ForegroundColor Cyan
flutter build windows --release

$Dist = "$Root\dist"
Remove-Item -Recurse -Force $Dist -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$Dist\android" | Out-Null
New-Item -ItemType Directory -Force -Path "$Dist\windows" | Out-Null
Copy-Item "$Root\build\app\outputs\flutter-apk\app-release.apk" "$Dist\android\NexaDrop.apk"
Copy-Item -Recurse "$Root\build\windows\x64\runner\Release" "$Dist\windows\NexaDrop-Windows"
Compress-Archive -Force -Path "$Dist\windows\NexaDrop-Windows\*" -DestinationPath "$Dist\windows\NexaDrop-Windows-x64.zip"

Write-Host "[6/6] Optional Windows installer" -ForegroundColor Cyan
$IsccCandidates = @(
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
)
$Iscc = $IsccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($Iscc) {
    & $Iscc "$Root\installer\NexaDrop.iss"
} else {
    Write-Host "Inno Setup 6 not found; skipping single EXE installer." -ForegroundColor Yellow
}

Write-Host "Release output:" -ForegroundColor Green
Write-Host "  APK: $Dist\android\NexaDrop.apk"
Write-Host "  Windows bundle: $Dist\windows\NexaDrop-Windows-x64.zip"
Write-Host "  App EXE: $Dist\windows\NexaDrop-Windows\NexaDrop.exe"
if (Test-Path "$Dist\windows\NexaDrop-Setup.exe") {
    Write-Host "  Installer EXE: $Dist\windows\NexaDrop-Setup.exe"
}
