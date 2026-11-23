# fetch.ps1 [-Target windows-x64|windows-arm64] [-Data <dir>] [-Archive <file>]:
# the Windows twin of fetch.sh. Downloads the patched Flutter engine from the
# repo's GitHub release (the tag in .\RELEASE; needs `gh` logged in to an
# account that can read the repo), checks its SHA-256, unpacks it to
# <Data>\engine\<target>\ (Data: $env:MCSM_DATA, else the repo's data\) and
# links its out dir's dart-sdk to the Flutter SDK's own (the `flutter` on
# PATH, or $env:MCSM_FLUTTER). -Archive: unpack that local .tar.xz instead
# (its .sha256 beside it). Prints the flags for `flutter build windows`.
# The release repo (owner/name): $env:MCSM_ENGINE_REPO, else MCSM_ENGINE_REPO in
# a private/config/*.env found walking up from here (tools/toolchain/private_env.sh).
param(
  [string] $Target,
  [string] $Data,
  [string] $Archive
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
function Get-PrivateSetting([string] $Key) {
  $v = [Environment]::GetEnvironmentVariable($Key)
  if ($v) { return $v }
  $d = $here
  while ($d) {
    $cfg = Join-Path $d 'private\config'
    if (Test-Path $cfg) {
      foreach ($f in Get-ChildItem $cfg -Filter *.env | Sort-Object Name) {
        foreach ($l in Get-Content $f.FullName) {
          if ($l -match "^$Key=(.*)$") { return $Matches[1].Trim('"', "'") }
        }
      }
    }
    $d = Split-Path -Parent $d
  }
  return $null
}
$repo = Get-PrivateSetting 'MCSM_ENGINE_REPO'
if (!$repo -and !$Archive) {
  throw "mcsm: missing machine setting MCSM_ENGINE_REPO (the engine release repo, owner/name): set it in the environment or in <repo>\private\config\*.env, or pass -Archive"
}
$tag = (Get-Content "$here\RELEASE").Trim()
if (!$Target) {
  $Target = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'windows-arm64' } else { 'windows-x64' }
}
if (!$Data) {
  $Data = if ($env:MCSM_DATA) { $env:MCSM_DATA } else { Join-Path (Resolve-Path "$here\..\..") 'data' }
}
$asset = "mcsm-engine-$Target.tar.xz"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("mcsm-engine-fetch-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  if ($Archive) {
    Copy-Item $Archive "$tmp\$asset"
    Copy-Item "$Archive.sha256" "$tmp\$asset.sha256"
  } else {
    "mcsm: fetching $asset from $repo release $tag"
    gh release download $tag -R $repo -p $asset -p "$asset.sha256" -D $tmp
    if ($LASTEXITCODE -ne 0) { throw "gh release download failed" }
  }
  $want = ((Get-Content "$tmp\$asset.sha256") -split '\s+')[0]
  $have = (Get-FileHash -Algorithm SHA256 "$tmp\$asset").Hash.ToLower()
  if ($want -ne $have) { throw "SHA-256 mismatch for $asset" }
  $dest = Join-Path $Data 'engine'
  New-Item -ItemType Directory -Force $dest | Out-Null
  if (Test-Path "$dest\$Target") { Remove-Item -Recurse -Force "$dest\$Target" }
  tar -C $dest -xJf "$tmp\$asset"
  if ($LASTEXITCODE -ne 0) { throw "tar failed" }
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
$flutter = if ($env:MCSM_FLUTTER) { $env:MCSM_FLUTTER } else { Split-Path -Parent (Split-Path -Parent (Get-Command flutter).Source) }
$out = Get-ChildItem "$dest\$Target\src\out" -Directory | Select-Object -First 1
cmd /c mklink /J "$($out.FullName)\dart-sdk" "$flutter\bin\cache\dart-sdk" | Out-Null
"mcsm: engine $Target in $dest\$Target"
"Build with:"
"  flutter build windows --release --local-engine-src-path=$dest\$Target\src --local-engine=$($out.Name) --local-engine-host=$($out.Name)"
