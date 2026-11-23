# The Windows engine build toolchain (logs to $env:TEMP\prismarine-toolchain\install.log): Git, Python,
# VS 2022 Build Tools (MSVC x64 + ARM64, ATL, Windows SDK 22621) and the SDK's
# Debugging Tools. Run elevated as the build user (a scheduled task: jobs
# started from an SSH session die with it). Then windows.ps1. Long paths are
# turned on too (the engine's sources need them).
$ErrorActionPreference = 'Continue'
$work = Join-Path $env:TEMP 'prismarine-toolchain'
New-Item -ItemType Directory -Force $work | Out-Null
Start-Transcript -Path "$work\install.log" -Append
$wg = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
& $wg install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements --scope machine
& $wg install --id Python.Python.3.12 -e --silent --accept-package-agreements --accept-source-agreements --scope machine
# Visual Studio 2022 Build Tools: MSVC x64 and ARM64, ATL, Windows 11 SDK 22621 (the engine's SDK_VERSION).
$vs = "$work\vs_BuildTools.exe"
Invoke-WebRequest https://aka.ms/vs/17/release/vs_BuildTools.exe -OutFile $vs
$p = Start-Process $vs -Wait -PassThru -ArgumentList @('--quiet','--wait','--norestart','--nocache',
  '--add','Microsoft.VisualStudio.Workload.VCTools',
  '--add','Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
  '--add','Microsoft.VisualStudio.Component.VC.Tools.ARM64',
  '--add','Microsoft.VisualStudio.Component.VC.ATL',
  '--add','Microsoft.VisualStudio.Component.VC.ATL.ARM64',
  '--add','Microsoft.VisualStudio.Component.Windows11SDK.22621',
  '--includeRecommended')
"vs_BuildTools exit $($p.ExitCode)"
# Debugging Tools for Windows (the engine needs them), from the 22621 SDK.
& $wg install --id Microsoft.WindowsSDK.10.0.22621 -e --silent --accept-package-agreements --accept-source-agreements --override '/features OptionId.WindowsDesktopDebuggers /quiet /norestart'
"debuggers: $(Test-Path 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\dbghelp.dll')"
& 'C:\Program Files\Git\cmd\git.exe' config --system core.longpaths true
Set-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1
"INSTALL-DONE"
Stop-Transcript
