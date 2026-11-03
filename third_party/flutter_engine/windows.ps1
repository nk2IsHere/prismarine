# windows.ps1 [-EngineDir <dir>] [-Cpu x64|arm64|both] [-Jobs <n>]: the patched
# Flutter engine for Windows. Clones Flutter at the engine revision into
# <EngineDir>\flutter, applies .\patches, runs `gclient sync` (Windows deps
# only) and builds the release engines: out\host_release (x64) and/or
# out\host_release_arm64 (arm64, cross-built). Logs in <EngineDir>\logs.
#
# Needs windows-toolchain.ps1's tools first (VS 2022 Build Tools with the C++
# x64/ARM64 tools and ATL, Windows SDK 10.0.22621 with Debugging Tools, Git,
# Python), long paths on, and ~25 GB free (sources ~10 GB, ~2.5–3.6 GB per out
# dir). Run it from an elevated PowerShell (or a scheduled task: builds started
# from an SSH session stop when it closes). The first build of each CPU takes
# ~25–35 min on 10 cores.
param(
  [string] $EngineDir = (Join-Path $env:USERPROFILE 'mcsm-engine'),
  [ValidateSet('x64', 'arm64', 'both')] [string] $Cpu = 'both',
  [int] $Jobs = [Environment]::ProcessorCount,
  [string] $Revision = 'deb287481e3ce9468f3434937ced4240a70539ca'
)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force "$EngineDir\logs" | Out-Null
Start-Transcript -Path "$EngineDir\logs\build.log" -Append
$vs = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
$env:Path = "C:\Program Files\Git\cmd;$EngineDir\depot_tools;" + $env:Path
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:DEPOT_TOOLS_METRICS = '0'
$env:GYP_MSVS_OVERRIDE_PATH = $vs
$env:vs2022_install = $vs
Set-Location $EngineDir
if (!(Test-Path depot_tools)) { git clone -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git }
if (!(Test-Path flutter)) {
  git clone -q --filter=blob:none --no-checkout https://github.com/flutter/flutter.git flutter
  git -C flutter checkout -q --detach $Revision
}
Set-Location flutter
git checkout -q -B mcsm-engine $Revision
git -c user.name=mcsm -c user.email=mcsm@localhost -c core.autocrlf=false am -q (Get-ChildItem "$here\patches\*.patch" | Sort-Object Name | ForEach-Object FullName)
@'
solutions = [{
  "name": ".",
  "url": "https://github.com/flutter/flutter.git",
  "deps_file": "DEPS",
  "managed": False,
  "safesync_url": "",
  "custom_deps": {},
  "custom_vars": {
    "download_android_deps": False,
    "download_jdk": False,
    "download_esbuild": False,
    "download_fuchsia_deps": False,
    "setup_githooks": False,
  },
}]
target_os = ["win"]
'@ | Set-Content -Encoding ascii .gclient
"== $(Get-Date -Format T) gclient"
gclient sync --no-history -j8
Set-Location engine\src
$common = @('flutter/lib/snapshot:kernel_platform_files')
$hostTools = @('flutter/sky/packages', 'flutter/tools/font_subset', 'flutter/tools/const_finder', 'flutter/impeller/compiler:impellerc')
foreach ($c in @('x64', 'arm64')) {
  if ($Cpu -ne 'both' -and $Cpu -ne $c) { continue }
  $out = if ($c -eq 'arm64') { 'host_release_arm64' } else { 'host_release' }
  $gnArgs = @('--runtime-mode=release', '--no-lto', '--prebuilt-dart-sdk', '--no-enable-unittests')
  if ($c -eq 'arm64') { $gnArgs += @('--windows-cpu', 'arm64') }
  "== $(Get-Date -Format T) $c"
  python3 flutter\tools\gn @gnArgs
  $targets = @('windows', 'gen_snapshot', 'flutter/build/archives:windows_flutter') + $common
  if ($c -eq 'x64') { $targets += $hostTools }
  $t = Measure-Command { ninja -C "out\$out" "-j$Jobs" @targets *> "$EngineDir\logs\ninja-$c.log" }
  "$c exit $LASTEXITCODE in $([math]::Round($t.TotalMinutes, 1)) min"
  Get-Content "$EngineDir\logs\ninja-$c.log" -Tail 3
  # A release out dir's patched SDK is the product one (the Flutter tool's name).
  if (!(Test-Path "out\$out\flutter_patched_sdk_product")) {
    cmd /c mklink /J "out\$out\flutter_patched_sdk_product" "out\$out\flutter_patched_sdk" | Out-Null
  }
}
"Engine source: $EngineDir\flutter\engine\src"
"BUILD-DONE"
Stop-Transcript
