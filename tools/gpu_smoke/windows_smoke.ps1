# windows_smoke.ps1: builds tools/gpu_smoke for Windows against Flutter's
# prebuilt engine and the patched one (C:\mcsm\engine, out\host_release) and
# runs each in the logged-in desktop session (run this as a scheduled task with
# /it). Results: C:\mcsm\smoke-<engine>.txt. Sources in C:\mcsm\smoke (this
# repo's tools/gpu_smoke and third_party/flutter_scene, flutter_gpu).
$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\mcsm\smoke.log -Append
$env:Path = "C:\Program Files\Git\cmd;C:\mcsm\sdk\bin;" + $env:Path
if (!(Test-Path C:\mcsm\sdk)) { git clone -q --depth 1 -b 3.47.7 https://github.com/flutter/flutter.git C:\mcsm\sdk }
flutter config --no-analytics --no-cli-animations | Out-Null
# A release out dir's patched SDK is the product one (the tool's name for it).
$out = 'C:\mcsm\engine\flutter\engine\src\out\host_release'
if (!(Test-Path "$out\flutter_patched_sdk_product")) { cmd /c mklink /J "$out\flutter_patched_sdk_product" "$out\flutter_patched_sdk" | Out-Null }
Set-Location C:\mcsm\smoke\tools\gpu_smoke
(Get-Content ..\..\third_party\flutter_scene\pubspec.yaml) | Where-Object { $_ -notmatch '^resolution: workspace' } | Set-Content ..\..\third_party\flutter_scene\pubspec.yaml
flutter pub get
foreach ($engine in 'stock', 'patched') {
  $args = @()
  if ($engine -eq 'patched') { $args = @('--local-engine-src-path=C:\mcsm\engine\flutter\engine\src', '--local-engine=host_release', '--local-engine-host=host_release') }
  "== $engine build"
  flutter build windows --release @args *> "C:\mcsm\smoke-build-$engine.log"
  "build exit $LASTEXITCODE"
  Remove-Item -Recurse -Force "C:\mcsm\smoke-$engine" -ErrorAction SilentlyContinue
  Copy-Item -Recurse build\windows\x64\runner\Release "C:\mcsm\smoke-$engine"
  Remove-Item "C:\mcsm\smoke-$engine.txt" -ErrorAction SilentlyContinue
  $env:GPU_SMOKE_OUT = "C:\mcsm\smoke-$engine.txt"
  $p = Start-Process "C:\mcsm\smoke-$engine\gpu_smoke.exe" -PassThru
  if (!$p.WaitForExit(180000)) { $p.Kill(); "timeout" }
  "run exit $($p.ExitCode)"
  Get-Content "C:\mcsm\smoke-$engine.txt" -ErrorAction SilentlyContinue
}
"SMOKE-DONE"
Stop-Transcript
