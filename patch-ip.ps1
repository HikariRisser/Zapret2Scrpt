$ErrorActionPreference='Stop'
$p='C:\HarnessWorkspace\Zapret2Windows.ps1'
$t=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)

# --- 1) Хелперы: быстрый TCP-тест и разрешение CNAME ---
$helpers = @'
function Test-TcpQuick {
    param([string]$IP,[int]$Port=443,[int]$TimeoutMs=1200)
    try {
        $c=[Net.Sockets.TcpClient]::new()
        $ar=$c.BeginConnect($IP,$Port,$null,$null)
        $ok=$ar.AsyncWaitHandle.WaitOne($TimeoutMs)
        if($ok){ $c.EndConnect($ar) }
        $c.Dispose()
        return $ok
    } catch { return $false }
}

function Resolve-DohCname {
    param([string]$Name,[int]$TimeoutSec=5)
    foreach($p in $script:DohProviders){
        try {
            $sep=if($p -match '\?'){'&'}else{'?'}
            $r=Invoke-RestMethod -Uri "$p${sep}name=$Name&type=CNAME" `
                 -Headers @{accept='application/dns-json'} -TimeoutSec $TimeoutSec -ErrorAction Stop
            $c=@($r.Answer | Where-Object { $_.type -eq 5 } | ForEach-Object { $_.data -replace '\.$','' })
            if($c.Count){ return $c }
        } catch {}
    }
    return @()
}

function Get-WorkingIPFor {
    <#
      Возвращает первый РАБОЧИЙ IP домена.
      DoH может вернуть мёртвый edge-IP (типично для Meta/Instagram):
      пиннинг такого адреса в hosts ломает доступ, поэтому кандидаты
      проверяются TCP-соединением, а при неудаче подтягиваются CNAME-алиасы.
    #>
    param([string]$Domain,[int]$MaxCandidates=5)
    $cands=New-Object System.Collections.Generic.List[string]

    foreach($ip in @(Resolve-DohName -Name $Domain)){ if(-not $cands.Contains($ip)){$cands.Add($ip)} }

    # CNAME-алиасы: рабочие адреса часто лежат именно там
    foreach($cn in @(Resolve-DohCname -Name $Domain)){
        foreach($ip in @(Resolve-DohName -Name $cn)){ if(-not $cands.Contains($ip)){$cands.Add($ip)} }
        if($cands.Count -ge $MaxCandidates){break}
    }

    $tried=0
    foreach($ip in $cands){
        if($tried -ge $MaxCandidates){break}
        $tried++
        if(Test-TcpQuick -IP $ip -Port 443 -TimeoutMs 1200){ return $ip }
    }
    return $null
}

'@
$anchor='function Update-DohHosts {'
if($t.Contains($anchor)){ $t=$t.Replace($anchor,$helpers+$anchor); Write-Host 'хелперы: ok' } else { Write-Host 'хелперы: ЯКОРЬ НЕ НАЙДЕН'; exit 1 }

# --- 2) В цикле используем проверенный IP, а не первый из DoH ---
$oldLoop = @'
        $ips=@(Resolve-DohName -Name $d)
        if($ips.Count){
            $resolved.Add(("{0}`t{1}" -f $ips[0],$d))
            if(-not $Quiet){Write-Host $ips[0] -ForegroundColor Green}
        } else {
            $failed.Add($d)
            if(-not $Quiet){Write-Host 'нет ответа' -ForegroundColor DarkGray}
        }
'@
$newLoop = @'
        $ip=Get-WorkingIPFor -Domain $d
        if($ip){
            $resolved.Add(("{0}`t{1}" -f $ip,$d))
            if(-not $Quiet){Write-Host $ip -ForegroundColor Green}
        } else {
            # DoH дал адреса, но ни один не отвечает. Пиннинг мёртвого IP
            # только сломал бы доступ — оставляем домен системному DNS.
            $failed.Add($d)
            if(-not $Quiet){Write-Host 'нет рабочего IP' -ForegroundColor DarkGray}
        }
'@
if($t.Contains($oldLoop)){ $t=$t.Replace($oldLoop,$newLoop); Write-Host 'цикл: ok' } else { Write-Host 'цикл: НЕ НАЙДЕН'; exit 1 }

# --- 3) Понятнее отчёт ---
$oldRep = @'
        Write-Host ("  Без DoH-ответа: {0}" -f ($failed -join ', ')) -ForegroundColor DarkGray
'@
$newRep = @'
        Write-Host ("  Без рабочего IP: {0}" -f ($failed -join ', ')) -ForegroundColor DarkGray
        Write-Host '  Такие домены не пиннингуются: системный DNS остаётся как есть.' -ForegroundColor DarkGray
'@
if($t.Contains($oldRep)){ $t=$t.Replace($oldRep,$newRep); Write-Host 'отчёт: ok' } else { Write-Host 'отчёт: НЕ НАЙДЕН' }

[IO.File]::WriteAllText($p,$t,(New-Object Text.UTF8Encoding $true))
Write-Host 'Готово'
