# package.ps1 <engine\src> <out name> <target> <dest dir> [<host out name>]:
# the Windows twin of package.sh. Packs what a release
# `flutter build windows --local-engine` reads into
# <dest>\prismarine-engine-<target>.tar.xz (+ .sha256): flutter_windows.dll, its
# import library, export file and headers (an empty .pdb in place of its
# debug symbols), the C++ client wrapper, gen_snapshot, icudtl,
# the patched SDK (also as flutter_patched_sdk_product: a copy, since
# extracting symlinks needs privileges on Windows), sky_engine, const_finder,
# font-subset, impellerc with its shader_lib. fetch.ps1 adds the dart-sdk link.
param(
  [Parameter(Mandatory)] [string] $Src,
  [Parameter(Mandatory)] [string] $Out,
  [Parameter(Mandatory)] [string] $Target,
  [Parameter(Mandatory)] [string] $Dest,
  [string] $HostOut = $Out
)
$ErrorActionPreference = 'Stop'
$from = Join-Path $Src "out\$Out"
if (!(Test-Path $from)) { throw "no $from" }
$stage = Join-Path ([IO.Path]::GetTempPath()) ("prismarine-engine-pack-" + [guid]::NewGuid())
$to = Join-Path $stage "$Target\src\out\$Out"
New-Item -ItemType Directory -Force $to | Out-Null
$files = @('flutter_windows.dll', 'flutter_windows.dll.lib', 'flutter_windows.dll.exp', 'flutter_export.h', 'flutter_macros.h',
  'flutter_messenger.h', 'flutter_plugin_registrar.h', 'flutter_texture_registrar.h', 'flutter_windows.h',
  'gen_snapshot.exe', 'icudtl.dat', 'font-subset.exe', 'impellerc.exe', 'LICENSE')
foreach ($f in $files) { if (Test-Path "$from\$f") { Copy-Item "$from\$f" $to } }
# The Flutter tool's unpack_windows copies flutter_windows.dll.pdb too (the
# debug symbols, ~260 MB): an empty one stands in for it.
if (!(Test-Path "$to\flutter_windows.dll.pdb")) { New-Item -ItemType File "$to\flutter_windows.dll.pdb" | Out-Null }
foreach ($d in 'cpp_client_wrapper', 'flutter_patched_sdk', 'shader_lib') {
  if (Test-Path "$from\$d") { Copy-Item -Recurse "$from\$d" $to }
}
Copy-Item -Recurse "$from\flutter_patched_sdk" "$to\flutter_patched_sdk_product"
Get-ChildItem $from -Directory -Filter 'clang_*' | ForEach-Object {
  if (Test-Path "$($_.FullName)\gen_snapshot.exe") {
    New-Item -ItemType Directory -Force "$to\$($_.Name)" | Out-Null
    Copy-Item "$($_.FullName)\gen_snapshot.exe" "$to\$($_.Name)\"
  }
}
New-Item -ItemType Directory -Force "$to\gen\dart-pkg" | Out-Null
foreach ($g in 'dart-pkg\sky_engine', 'const_finder.dart.snapshot') {
  foreach ($o in $from, (Join-Path $Src "out\$HostOut")) {
    if (Test-Path "$o\gen\$g") { Copy-Item -Recurse "$o\gen\$g" "$to\gen\$g"; break }
  }
}
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$patches = (Get-ChildItem "$here\patches\*.patch" | Sort-Object Name | ForEach-Object Name) -join ' '
# The engine revision the patches apply to (the Flutter SDK's engine.version).
$rev = if ($env:PRISMARINE_ENGINE_REV) { $env:PRISMARINE_ENGINE_REV } elseif ($env:MCSM_ENGINE_REV) { $env:MCSM_ENGINE_REV } else { 'deb287481e3ce9468f3434937ced4240a70539ca' }
$release = (Get-Content (Join-Path $here 'RELEASE') -Raw).Trim()
@("target=$Target", "release=$release", "out=$Out", "engine_revision=$rev", "patches=$patches") |
  Set-Content -Encoding ascii (Join-Path $stage "$Target\prismarine-engine.txt")
New-Item -ItemType Directory -Force $Dest | Out-Null
$archive = Join-Path $Dest "prismarine-engine-$Target.tar.xz"
tar -C $stage -cJf $archive $Target
$hash = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLower()
"$hash  prismarine-engine-$Target.tar.xz" | Set-Content -Encoding ascii "$archive.sha256" -NoNewline
Add-Content -Encoding ascii "$archive.sha256" "`n" -NoNewline
Remove-Item -Recurse -Force $stage
"$archive $([math]::Round((Get-Item $archive).Length / 1MB, 1)) MB"
