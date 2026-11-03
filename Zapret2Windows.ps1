#requires -Version 5.1
<#
.SYNOPSIS
  Системный контроллер zapret2 (winws2) для Windows.
.DESCRIPTION
  Устанавливает официальные winws2/WinDivert/Lua из релиза zapret2 в локальную
  среду, включает DPI-десинхронизацию для всех приложений через полный
  перехват WinDivert, использует автообучаемый автосписок доменов и управляет
  задачей автозапуска при входе в систему.

  Это средство обхода DPI, а не VPN. Оно не создаёт маршрут в обход
  IP/маршрутизационных блокировок: для них нужен доступный внешний туннель
  или иной VPN-endpoint.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu','Install','Start','Stop','Status','Diagnose','DohHosts','Uninstall','Purge')]
    [string]$Action='Menu',
    [string]$ZapretRoot = (Join-Path $PSScriptRoot 'zapret2-v1.0.6'),
    [switch]$NoAutostart,
    [switch]$KeepLogs,        # с Uninstall/Purge: сохранить копию логов
    [switch]$IncludeProject,  # с Uninstall/Purge: удалить и runtime рабочей папки
    [switch]$Force            # с Uninstall/Purge: без запроса подтверждения
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false) } catch {}
$script:AppRoot=$PSScriptRoot
$script:Runtime=Join-Path $script:AppRoot 'runtime\winws2'
$script:TrustedRuntime=Join-Path $env:SystemRoot 'System32\Zapret2Windows'
$script:TaskName='Zapret2Windows'
$script:BinSource=$null
$script:Arch=$null

