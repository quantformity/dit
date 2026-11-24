@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Build the dit CLI for Windows.
rem
rem   scripts\build.bat             build with the current version
rem   scripts\build.bat --inc-version
rem                                  increment the revision after a successful build

cd /d "%~dp0.."
if errorlevel 1 (
  echo Failed to change to the project root. 1>&2
  exit /b 1
)

where go >nul 2>&1
if errorlevel 1 (
  echo Go was not found on PATH. 1>&2
  exit /b 1
)

set "INC_VERSION=false"
if "%~1"=="--inc-version" (
  set "INC_VERSION=true"
  if not "%~2"=="" (
    echo Unexpected argument: %~2 1>&2
    exit /b 1
  )
) else if not "%~1"=="" (
  echo Usage: scripts\build.bat [--inc-version] 1>&2
  exit /b 1
)

set "CURRENT_VERSION="
set /p "CURRENT_VERSION=" < version.txt
powershell.exe -NoProfile -Command "$v=(Get-Content -Raw -LiteralPath 'version.txt').Trim(); if ($v -notmatch '^\d+\.\d+\.\d+$') { Write-Error ('invalid version in version.txt: ' + $v); exit 1 }"
if errorlevel 1 exit /b 1

set "VERSION=%CURRENT_VERSION%"
if "%INC_VERSION%"=="true" (
  for /f "usebackq delims=" %%V in (`powershell.exe -NoProfile -Command "$v='%CURRENT_VERSION%'; $p=$v -split '\.'; '{0}.{1}.{2}' -f $p[0],$p[1],([int]$p[2]+1)"`) do set "VERSION=%%V"
  if not defined VERSION (
    echo Failed to calculate the next version. 1>&2
    exit /b 1
  )
)

for /f "delims=" %%D in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd.HHmmss"') do set "BUILD_DATE=%%D"
if not defined BUILD_DATE (
  echo Failed to determine the build date. 1>&2
  exit /b 1
)

if not exist .build mkdir .build
set "TEMP_BINARY=.build\dit.exe.tmp-%RANDOM%"
set "OUTPUT=.build\dit.exe"

set "CGO_ENABLED=0"
go build -trimpath -ldflags "-X main.version=%VERSION% -X main.buildDate=%BUILD_DATE%" -o "%TEMP_BINARY%" ./cmd/dit
if errorlevel 1 (
  del /q "%TEMP_BINARY%" >nul 2>&1
  echo Build failed for windows/amd64 - nothing was published, version unchanged. 1>&2
  exit /b 1
)

move /y "%TEMP_BINARY%" "%OUTPUT%" >nul
if errorlevel 1 (
  del /q "%TEMP_BINARY%" >nul 2>&1
  echo Failed to publish %OUTPUT%. 1>&2
  exit /b 1
)

if "%INC_VERSION%"=="true" (
  >version.txt.tmp echo %VERSION%
  move /y version.txt.tmp version.txt >nul
  if errorlevel 1 (
    echo Build succeeded, but version.txt could not be updated. 1>&2
    exit /b 1
  )
)

echo Built dit %VERSION% (%BUILD_DATE%) -^> %OUTPUT%
exit /b 0
