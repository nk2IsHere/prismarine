@echo off
rem Starts the prismarine command of this checkout with the Dart SDK of Flutter.
rem The command is compiled again when its sources change.
setlocal
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "SDK="
if defined PRISMARINE_FLUTTER if exist "%PRISMARINE_FLUTTER%\bin\flutter.bat" set "SDK=%PRISMARINE_FLUTTER%"
if not defined SDK if exist "%USERPROFILE%\.prismarine\flutter\bin\flutter.bat" set "SDK=%USERPROFILE%\.prismarine\flutter"
if not defined SDK for /f "delims=" %%F in ('where flutter.bat 2^>nul') do if not defined SDK set "SDK=%%~dpF.."
if not defined SDK (
  echo prismarine needs the Flutter SDK 3.47.7. Install it with: 1>&2
  echo   git clone --branch 3.47.7 https://github.com/flutter/flutter.git %USERPROFILE%\.prismarine\flutter 1>&2
  exit /b 1
)
for %%I in ("%SDK%") do set "SDK=%%~fI"
set "CACHE=%PRISMARINE_PUB_CACHE%"
if not defined CACHE set "CACHE=%USERPROFILE%\.prismarine\pub-cache"
if exist "%CACHE%\" set "PUB_CACHE=%CACHE%"
set "DART=%SDK%\bin\cache\dart-sdk\bin\dart.exe"
if not exist "%DART%" (
  call "%SDK%\bin\flutter.bat" --version >nul 2>&1
)
set "KERNEL=%ROOT%\.dart_tool\prismarine\prismarine.dill"
if not exist "%ROOT%\.dart_tool\package_config.json" (
  echo prismarine: resolving the packages of %ROOT% 1>&2
  pushd "%ROOT%"
  "%DART%" pub get >nul || ("%DART%" pub get & popd & exit /b 1)
  popd
)
if exist "%KERNEL%" goto run
if not exist "%ROOT%\.dart_tool\prismarine" mkdir "%ROOT%\.dart_tool\prismarine"
pushd "%ROOT%"
"%DART%" compile kernel -o "%KERNEL%" packages\prismarine_cli\bin\prismarine.dart >nul 2>&1
if errorlevel 1 (
  rem A package config of an older checkout can lack a package of the command.
  echo prismarine: resolving the packages of %ROOT% 1>&2
  "%DART%" pub get >nul
  "%DART%" compile kernel -o "%KERNEL%" packages\prismarine_cli\bin\prismarine.dart >nul
  if errorlevel 1 (
    popd
    exit /b 1
  )
)
popd
:run
"%DART%" "%KERNEL%" %*
exit /b %ERRORLEVEL%