function Test-Admin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Ensure-Admin {
    if(Test-Admin){return}
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-Action',$Action,'-ZapretRoot',('"{0}"' -f $ZapretRoot))
    if($NoAutostart){$args+='-NoAutostart'}
    Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs | Out-Null
    exit
}
function Find-Source {
    if(-not (Test-Path $ZapretRoot)){throw "Не найден исходный релиз zapret2: $ZapretRoot"}
    $p=Get-CimInstance Win32_OperatingSystem
    if([Environment]::Is64BitOperatingSystem){$arch='windows-x86_64'}else{$arch='windows-x86'}
    $bin=Join-Path $ZapretRoot "binaries\$arch"
    if(-not (Test-Path (Join-Path $bin 'winws2.exe'))){throw "В bundled release нет winws2 для $arch"}
    foreach($f in @('winws2.exe','WinDivert.dll','cygwin1.dll','WinDivert64.sys')){
        if($f -eq 'WinDivert64.sys' -and $arch -eq 'windows-x86'){continue}
        if(-not (Test-Path (Join-Path $bin $f))){throw "В релизе отсутствует $f"}
    }
    $script:Arch=$arch; $script:BinSource=$bin
}
function Fix-DriverService {
    <#
      WinDivert регистрирует службу ядра по тому каталогу, откуда запущен winws2.
      Если служба уже указывает на незащищённый каталог (например, на рабочую
      папку проекта), пересоздаём её: тогда драйвер ядра будет загружаться
      из System32\Zapret2Windows, куда обычные пользователи писать не могут.
    #>
    $svc=Get-CimInstance Win32_SystemDriver -Filter "Name='WinDivert'" -ErrorAction SilentlyContinue
    if(-not $svc){return}
    $cur=($svc.PathName -replace '^\\\?\?\\','')
    $want=Join-Path $script:TrustedRuntime 'WinDivert64.sys'
    if($cur -ieq $want){return}
    Write-Host "  Перерегистрация драйвера WinDivert:" -ForegroundColor Yellow
    Write-Host "    было:  $cur" -ForegroundColor DarkGray
    Write-Host "    станет: $want" -ForegroundColor DarkGray
    Stop-Zapret -Quiet
    & sc.exe stop WinDivert | Out-Null
    Start-Sleep -Seconds 2
    & sc.exe delete WinDivert | Out-Null
    Start-Sleep -Seconds 2
    Write-Host '    служба удалена; будет создана заново из защищённого каталога при старте.' -ForegroundColor DarkGray
}
function Get-Upstream {
    <#
      Скачивает официальный релиз zapret2 с GitHub, если его нет рядом со скриптом.
      Нужно для чистой копии репозитория: бинарники upstream не хранятся в git.
    #>
    param([string]$Version='v1.0.6')
    if(Test-Path $ZapretRoot){return}
    $dl=Join-Path $script:AppRoot 'runtime\download'
    New-Item -ItemType Directory -Path $dl -Force | Out-Null
    $zip=Join-Path $dl "zapret2-$Version.zip"
    $url="https://github.com/bol-van/zapret2/releases/download/$Version/zapret2-$Version.zip"
    Write-Host "  Скачивание zapret2 $Version с GitHub..." -ForegroundColor Yellow
    Write-Host "    $url" -ForegroundColor DarkGray
    try {
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
    } catch {
        throw ("Не удалось скачать релиз. Скачайте вручную и распакуйте в: $ZapretRoot`n" + $_.Exception.Message)
    }
    Write-Host '  Распаковка...' -ForegroundColor Yellow
    Expand-Archive -LiteralPath $zip -DestinationPath $dl -Force
    $dir=Get-ChildItem $dl -Directory -ErrorAction SilentlyContinue |
         Where-Object { Test-Path (Join-Path $_.FullName 'binaries') } | Select-Object -First 1
    if(-not $dir){throw "В архиве не найден каталог с binaries: $zip"}
    if(Test-Path $ZapretRoot){Remove-Item $ZapretRoot -Recurse -Force}
    Move-Item $dir.FullName $ZapretRoot -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Write-Host "  Релиз распакован в: $ZapretRoot" -ForegroundColor Green
}
function Install-Runtime {
    Ensure-Admin
    if(-not (Test-Path $ZapretRoot)){Get-Upstream}
    Find-Source
    # Останавливаем работающий экземпляр: иначе занятый winws2.exe не заменить.
    Stop-Zapret -Quiet
    # Драйвер ядра загружен из боевого каталога и удерживает WinDivert64.sys.
    # Выгружаем службу, иначе файл нельзя заменить при обновлении.
    # Служба создастся заново при следующем запуске.
    $drvSvc=Get-CimInstance Win32_SystemDriver -Filter "Name='WinDivert'" -ErrorAction SilentlyContinue
    if($drvSvc){
        & sc.exe stop WinDivert | Out-Null
        Start-Sleep -Seconds 2
        & sc.exe delete WinDivert | Out-Null
        Start-Sleep -Seconds 2
    }
    $dirs=@($script:Runtime,(Join-Path $script:Runtime 'lua'),(Join-Path $script:Runtime 'lists'),(Join-Path $script:Runtime 'logs'))
    foreach($d in $dirs){New-Item -ItemType Directory -Path $d -Force | Out-Null}
    foreach($f in @('winws2.exe','WinDivert.dll','cygwin1.dll','WinDivert64.sys')){
        if($f -eq 'WinDivert64.sys' -and $script:Arch -eq 'windows-x86'){continue}
        Copy-Item (Join-Path $script:BinSource $f) (Join-Path $script:Runtime $f) -Force
    }
    Copy-Item (Join-Path $ZapretRoot 'lua\zapret-lib.lua') (Join-Path $script:Runtime 'lua\zapret-lib.lua') -Force
    Copy-Item (Join-Path $ZapretRoot 'lua\zapret-antidpi.lua') (Join-Path $script:Runtime 'lua\zapret-antidpi.lua') -Force
    Copy-Item (Join-Path $ZapretRoot 'lua\zapret-auto.lua') (Join-Path $script:Runtime 'lua\zapret-auto.lua') -Force
    $wfSource=Join-Path $ZapretRoot 'init.d\windivert.filter.examples'
    $wfDest=Join-Path $script:Runtime 'windivert.filter'
    New-Item -ItemType Directory -Path $wfDest -Force | Out-Null
    foreach($f in @('windivert_part.discord_media.txt','windivert_part.stun.txt','windivert_part.wireguard.txt')){
        Copy-Item (Join-Path $wfSource $f) (Join-Path $wfDest $f) -Force
    }
    $allDomains=@(
      'discord.com','discord.gg','discordapp.com','discordapp.net','discord.media','discordcdn.com',
      'rutracker.org','youtube.com','youtu.be','googlevideo.com','ytimg.com',
      'instagram.com','facebook.com','fbcdn.net','fbsbx.com','threads.net',
      'x.com','twitter.com','twimg.com','t.me','telegram.org','telegram.me',
      'reddit.com','redditstatic.com','redd.it','tiktok.com','tiktokcdn.com',
      'github.com','githubusercontent.com','githubassets.com','cloudflare.com','cloudflare-dns.com',
      'medium.com','soundcloud.com','spotify.com','twitch.tv','ttvnw.net'
    ) | Sort-Object -Unique
    $blockedW=Join-Path $script:Runtime 'lists\blocked.txt'
    if(-not (Test-Path $blockedW)){
        [IO.File]::WriteAllLines($blockedW,$allDomains,[Text.UTF8Encoding]::new($false))
    }

    # --- Безопасность: всё боевое переносим в каталог, доступный на запись
    # только Administrators/SYSTEM. Рабочая папка проекта может быть
    # доступна на запись другим пользователям, поэтому winws2 не должен
    # загружать оттуда Lua/списки/фильтры и не должен брать оттуда драйвер.
    New-Item -ItemType Directory -Path $script:TrustedRuntime -Force | Out-Null
    foreach($f in @('winws2.exe','WinDivert.dll','cygwin1.dll','WinDivert64.sys')){
        $src=Join-Path $script:Runtime $f
        if(-not (Test-Path $src)){continue}
        $dst=Join-Path $script:TrustedRuntime $f
        # Повтор на случай, если ОС ещё держит файл после остановки процесса.
        for($try=1; $try -le 6; $try++){
            try { Copy-Item $src $dst -Force -ErrorAction Stop; break }
            catch {
                if($try -eq 6){throw "Не удалось заменить $f (файл занят). Остановите winws2 и повторите."}
                Start-Sleep -Milliseconds 700
            }
        }
    }
    Copy-Item (Join-Path $script:Runtime 'lua') (Join-Path $script:TrustedRuntime 'lua') -Recurse -Force
    Copy-Item (Join-Path $script:Runtime 'windivert.filter') (Join-Path $script:TrustedRuntime 'windivert.filter') -Recurse -Force
    foreach($d in @('lists','logs')){New-Item -ItemType Directory -Path (Join-Path $script:TrustedRuntime $d) -Force | Out-Null}

    # Списки живут в защищённом каталоге. Существующие (в т.ч. выученные
    # autohostlist) не перезаписываем.
    $blocked=Join-Path $script:TrustedRuntime 'lists\blocked.txt'
    if(-not (Test-Path $blocked)){
        [IO.File]::WriteAllLines($blocked,$allDomains,[Text.UTF8Encoding]::new($false))
    }
    $exclude=Join-Path $script:TrustedRuntime 'lists\exclude.txt'
    if(-not (Test-Path $exclude)){
        [IO.File]::WriteAllLines($exclude,@('localhost','local','example.com'),[Text.UTF8Encoding]::new($false))
    }
    $auto=Join-Path $script:TrustedRuntime 'lists\autohostlist.txt'
    if(-not (Test-Path $auto)){[IO.File]::WriteAllText($auto,'',[Text.UTF8Encoding]::new($false))}

    Write-LaunchConfig
    Fix-DriverService
    # DNS-блок не лечится десинхронизацией: разрешаем имена через DoH.
    Update-DohHosts -Quiet
    if(-not $NoAutostart){Install-Autostart}
    Write-Host "Среда установлена ($($script:Arch))" -ForegroundColor Green
    Write-Host "Боевой каталог: $script:TrustedRuntime" -ForegroundColor DarkGray
    Write-Host 'Права: Администраторы/SYSTEM — полный доступ, Пользователи — только чтение.' -ForegroundColor DarkGray
}
function Write-LaunchConfig {
    # Конфиг и все ресурсы берутся из ЗАЩИЩЁННОГО каталога (System32),
    # а не из рабочей папки проекта, которая может быть доступна на запись
    # обычным пользователям (защита от подмены Lua/списков/фильтров).
    $cfg=Join-Path $script:TrustedRuntime 'winws2.args'
    $lua=Join-Path $script:TrustedRuntime 'lua'
    $lists=Join-Path $script:TrustedRuntime 'lists'
    $wf=Join-Path $script:TrustedRuntime 'windivert.filter'
    $args=@(
      '--wf-tcp-out=80,443','--wf-tcp-in=80,443','--wf-udp-out=443','--wf-udp-in=443','--wf-tcp-empty=1',
      "--wf-raw-part=@$(Join-Path $wf 'windivert_part.discord_media.txt')",
      "--wf-raw-part=@$(Join-Path $wf 'windivert_part.stun.txt')",
      "--wf-raw-part=@$(Join-Path $wf 'windivert_part.wireguard.txt')",
      "--lua-init=@$(Join-Path $lua 'zapret-lib.lua')",
      "--lua-init=@$(Join-Path $lua 'zapret-antidpi.lua')",
      '--hostlist-auto-fail-threshold=3','--hostlist-auto-fail-time=60',
      '--hostlist-auto-retrans-threshold=3','--hostlist-auto-retrans-reset=1',
      '--hostlist-auto-incoming-maxseq=32768','--hostlist-auto-retrans-maxseq=32768',
      "--filter-tcp=80","--filter-l7=http", "--hostlist=$(Join-Path $lists 'blocked.txt')",
      "--hostlist-auto=$(Join-Path $lists 'autohostlist.txt')","--hostlist-exclude=$(Join-Path $lists 'exclude.txt')",
      '--out-range=-d10','--payload=http_req',
      '--lua-desync=fake:blob=fake_default_http:tcp_md5',
      '--lua-desync=multisplit:pos=method+2','--new',
      '--filter-tcp=443','--filter-l7=tls',"--hostlist=$(Join-Path $lists 'blocked.txt')",
      "--hostlist-auto=$(Join-Path $lists 'autohostlist.txt')","--hostlist-exclude=$(Join-Path $lists 'exclude.txt')",
      '--out-range=-d10','--payload=tls_client_hello',
      '--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=6',
      '--lua-desync=multidisorder:pos=1,midsld','--new',
      '--filter-udp=443','--filter-l7=quic',"--hostlist=$(Join-Path $lists 'blocked.txt')",
      "--hostlist-auto=$(Join-Path $lists 'autohostlist.txt')","--hostlist-exclude=$(Join-Path $lists 'exclude.txt')",
      '--payload=quic_initial','--lua-desync=fake:blob=fake_default_quic:repeats=6','--new',
      # Голос/медиа Discord: IP-discovery (STUN-подобный) и STUN/WireGuard.
      # Официальная схема zapret2 (init.d/custom.d.examples.*/50-discord-media,
      # 50-stun4all, 50-wg4all): fake с нулевым блобом, repeats=2.
      # Фильтровать по hostlist здесь нельзя - в UDP-медиа нет SNI.
      '--filter-l7=stun,discord,wireguard',
      '--payload=stun,discord_ip_discovery,wireguard_initiation,wireguard_cookie',
      '--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
    )
    [IO.File]::WriteAllLines($cfg,$args,[Text.UTF8Encoding]::new($false))
}
function Start-Zapret {
    Ensure-Admin
    if(-not (Test-Path (Join-Path $script:TrustedRuntime 'winws2.exe'))){Install-Runtime}
    Stop-Zapret -Quiet
    if(-not (Test-Path (Join-Path $script:TrustedRuntime 'winws2.exe'))){Install-Runtime}
    $exe=Join-Path $script:TrustedRuntime 'winws2.exe'
    $cfg=Join-Path $script:TrustedRuntime 'winws2.args'
    $out=Join-Path $script:TrustedRuntime 'logs\stdout.log'; $err=Join-Path $script:TrustedRuntime 'logs\stderr.log'
    $p=Start-Process -FilePath $exe -ArgumentList "@$cfg" -WorkingDirectory $script:TrustedRuntime -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    Start-Sleep -Seconds 3
    if($p.HasExited){
        $detail=''; if(Test-Path $err){$detail=(Get-Content $err -Tail 20 -ErrorAction SilentlyContinue)-join "`n"}
        throw "winws2 завершился при запуске. Проверьте журнал: $err`n$detail"
    }
    [IO.File]::WriteAllText((Join-Path $script:TrustedRuntime 'winws2.pid'),[string]$p.Id,[Text.Encoding]::ASCII)
    Write-Host "winws2 запущен, PID $($p.Id). WinDivert обрабатывает сетевой трафик системы." -ForegroundColor Green
    Write-Host 'Автосписок включён: домен добавится после сигналов неуспешного доступа.' -ForegroundColor DarkGray
}
function Stop-Zapret {
    param([switch]$Quiet)
    $pidFile=Join-Path $script:TrustedRuntime 'winws2.pid'
    if(Test-Path $pidFile){
        $id=0; [void][int]::TryParse((Get-Content $pidFile -Raw),[ref]$id)
        if($id -gt 0){Get-Process -Id $id -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq (Join-Path $script:TrustedRuntime 'winws2.exe')} | Stop-Process -Force -ErrorAction SilentlyContinue}
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    # Надёжная остановка: ищем процесс по пути запуска. PID-файл может
    # отсутствовать или устареть (например, после переноса каталога),
    # а занятый winws2.exe не даст обновить файлы.
    $exe=Join-Path $script:TrustedRuntime 'winws2.exe'
    # Ждём фактического завершения: иначе занятый winws2.exe не заменить
    # при обновлении (гонка между kill и последующим Copy-Item).
    for($i=0; $i -lt 12; $i++){
        $procs=@(Get-CimInstance Win32_Process -Filter "Name='winws2.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.ExecutablePath -eq $exe })
        if(-not $procs.Count){break}
        $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 400
    }
    if(-not $Quiet){Write-Host 'winws2 остановлен.' -ForegroundColor Yellow}
}
function Get-Status {
    $p=Get-CimInstance Win32_Process -Filter "Name='winws2.exe'" -ErrorAction SilentlyContinue | Where-Object {$_.ExecutablePath -eq (Join-Path $script:TrustedRuntime 'winws2.exe')}
    [pscustomobject]@{
        Running=[bool]$p; Pid=if($p){$p.ProcessId}else{$null};
        Runtime=(Test-Path (Join-Path $script:TrustedRuntime 'winws2.exe'));
        AutoStart=[bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue);
        LearnedDomains=if(Test-Path (Join-Path $script:TrustedRuntime 'lists\autohostlist.txt')){@(Get-Content (Join-Path $script:TrustedRuntime 'lists\autohostlist.txt')|Where-Object {$_ -and $_ -notmatch '^\s*#'}).Count}else{0}
    }
}
function Show-Status {
    <#
      Русские подписи состояния (вместо Format-List с английскими именами полей).
    #>
    $st=Get-Status
    Write-Host ''
    Write-Host '  Состояние Zapret2 Windows' -ForegroundColor Cyan
    Write-Host ('    winws2:          ' + $(if($st.Running){"работает, PID $($st.Pid)"}else{'остановлен'})) `
        -ForegroundColor $(if($st.Running){'Green'}else{'Red'})
    Write-Host ('    среда:           ' + $(if($st.Runtime){'установлена'}else{'не установлена'})) `
        -ForegroundColor $(if($st.Runtime){'Green'}else{'Red'})
    Write-Host ('    автозапуск:      ' + $(if($st.AutoStart){'включён'}else{'выключен'})) `
        -ForegroundColor $(if($st.AutoStart){'Yellow'}else{'DarkGray'})
    Write-Host ('    выучено доменов: ' + $st.LearnedDomains) -ForegroundColor DarkGray
    Write-Host ''
}
function Install-Autostart {
    Ensure-Admin
    $scriptPath=$PSCommandPath
    $act=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Action Start -NoAutostart"
    $trg=New-ScheduledTaskTrigger -AtLogOn
    $pr=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $script:TaskName -Action $act -Trigger $trg -Principal $pr -Force | Out-Null
}
function Remove-Autostart {
    Ensure-Admin
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
}
function Test-Tcp443 {
    param([string]$HostName)
    try { $tcp=[Net.Sockets.TcpClient]::new(); $ar=$tcp.BeginConnect($HostName,443,$null,$null); $ok=$ar.AsyncWaitHandle.WaitOne(3000); if($ok){$tcp.EndConnect($ar)}; $tcp.Dispose(); return $ok } catch { return $false }
}
function Diagnose {
    $st=Get-Status
    Write-Host "winws2: $(if($st.Running){'работает'}else{'остановлен'}), PID=$($st.Pid)" -ForegroundColor $(if($st.Running){'Green'}else{'Red'})
    Write-Host ("Среда: " + $(if($st.Runtime){'установлена'}else{'не установлена'}) + "; автозапуск: " + $(if($st.AutoStart){'включён'}else{'выключен'}) + "; выучено доменов: $($st.LearnedDomains)")
    foreach($d in @('discord.com','rutracker.org','www.youtube.com','telegram.org')){
        $tcp=Test-Tcp443 $d
        $code='000'
        if(Get-Command curl.exe -ErrorAction SilentlyContinue){
            $cmdLine = 'curl.exe -sS -o NUL -L --max-time 8 -A "Mozilla/5.0" -w "%{http_code}" https://' + $d + '/ 2>NUL'
            $r = & cmd.exe /c $cmdLine
            if($r){$code=($r|Out-String).Trim()}
        }
        $class=if(-not $tcp){'TCP недоступен: нужен внешний маршрут'}elseif($code -eq '200'){'HTTP 200'}elseif($st.Running){'сбой DPI или протокола; смотрите журнал'}else{'ещё не проверялось с обходом'}
        Write-Host ("{0,-24} TCP443={1,-5} HTTP={2,-5} {3}" -f $d,$tcp,$code,$class)
    }
    $err=Join-Path $script:TrustedRuntime 'logs\stderr.log'
    if(Test-Path $err){Write-Host "Журнал: $err" -ForegroundColor DarkGray; Get-Content $err -Tail 12}
    Write-Host 'Важно: код 200 подтверждает только эти запросы и не доказывает, что работают все протоколы и приложения.' -ForegroundColor Yellow
}
function Show-Menu {
    while($true){
        Clear-Host
        Write-Host 'Zapret2 Windows — системная DPI-десинхронизация' -ForegroundColor Cyan
        Write-Host 'Релиз: bol-van/zapret2 v1.0.6; полный перехват портов через WinDivert' -ForegroundColor DarkGray
        $st=Get-Status
        Write-Host ('  winws2: ' + $(if($st.Running){"работает, PID $($st.Pid)"}else{'остановлен'}) + ' | автозапуск: ' + $(if($st.AutoStart){'включён'}else{'выключен'}) + " | выучено доменов: $($st.LearnedDomains)")
        Write-Host ''
        Write-Host '[1] Установить или обновить среду'
        Write-Host '[2] Запустить системный обход'
        Write-Host '[3] Остановить'
        Write-Host '[4] Диагностика ресурсов'
        Write-Host '[5] Включить автозапуск при входе'
        Write-Host '[6] Выключить автозапуск'
        Write-Host '[7] Показать выученные домены'
        Write-Host '[8] Открыть каталог журналов'
        Write-Host '[9] Удалить из системы (драйвер, задача, среда, hosts)' -ForegroundColor Yellow
        Write-Host '[10] Обновить DNS через DoH (hosts)'
        Write-Host '[0] Выход'
        $choice=Read-Host '  Выбор'
        try {
            switch($choice){
                '1' {Install-Runtime; Read-Host '  Нажмите Enter'}
                '2' {Start-Zapret; Read-Host '  Нажмите Enter'}
                '3' {Stop-Zapret; Read-Host '  Нажмите Enter'}
                '4' {Diagnose; Read-Host '  Нажмите Enter'}
                '5' {Install-Autostart; Write-Host 'Автозапуск включён.' -ForegroundColor Green; Read-Host '  Нажмите Enter'}
                '6' {Remove-Autostart; Write-Host 'Автозапуск выключен.' -ForegroundColor Yellow; Read-Host '  Нажмите Enter'}
                '7' { $f=Join-Path $script:TrustedRuntime 'lists\autohostlist.txt'; if(Test-Path $f){Get-Content $f}else{Write-Host 'Среда не установлена'}; Read-Host '  Нажмите Enter' }
                '8' {if(Test-Path (Join-Path $script:TrustedRuntime 'logs')){Start-Process explorer.exe (Join-Path $script:TrustedRuntime 'logs')}else{Write-Host 'Сначала установите среду'}; Read-Host '  Нажмите Enter'}
                '9' {Remove-All}
                '10' {Update-DohHosts; Read-Host '  Нажмите Enter'}
                '0' {return}
            }
        } catch {Write-Host ("ОШИБКА: " + $_.Exception.Message) -ForegroundColor Red; Read-Host '  Нажмите Enter'}
    }
}

# ============================================================================
#  Разрешение имён через DoH (обход DNS-подмены и DNS-блокировок).
#  DPI-десинхронизация не помогает, если провайдер вообще не отдаёт IP.
#  Адреса из DoH пишутся в hosts размеченным блоком, который полностью
#  удаляется командой Uninstall.
# ============================================================================
$script:DohProviders=@(
    'https://cloudflare-dns.com/dns-query',
    'https://dns.google/resolve',
    'https://dns.quad9.net/dns-query'
)

function Resolve-DohName {
    param([string]$Name,[int]$TimeoutSec=6)
    foreach($p in $script:DohProviders){
        try {
            $sep=if($p -match '\?'){'&'}else{'?'}
            $u="$p${sep}name=$Name&type=A"
            $r=Invoke-RestMethod -Uri $u -Headers @{accept='application/dns-json'} -TimeoutSec $TimeoutSec -ErrorAction Stop
            $ips=@($r.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data } |
                   Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
            if($ips.Count){return $ips}
        } catch {}
    }
    return @()
}

function Update-DohHosts {
    param([switch]$Quiet)
    Ensure-Admin
    $hf=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $listFile=Join-Path $script:TrustedRuntime 'lists\blocked.txt'
    if(-not (Test-Path $listFile)){
        Write-Host '  Списки не установлены. Сначала выполните установку (пункт [1]).' -ForegroundColor Red
        return
    }
    $domains=@(Get-Content $listFile -ErrorAction SilentlyContinue |
               Where-Object { $_ -and $_ -notmatch '^\s*#' } |
               ForEach-Object { $_.Trim() } | Select-Object -Unique)
    if(-not $domains.Count){Write-Host '  Список доменов пуст.' -ForegroundColor Yellow; return}
    # hosts сопоставляет ТОЧНОЕ имя, поэтому www-вариант разрешаем отдельно:
    # запись youtube.com не покрывает www.youtube.com.
    $targets=New-Object System.Collections.Generic.List[string]
    foreach($d in $domains){
        $targets.Add($d)
        if($d -notmatch '^www\.'){$targets.Add("www.$d")}
    }
    $domains=@($targets | Select-Object -Unique)

    if(-not $Quiet){Write-Host ("  DoH-разрешение {0} доменов..." -f $domains.Count) -ForegroundColor Yellow}
    $resolved=New-Object System.Collections.Generic.List[string]
    $failed=New-Object System.Collections.Generic.List[string]
    $i=0
    foreach($d in $domains){
        $i++
        if(-not $Quiet){Write-Host ("    [{0}/{1}] {2,-34} " -f $i,$domains.Count,$d) -NoNewline}
        $ips=@(Resolve-DohName -Name $d)
        if($ips.Count){
            $resolved.Add(("{0}`t{1}" -f $ips[0],$d))
            if(-not $Quiet){Write-Host $ips[0] -ForegroundColor Green}
        } else {
            $failed.Add($d)
            if(-not $Quiet){Write-Host 'нет ответа' -ForegroundColor DarkGray}
        }
    }

    # Удаляем прежние блоки (наш и от прежней итерации проекта), пишем новый.
    $null=Remove-HostsEntries
    $lines=New-Object System.Collections.Generic.List[string]
    foreach($l in @(Get-Content -LiteralPath $hf -ErrorAction SilentlyContinue)){$lines.Add($l)}
    if($lines.Count -and $lines[$lines.Count-1].Trim() -ne ''){$lines.Add('')}
    $lines.Add('# --- Zapret2Windows DoH begin ---')
    $lines.Add('# Разрешено через DoH. Удаляется командой: -Action Uninstall')
    foreach($l in $resolved){$lines.Add($l)}
    $lines.Add('# --- Zapret2Windows DoH end ---')
    Copy-Item -LiteralPath $hf -Destination "$hf.zapret-backup" -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllLines($hf,$lines,[Text.Encoding]::ASCII)
    & ipconfig.exe /flushdns | Out-Null

    Write-Host ''
    Write-Host ("  Записано в hosts: {0}, не разрешилось: {1}" -f $resolved.Count,$failed.Count) -ForegroundColor Green
    if($failed.Count){
        Write-Host ("  Без DoH-ответа: {0}" -f ($failed -join ', ')) -ForegroundColor DarkGray
    }
    Write-Host '  Откат: -Action Uninstall (блок удаляется полностью).' -ForegroundColor DarkGray
}

