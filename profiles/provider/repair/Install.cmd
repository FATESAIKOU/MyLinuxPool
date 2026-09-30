@echo off
rem Install.cmd -- double-click entry for the family repair-host bundle.
rem (openspec/changes/archive/2026-10-01-family-repair-host tasks 8d.3)
rem
rem Why this file exists: on a normal family Windows, double-clicking the
rem .ps1 only opens an editor (store App file association) and the default
rem Restricted policy would refuse to run it anyway. A .cmd runs on
rem double-click; it only starts powershell with Bypass for THIS file.
rem UAC is NOT handled here: the installer re-launches itself elevated
rem (one "Yes") when it needs admin, with its own guidance on screen.
rem
rem ASCII only on purpose: cmd reads this file in the system codepage, so
rem anything non-ASCII would show as mojibake. The Chinese instructions live
rem in README-FAMILY.txt and in the installer's own messages.
rem Quoting: "%~dp0..." survives spaces in the path (e.g. a Desktop folder
rem whose user name has spaces). Extra arguments are forwarded (%*), so the
rem owner can test with e.g. Install.cmd -DataDir C:\mlp-test\data.
setlocal
set RC=0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-RepairHost.ps1" %*
set RC=%ERRORLEVEL%
if %RC% neq 0 (
  echo INSTALL FAILED, exit code %RC%. Keep this window and tell the person who gave you this package.
) else (
  echo Install finished. You can close this window.
)
pause
exit /b %RC%
