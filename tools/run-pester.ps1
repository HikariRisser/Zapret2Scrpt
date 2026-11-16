# Запуск Pester-тестов чистых функций Zapret2Windows.ps1.
#
# powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-pester.ps1
#
# Скрипт загружается ДО финального try/switch (только определения функций и
# константы; побочных эффектов нет), затем запускаются тесты из tests/.
# Совместим с Pester 4 (Windows PowerShell 5.1) и Pester 5 (pwsh, CI).

param([string]$Ps1Path)

$ErrorActionPreference = 'Stop'

# В 5.1 встроен Pester 3 - нужен 4+. -SkipPublisherCheck: bundled Pester 3 подписан Microsoft.
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 4 })) {
    Write-Host 'Установка Pester (Scope CurrentUser)...'
    try { Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
    Install-Module Pester -Force -Scope CurrentUser -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 4.0.0
$pesterMajor = (Get-Module Pester).Version.Major

# $PSScriptRoot при -File - каталог скрипта; если пуст (некоторые способы
# вызова), берём каталог из $MyInvocation. Путь нормализуем через
# Resolve-Path: на Windows "tools\..\X.ps1" обязан превратиться в реальный
# абсолютный путь, иначе ReadAllText молча вернёт не то (или бросит).
if (-not $Ps1Path) {
    $here = $PSScriptRoot
    if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Ps1Path = Join-Path $here '..\Zapret2Windows.ps1'
}
$Ps1Full = [IO.Path]::GetFullPath($Ps1Path)
if (-not (Test-Path -LiteralPath $Ps1Full)) {
    throw "Не найден файл скрипта: $Ps1Full (передан путь '$Ps1Path')"
}

# Get-Content -Raw: кодировку (UTF-8 с BOM) определяет сам PowerShell.
$text = Get-Content -LiteralPath $Ps1Full -Raw
if (-not $text) { throw "Файл $Ps1Full прочитан как пустой" }
# Убираем BOM: он сдвигает индекс, если якорь оказался в самом начале.
$text = $text.TrimStart([char]0xFEFF)

# Якорь ищем по regex: точная строка зависит от переводов строк (CRLF/LF),
# а умножать хрупкость не нужно. Ищем последний "try {", за которым идёт
# "switch($Action){" - это и есть диспетчер действий.
$m = [regex]::Match($text, '(?s)try\s*\{\s*switch\(\$Action\)\s*\{')
if (-not $m.Success) {
    throw "В $Ps1Full не найден блок диспетчера действий (switch(`$Action))"
}
$idx = $m.Index

$head = $text.Substring(0, $idx)
# $env:TEMP бывает пуст вне Windows (локальная проверка в pwsh) - тогда системный tmp.
$tmpRoot = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
$tmp = Join-Path $tmpRoot 'zapret2-test-definitions.ps1'
[IO.File]::WriteAllText($tmp, $head, (New-Object Text.UTF8Encoding $true))

. $tmp -Action Status

# Путь к .ps1 нужен тесту инвариантов; области видимости Pester надёжнее
# пробрасывать через окружение.
$env:Z2_PS1_PATH = $Ps1Full

$testsPath = Join-Path (Split-Path -Parent $Ps1Full) 'tests\Zapret2Windows.Tests.ps1'
if (-not (Test-Path -LiteralPath $testsPath)) {
    throw "Не найдены тесты: $testsPath"
}
if ($pesterMajor -ge 5) {
    $container = New-PesterContainer -Path $testsPath
    $result = Invoke-Pester -Container $container -PassThru -Output Detailed
} else {
    $result = Invoke-Pester -Script $testsPath -PassThru -Quiet
}
exit $result.FailedCount
