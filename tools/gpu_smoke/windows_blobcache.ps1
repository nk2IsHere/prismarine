# windows_blobcache.ps1: the patched engine's ANGLE program cache (patch 0005),
# cold vs warm. Rebuilds gpu_smoke against C:\mcsm\engine (out\host_release),
# then runs it with the cache deleted, and twice more with it kept; and once
# with FLUTTER_ANGLE_BLOB_CACHE=0. Run as a scheduled task with /it.
# Results: C:\mcsm\blob-<run>.txt and C:\mcsm\blobcache.log.
$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\mcsm\blobcache.log -Append
$env:Path = "C:\Program Files\Git\cmd;C:\mcsm\sdk\bin;" + $env:Path
Set-Location C:\mcsm\smoke\tools\gpu_smoke
if (!(Test-Path build\windows\x64\runner\Release\gpu_smoke.exe)) {
  flutter build windows --release --local-engine-src-path=C:\mcsm\engine\flutter\engine\src --local-engine=host_release --local-engine-host=host_release *> C:\mcsm\blob-build.log
  "build exit $LASTEXITCODE"
}
$exe = (Resolve-Path build\windows\x64\runner\Release\gpu_smoke.exe).Path
$cache = "$env:LOCALAPPDATA\gpu_smoke\flutter_angle_cache"
foreach ($run in 'cold', 'warm1', 'warm2', 'off') {
  if ($run -eq 'cold') { Remove-Item -Recurse -Force $cache -ErrorAction SilentlyContinue }
  if ($run -eq 'off') { $env:FLUTTER_ANGLE_BLOB_CACHE = '0' } else { Remove-Item Env:FLUTTER_ANGLE_BLOB_CACHE -ErrorAction SilentlyContinue }
  Remove-Item "C:\mcsm\blob-$run.txt" -ErrorAction SilentlyContinue
  $env:GPU_SMOKE_OUT = "C:\mcsm\blob-$run.txt"
  $p = Start-Process $exe -PassThru
  $deadline = (Get-Date).AddSeconds(120)
  $null = $p.WaitForExit(120000)
  if (!$p.HasExited) { $p.Kill() }
  "== $run (cache files: $((Get-ChildItem $cache -ErrorAction SilentlyContinue | Measure-Object).Count))"
  Get-Content "C:\mcsm\blob-$run.txt" -ErrorAction SilentlyContinue
}
"BLOB-DONE"
Stop-Transcript
