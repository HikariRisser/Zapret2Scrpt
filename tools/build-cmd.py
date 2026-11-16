#!/usr/bin/env python3
"""
Собирает Zapret2Windows.cmd из Zapret2Windows.ps1.

Оба файла - один и тот же скрипт: .cmd состоит из короткой шапки для cmd.exe и
полного текста .ps1. Правится только .ps1, после правки:

    python3 tools/build-cmd.py           # пересобрать Zapret2Windows.cmd
    python3 tools/build-cmd.py --check   # проверить, что .cmd соответствует .ps1
"""
import os
import sys

# На Windows stdout/stdin по умолчанию в локальной кодировке (cp1252/cp866):
# вывод кириллицы падает с UnicodeEncodeError, а чтение .ps1 без BOM может
# испортить текст. Принудительно UTF-8 для всех путей.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PS1 = os.path.join(ROOT, "Zapret2Windows.ps1")
CMD = os.path.join(ROOT, "Zapret2Windows.cmd")

# Шапка исполняется cmd.exe и должна быть только из ASCII: cmd читает файл в
# кодировке OEM. Для PowerShell вся шапка - блочный комментарий <# ... #>.
HEADER = r'''<# :
@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem ============================================================
rem  Zapret2 Windows: self-contained launcher + script.
rem  cmd.exe runs this header; PowerShell runs the rest of the
rem  file (for PowerShell the header is a block comment).
rem  No other files are needed next to this one.
rem  Generated from Zapret2Windows.ps1 by tools/build-cmd.py.
rem  Keep this header ASCII-only.
rem ============================================================
where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo.
    echo   [ERROR] powershell.exe not found.
    echo   Windows PowerShell 5.1 is required ^(included in Windows 10/11^).
    echo.
    pause
    exit /b 1
)
chcp 65001 >nul 2>&1
set "Z2_MENU="
if "%~1"=="" set "Z2_MENU=1"
set "ZAPRET2_SELF=%~f0"
set ZAPRET2_ARGS=%*
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& ([ScriptBlock]::Create([IO.File]::ReadAllText($env:ZAPRET2_SELF,[Text.Encoding]::UTF8)))"
set "RC=%ERRORLEVEL%"
rem Exit code 2: the script has already shown the error and waited for Enter.
if not "%RC%"=="0" if not "%RC%"=="2" if defined Z2_MENU (
    echo.
    echo   [ERROR] Script exited with code %RC%. Read the message above.
    echo.
    pause
)
endlocal & exit /b %RC%
#>
'''


def build():
    raw = open(PS1, "rb").read()
    if not raw.startswith(b"\xef\xbb\xbf"):
        sys.exit("Zapret2Windows.ps1: нет UTF-8 BOM")
    text = raw[3:].decode("utf-8").replace("\r\n", "\n")
    lines = text.split("\n")
    # "#requires" допустим только в файле .ps1; здесь код исполняется как блок.
    if lines and lines[0].lower().startswith("#requires"):
        lines = lines[1:]
    body = "\n".join(lines)
    assert HEADER.isascii(), "шапка должна быть из ASCII"
    assert "#>" not in HEADER[:-3], "в шапке не должно быть #>"
    out = (HEADER + body).replace("\n", "\r\n")
    return out.encode("utf-8")          # без BOM: cmd.exe споткнулся бы на нём


def main():
    data = build()
    if "--check" in sys.argv:
        if not os.path.isfile(CMD) or open(CMD, "rb").read() != data:
            sys.exit("Zapret2Windows.cmd не соответствует Zapret2Windows.ps1: запустите tools/build-cmd.py")
        print("Zapret2Windows.cmd соответствует Zapret2Windows.ps1")
        return
    with open(CMD, "wb") as f:
        f.write(data)
    print(f"Zapret2Windows.cmd собран: {len(data)} байт")


if __name__ == "__main__":
    main()
