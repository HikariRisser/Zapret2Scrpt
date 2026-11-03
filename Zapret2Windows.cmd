@echo off
setlocal EnableExtensions
cd /d "%~dp0"

rem ============================================================
rem  Zapret2 Windows launcher
rem  Keeps the window open on error so the message is visible.
rem  NOTE: this file must stay ASCII-only. cmd.exe reads .cmd in
rem  the OEM code page, so UTF-8 Cyrillic would break parsing.
rem ============================================================

rem --- PowerShell must exist ---
where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo.
    echo   [ERROR] powershell.exe not found.
    echo   Windows PowerShell 5.1 is required ^(included in Windows 10/11^).
    echo   For Windows 7/8.1 install Windows Management Framework 5.1.
    echo.
    pause
    exit /b 1
)

rem --- The script must sit next to this launcher ---
if not exist "%~dp0Zapret2Windows.ps1" (
    echo.
    echo   [ERROR] Zapret2Windows.ps1 not found next to this launcher.
    echo   Expected: %~dp0Zapret2Windows.ps1
    echo.
    pause
    exit /b 1
)

chcp 65001 >nul 2>&1

rem --- Encoding guard: the .ps1 must be UTF-8 WITH BOM ---
rem Without BOM, Windows PowerShell 5.1 reads the file as ANSI,
rem Russian text breaks and the script dies before doing anything.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p='%~dp0Zapret2Windows.ps1'; $b=[IO.File]::ReadAllBytes($p); if($b.Length -lt 3 -or $b[0] -ne 239 -or $b[1] -ne 187 -or $b[2] -ne 191){ Write-Host ''; Write-Host '  [ERROR] Zapret2Windows.ps1 has no UTF-8 BOM.' -ForegroundColor Red; Write-Host ''; Write-Host '  Windows PowerShell 5.1 will read the file as ANSI,' -ForegroundColor Yellow; Write-Host '  the Russian text will break and the script will not start.' -ForegroundColor Yellow; Write-Host ''; Write-Host '  Fix: save Zapret2Windows.ps1 as UTF-8 with BOM' -ForegroundColor Cyan; Write-Host '       Notepad++  : Encoding - UTF-8-BOM'; Write-Host '       VS Code    : encoding UTF-8 with BOM'; Write-Host '  Or download the file again from the repository.' -ForegroundColor DarkGray; Write-Host ''; exit 2 }"
if errorlevel 2 (
    pause
    exit /b 2
)

rem --- Run ---
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Zapret2Windows.ps1" %*
set "RC=%ERRORLEVEL%"

rem --- Keep the window open when something failed ---
if not "%RC%"=="0" (
    echo.
    echo   [ERROR] Script exited with code %RC%
    echo   Read the error message above.
    echo.
    pause
)

endlocal
exit /b %RC%
