# windows_smoke.ps1 [-EngineSrc <engine\src>] [-Out host_release] [-Results <dir>]:
# builds this app for Windows on Flutter's stock engine and, with -EngineSrc, on
# the patched one, runs each and prints its SMOKE lines (also saved in
# <Results>\smoke-<engine>.txt). The app opens a window, so run it in a desktop
# session (from SSH: a scheduled task with /it). Needs `flutter` on PATH.
param(
  [string] $EngineSrc,
  [string] $Out = 'host_release',
  [string] $Results = (Join-Path $env:TEMP 'gpu_smoke')
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $Results | Out-Null
Set-Location $PSScriptRoot
flutter pub get | Out-Null
$engines = @('stock')
if ($EngineSrc) { $engines += 'patched' }
foreach ($engine in $engines) {
  $flags = @()
  if ($engine -eq 'patched') { $flags = @("--local-engine-src-path=$EngineSrc", "--local-engine=$Out", "--local-engine-host=$Out") }
  "== $engine build"
  flutter build windows --release @flags *> "$Results\build-$engine.log"
  "build exit $LASTEXITCODE"
  $txt = "$Results\smoke-$engine.txt"
  Remove-Item $txt -ErrorAction SilentlyContinue
  $env:GPU_SMOKE_OUT = $txt
  # A fresh ANGLE program cache (patch 0005) for each engine's first run.
  Remove-Item -Recurse -Force "$env:LOCALAPPDATA\gpu_smoke\flutter_angle_cache" -ErrorAction SilentlyContinue
  $p = Start-Process build\windows\x64\runner\Release\gpu_smoke.exe -PassThru
  $null = $p.WaitForExit(180000)
  if (!$p.HasExited) { $p.Kill(); "timeout" }
  Get-Content $txt -ErrorAction SilentlyContinue
}
