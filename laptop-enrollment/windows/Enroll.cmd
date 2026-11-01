@echo off
REM USB launcher for Register-AutopilotDevice.ps1.
REM During Windows setup press Shift+F10, then run:  D:\Enroll.cmd CLIENTKEY
REM (replace D: with the USB drive letter; CLIENTKEY is a section in clients.cmd)

setlocal
if "%~1"=="" (
  echo Usage: Enroll.cmd CLIENTKEY [extra script options]
  echo Clients are defined in clients.cmd next to this file.
  exit /b 1
)

call "%~dp0clients.cmd" %1
if not defined TENANT (
  echo Unknown client "%1". Check clients.cmd.
  exit /b 1
)

if not exist "%~dp0hashes" mkdir "%~dp0hashes"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Register-AutopilotDevice.ps1" ^
  -TenantId "%TENANT%" -GroupTag "%GROUPTAG%" ^
  -OutputCsv "%~dp0hashes\%1.csv" -WaitForProfile -Reboot %2 %3 %4 %5 %6
