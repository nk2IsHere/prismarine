# mcsm patched engine on Windows: checkout, gclient sync, x64 and arm64 release builds.
# Logs to C:\mcsm\build.log. Patches in C:\mcsm\patches.
$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\mcsm\build.log -Append
$E = 'C:\mcsm\engine'
$rev = 'deb287481e3ce9468f3434937ced4240a70539ca'
$env:Path = "C:\Program Files\Git\cmd;$E\depot_tools;" + $env:Path
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:DEPOT_TOOLS_METRICS = '0'
$env:GYP_MSVS_OVERRIDE_PATH = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
$env:vs2022_install = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
New-Item -ItemType Directory -Force $E | Out-Null
Set-Location $E
if (!(Test-Path depot_tools)) { git clone -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git }
if (!(Test-Path flutter)) {
  git clone -q --filter=blob:none --no-checkout https://github.com/flutter/flutter.git flutter
  git -C flutter checkout -q --detach $rev
}
Set-Location flutter
git checkout -q -B mcsm-engine $rev
git -c user.name=mcsm -c user.email=mcsm@localhost -c core.autocrlf=false am -q (Get-ChildItem C:\mcsm\patches\*.patch | Sort-Object Name | ForEach-Object FullName)
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
$targets = @('windows','gen_snapshot','flutter/build/archives:windows_flutter','flutter/lib/snapshot:kernel_platform_files','flutter/sky/packages','flutter/flutter_frontend_server:frontend_server','flutter/tools/font_subset','flutter/tools/const_finder')
"== $(Get-Date -Format T) x64"
python3 flutter\tools\gn --runtime-mode=release --no-lto --prebuilt-dart-sdk --no-enable-unittests
$t = Measure-Command { ninja -C out\host_release -j10 @targets *> C:\mcsm\ninja-x64.log }
"x64 exit $LASTEXITCODE in $($t.TotalMinutes) min"; Get-Content C:\mcsm\ninja-x64.log -Tail 3
"== $(Get-Date -Format T) arm64"
python3 flutter\tools\gn --runtime-mode=release --no-lto --prebuilt-dart-sdk --no-enable-unittests --windows-cpu arm64
$t = Measure-Command { ninja -C out\host_release_arm64 -j10 windows gen_snapshot flutter/build/archives:windows_flutter flutter/lib/snapshot:kernel_platform_files *> C:\mcsm\ninja-arm64.log }
"arm64 exit $LASTEXITCODE in $($t.TotalMinutes) min"; Get-Content C:\mcsm\ninja-arm64.log -Tail 3
"BUILD-DONE"
Stop-Transcript