# ============================================================================
#  Откат правок hosts.
#  Удаляются ТОЛЬКО размеченные блоки (наш и от прежней итерации проекта):
#    "# --- Zapret2Windows DoH begin/end ---"
#    "# --- Zapret2 TUI DoH begin/end ---"
#  Прочие строки hosts не затрагиваются.
# ============================================================================
function Remove-HostsEntries {
    param([switch]$CountOnly)
    $hf=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if(-not (Test-Path $hf)){return 0}
    $lines=@(Get-Content -LiteralPath $hf -ErrorAction SilentlyContinue)
    $out=New-Object System.Collections.Generic.List[string]
    $skip=$false; $removed=0
    foreach($l in $lines){
        if($l -match '^\s*#\s*-+\s*Zapret2(Windows)?\s*(TUI)?\s*DoH\s*begin\s*-+'){$skip=$true; $removed++; continue}
        if($l -match '^\s*#\s*-+\s*Zapret2(Windows)?\s*(TUI)?\s*DoH\s*end\s*-+'){$skip=$false; $removed++; continue}
        if($skip){$removed++; continue}
        $out.Add($l)
    }
    if($removed -eq 0 -or $CountOnly){return $removed}
    Copy-Item -LiteralPath $hf -Destination "$hf.zapret-backup" -Force -ErrorAction SilentlyContinue
    $hasNonAscii=$false
    foreach($l in $out){ if($l -match '[^\x00-\x7F]'){$hasNonAscii=$true; break} }
    $enc=if($hasNonAscii){[Text.UTF8Encoding]::new($false)}else{[Text.Encoding]::ASCII}
    [IO.File]::WriteAllLines($hf,$out,$enc)
    & ipconfig.exe /flushdns | Out-Null
    return $removed
}
# ============================================================================
#  Полное удаление из системы.
#  Удаляет: процесс winws2, задачу автозапуска, службу ядра WinDivert,
#  защищённый каталог System32\Zapret2Windows и размеченный блок прежней
#  версии проекта в hosts (если он есть).
#  НЕ трогает: хранилище сертификатов, прочие файлы System32, посторонние
#  записи hosts, рабочую папку проекта (если не указан -IncludeProject).
#  Команда идемпотентна: повторный запуск безопасен.
# ============================================================================
function Remove-All {
    param(
        [switch]$KeepLogs,        # сохранить копию логов в logs-backup перед удалением
        [switch]$IncludeProject,  # удалить также runtime рабочей папки проекта
        [switch]$Force            # не спрашивать подтверждение
    )
    Ensure-Admin
    $hostsCount=Remove-HostsEntries -CountOnly
    Write-Host ''
    Write-Host '  Полное удаление Zapret2 Windows из системы' -ForegroundColor Cyan
    Write-Host '  Будет удалено:' -ForegroundColor DarkGray
    Write-Host '    - процесс winws2 (если запущен)' -ForegroundColor DarkGray
    Write-Host "    - задача планировщика '$script:TaskName' (если есть)" -ForegroundColor DarkGray
    Write-Host '    - служба ядра WinDivert' -ForegroundColor DarkGray
    Write-Host "    - каталог $script:TrustedRuntime" -ForegroundColor DarkGray
    if($hostsCount -gt 0){
        Write-Host "    - $hostsCount строк в hosts (блок прежней версии проекта)" -ForegroundColor DarkGray
    }
    if($IncludeProject){Write-Host "    - каталог $script:Runtime" -ForegroundColor DarkGray}
    Write-Host '  Не затрагивается:' -ForegroundColor DarkGray
    Write-Host '    - сертификаты, прочие файлы System32, прочие записи hosts' -ForegroundColor DarkGray
    Write-Host ''
    if(-not $Force){
        $a=Read-Host '  Продолжить? (y/N)'
        if($a -notmatch '^\s*[yYдД]'){Write-Host '  Отменено.' -ForegroundColor Yellow; return}
    }

    # 1) процесс
    Write-Host '  [1/5] Остановка winws2...' -ForegroundColor Yellow
    Stop-Zapret -Quiet

    # 2) задача автозапуска
    Write-Host '  [2/5] Удаление задачи автозапуска...' -ForegroundColor Yellow
    Remove-Autostart

    # 3) служба ядра WinDivert
    Write-Host '  [3/5] Удаление службы драйвера WinDivert...' -ForegroundColor Yellow
    $svc=Get-CimInstance Win32_SystemDriver -Filter "Name='WinDivert'" -ErrorAction SilentlyContinue
    if($svc){
        & sc.exe stop WinDivert | Out-Null
        Start-Sleep -Seconds 2
        & sc.exe delete WinDivert | Out-Null
        Start-Sleep -Seconds 2
    }

    # 4) защищённый каталог (копия логов - по желанию)
    Write-Host '  [4/5] Удаление защищённого каталога...' -ForegroundColor Yellow
    $logBackup=$null
    if($KeepLogs){
        $src=Join-Path $script:TrustedRuntime 'logs'
        if(Test-Path $src){
            $logBackup=Join-Path $script:AppRoot 'logs-backup'
            New-Item -ItemType Directory -Path $logBackup -Force | Out-Null
            Copy-Item (Join-Path $src '*') $logBackup -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if(Test-Path $script:TrustedRuntime){
        # Удаляем строго наш каталог: сначала проверяем точный путь.
        $resolved=(Resolve-Path $script:TrustedRuntime -ErrorAction SilentlyContinue).Path
        $expected=Join-Path $env:SystemRoot 'System32\Zapret2Windows'
        if($resolved -and $resolved -ieq $expected){
            Remove-Item $resolved -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "  ! Не совпадает ожидаемый путь, удаление пропущено: $resolved" -ForegroundColor Red
        }
    }
    if($IncludeProject -and (Test-Path $script:Runtime)){
        $resolvedW=(Resolve-Path $script:Runtime -ErrorAction SilentlyContinue).Path
        if($resolvedW -and $resolvedW -ieq (Join-Path $script:AppRoot 'runtime\winws2')){
            Remove-Item $resolvedW -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 5) hosts: откат размеченного блока прежней версии проекта
    Write-Host '  [5/5] Откат правок hosts...' -ForegroundColor Yellow
    $removedHosts=Remove-HostsEntries

    # --- проверка остатков ---
    Write-Host ''
    Write-Host '  Проверка результата:' -ForegroundColor Cyan
    $proc=@(Get-CimInstance Win32_Process -Filter "Name='winws2.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -eq (Join-Path $script:TrustedRuntime 'winws2.exe') }).Count
    $task=[bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)
    $drv=[bool](Get-CimInstance Win32_SystemDriver -Filter "Name='WinDivert'" -ErrorAction SilentlyContinue)
    $dir=Test-Path (Join-Path $env:SystemRoot 'System32\Zapret2Windows')
    $hostsLeft=Remove-HostsEntries -CountOnly
    Write-Host ("    процесс winws2:        {0}" -f $(if($proc -eq 0){'удалён'}else{'ОСТАЛСЯ'})) -ForegroundColor $(if($proc -eq 0){'Green'}else{'Red'})
    Write-Host ("    задача автозапуска:    {0}" -f $(if(-not $task){'удалена'}else{'ОСТАЛАСЬ'})) -ForegroundColor $(if(-not $task){'Green'}else{'Red'})
    Write-Host ("    служба WinDivert:      {0}" -f $(if(-not $drv){'удалена'}else{'ОСТАЛАСЬ'})) -ForegroundColor $(if(-not $drv){'Green'}else{'Red'})
    Write-Host ("    каталог в System32:    {0}" -f $(if(-not $dir){'удалён'}else{'ОСТАЛСЯ'})) -ForegroundColor $(if(-not $dir){'Green'}else{'Red'})
    Write-Host ("    записи hosts:          {0}" -f $(if($hostsLeft -eq 0){'очищены'}else{"осталось $hostsLeft"})) -ForegroundColor $(if($hostsLeft -eq 0){'Green'}else{'Yellow'})
    Write-Host ''
    if($proc -eq 0 -and -not $task -and -not $drv -and -not $dir -and $hostsLeft -eq 0){
        Write-Host '  Удаление завершено полностью.' -ForegroundColor Green
    } else {
        Write-Host '  Часть компонентов осталась. Закройте приложения, использующие WinDivert,' -ForegroundColor Yellow
        Write-Host '  и повторите команду Uninstall.' -ForegroundColor Yellow
    }
    if($logBackup){Write-Host "  Копия логов сохранена: $logBackup" -ForegroundColor DarkGray}
    Write-Host "  Рабочая папка проекта: $script:AppRoot (не тронута)" -ForegroundColor DarkGray
    Write-Host '  Для повторной установки: -Action Install' -ForegroundColor DarkGray
}

switch($Action){
    'Install' {Install-Runtime}
    'Start' {Start-Zapret}
    'Stop' {Stop-Zapret}
    'Status' {Show-Status}
    'Diagnose' {Diagnose}
    'DohHosts' {Update-DohHosts}
    'Uninstall' {Remove-All -KeepLogs:$KeepLogs -Force:$Force}
    'Purge' {Remove-All -KeepLogs:$KeepLogs -IncludeProject:$IncludeProject -Force:$Force}
    'Menu' {Show-Menu}
}
