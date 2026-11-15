# Запуск Pester-тестов чистых функций Zapret2Windows.ps1.
#
# powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-pester.ps1
#
# Скрипт загружается ДО финального try/switch (только определения функций и
# константы; побочных эффектов нет), затем запускаются тесты из tests/.
# Совместим с Pester 4 (Windows PowerShell 5.1) и Pester 5 (pwsh, CI).

param([string]$Ps1Path = (Join-Path $PSScriptRoot '..\Zapret2Windows.ps1'))

$ErrorActionPreference = 'Stop'

# В 5.1 встроен Pester 3 - нужен 4+. -SkipPublisherCheck: bundled Pester 3 подписан Microsoft.
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 4 })) {
    Write-Host 'Установка Pester (Scope CurrentUser)...'
    try { Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
    Install-Module Pester -Force -Scope CurrentUser -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 4.0.0
$pesterMajor = (Get-Module Pester).Version.Major

$text = [IO.File]::ReadAllText($Ps1Path)
$idx = $text.IndexOf("try {`r`nswitch(`$Action){")
if ($idx -lt 0) { $idx = $text.IndexOf("try {`nswitch(`$Action){") }
if ($idx -lt 0) { throw 'В Zapret2Windows.ps1 не найден блок диспетчера действий' }

$head = $text.Substring(0, $idx)
# $env:TEMP бывает пуст вне Windows (локальная проверка в pwsh) - тогда системный tmp.
$tmpRoot = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
$tmp = Join-Path $tmpRoot 'zapret2-test-definitions.ps1'
[IO.File]::WriteAllText($tmp, $head, (New-Object Text.UTF8Encoding $true))

. $tmp -Action Status

# Путь к .ps1 нужен тесту инвариантов; области видимости Pester надёжнее
# пробрасывать через окружение.
$env:Z2_PS1_PATH = [IO.Path]::GetFullPath($Ps1Path)

$testsPath = Join-Path $PSScriptRoot '..\tests\Zapret2Windows.Tests.ps1'
if ($pesterMajor -ge 5) {
    $container = New-PesterContainer -Path $testsPath
    $result = Invoke-Pester -Container $container -PassThru -Output Detailed
} else {
    $result = Invoke-Pester -Script $testsPath -PassThru -Quiet
}
exit $result.FailedCount
