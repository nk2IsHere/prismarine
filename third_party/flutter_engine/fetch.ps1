# fetch.ps1 [-Target windows-x64|windows-arm64] [-Data <dir>] [-Archive <file>]
# is the Windows form of fetch.sh. It downloads the patched Flutter engine from
# the GitHub release that RELEASE gives, checks its SHA-256 and unpacks it to
# <engine dir>\<target>\. It links the dart-sdk of the out dir to the one of
# the Flutter SDK and prints the flags for `flutter build windows`.
#
# The engine directory is <Data>\engine when -Data is given, else
# $env:PRISMARINE_ENGINE_DIR, else $env:MCSM_DATA\engine, else data\engine of
# this checkout. The Flutter SDK is $env:PRISMARINE_FLUTTER or
# $env:MCSM_FLUTTER, else the flutter on PATH. The release repository, as
# owner/name, is PRISMARINE_ENGINE_REPO or MCSM_ENGINE_REPO from the
# environment or from the first private\config\*.env above this directory. The
# download needs gh, logged in to an account that can read the repository.
# -Archive unpacks a downloaded archive with its .sha256 beside it in place of
# the download.
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
$repo = Get-PrivateSetting 'PRISMARINE_ENGINE_REPO'
if (!$repo) { $repo = Get-PrivateSetting 'MCSM_ENGINE_REPO' }
if (!$repo -and !$Archive) {
  throw "fetch.ps1: no release repository. Set PRISMARINE_ENGINE_REPO to owner/name in the environment or in private\config\*.env, or pass -Archive."
}
$tag = (Get-Content "$here\RELEASE").Trim()
if (!$Target) {
  $Target = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'windows-arm64' } else { 'windows-x64' }
}
if ($Data) {
  $dest = Join-Path $Data 'engine'
} elseif ($env:PRISMARINE_ENGINE_DIR) {
  $dest = $env:PRISMARINE_ENGINE_DIR
} else {
  $Data = if ($env:MCSM_DATA) { $env:MCSM_DATA } else { Join-Path (Resolve-Path "$here\..\..") 'data' }
  $dest = Join-Path $Data 'engine'
}
$asset = "prismarine-engine-$Target.tar.xz"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("prismarine-engine-fetch-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  if ($Archive) {
    Copy-Item $Archive "$tmp\$asset"
    Copy-Item "$Archive.sha256" "$tmp\$asset.sha256"
  } else {
    "fetch.ps1: fetching $asset from $repo release $tag"
    gh release download $tag -R $repo -p $asset -p "$asset.sha256" -D $tmp
    if ($LASTEXITCODE -ne 0) { throw "gh release download failed" }
  }
  $want = ((Get-Content "$tmp\$asset.sha256") -split '\s+')[0]
  $have = (Get-FileHash -Algorithm SHA256 "$tmp\$asset").Hash.ToLower()
  if ($want -ne $have) { throw "SHA-256 mismatch for $asset" }
  New-Item -ItemType Directory -Force $dest | Out-Null
  if (Test-Path "$dest\$Target") { Remove-Item -Recurse -Force "$dest\$Target" }
  tar -C $dest -xJf "$tmp\$asset"
  if ($LASTEXITCODE -ne 0) { throw "tar failed" }
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
$flutter = if ($env:PRISMARINE_FLUTTER) { $env:PRISMARINE_FLUTTER } elseif ($env:MCSM_FLUTTER) { $env:MCSM_FLUTTER } else { Split-Path -Parent (Split-Path -Parent (Get-Command flutter).Source) }
$out = Get-ChildItem "$dest\$Target\src\out" -Directory | Select-Object -First 1
cmd /c mklink /J "$($out.FullName)\dart-sdk" "$flutter\bin\cache\dart-sdk" | Out-Null
"fetch.ps1: engine $Target in $dest\$Target"
"Build with:"
"  flutter build windows --release --local-engine-src-path=$dest\$Target\src --local-engine=$($out.Name) --local-engine-host=$($out.Name)"
