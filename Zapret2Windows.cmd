@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Zapret2Windows.ps1" %*
endlocal
