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
    [ValidateSet('Menu','Install','Start','Stop','Status','Diagnose','Check','Deps','DohHosts','Update','Uninstall','Purge','WarpOn','WarpOff','WarpScan','WarpRoutes','WarpImport')]
    [string]$Action='Menu',
    [string]$ZapretRoot = '',
    [switch]$NoAutostart,
    [switch]$KeepLogs,        # с Uninstall/Purge: сохранить копию логов
    [switch]$IncludeProject,  # с Uninstall/Purge: удалить и runtime рабочей папки
    [switch]$Force,           # с Uninstall/Purge: без запроса подтверждения
    [string]$WarpConfig = ''  # с WarpImport: путь к WireGuard-конфигу WARP
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false) } catch {}
# Корень проекта. $PSScriptRoot может быть пустым (например, при запуске
# через .cmd или из другого хоста), поэтому используем запасные варианты.
$script:AppRoot=$(
    if($PSScriptRoot){ $PSScriptRoot }
    elseif($PSCommandPath){ Split-Path -Parent $PSCommandPath }
    elseif($MyInvocation.MyCommand.Path){ Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { (Get-Location).Path }
)
if(-not $ZapretRoot){ $ZapretRoot = Join-Path $script:AppRoot 'zapret2-v1.0.6' }
$script:Runtime=Join-Path $script:AppRoot 'runtime\winws2'
$script:TrustedRuntime=Join-Path $env:SystemRoot 'System32\Zapret2Windows'
$script:TaskName='Zapret2Windows'
$script:DepsChecked=$false
$script:BinSource=$null
$script:Arch=$null

# Версия скрипта и репозиторий для самообновления (пункт [9] меню).
# Версию меняйте при каждом значимом изменении: по ней сравнивается
# локальная копия с удалённой.
$script:ScriptVersion='1.3.1'
$script:UpdateRepo='HikariRisser/Zapret2Scrpt'
$script:UpdateBranch='main'

# "Белый" SNI для фейковых ClientHello. ТСПУ пропускает соединения к
# хостингам (Cloudflare, Hetzner, OVH, AWS...) только для доменов из своего
# белого списка, остальные обрывает после ~16 КБ. Фейк с белым SNI
# заставляет DPI отнести поток к разрешённому домену.
$script:WhiteSni='www.google.com'

# Начальный список доменов для обхода. При каждой установке/обновлении
# недостающие домены ДОБАВЛЯЮТСЯ в существующий список, ручные правки
# пользователя сохраняются.
$script:SeedDomains=@(
    'archive.org','cdn-telegram.org','cdninstagram.com','cloudflare-dns.com',
    'cloudflare-ech.com','cloudflare.com','dis.gd','discord-attachments-uploads-prd.storage.googleapis.com',
    'discord.co','discord.com','discord.dev','discord.gg',
    'discord.gift','discord.media','discord.new','discordapp.com',
    'discordapp.net','discordcdn.com','discordstatus.com','facebook.com',
    'facebook.net','fb.com','fb.me','fbcdn.net',
    'fbsbx.com','ggpht.com','github.com','githubassets.com',
    'githubusercontent.com','googlevideo.com','instagram.com','jnn-pa.googleapis.com',
    'jtvnw.net','licdn.com','linkedin.com','live-video.net',
    'medium.com','messenger.com','nnmclub.to','patreon.com',
    'proton.me','protonmail.com','rbxcdn.com','redd.it',
    'reddit.com','redditmedia.com','redditstatic.com','roblox.com',
    'rutor.info','rutor.is','rutracker.cc','rutracker.org',
    'signal.org','sndcdn.com','soundcloud.com','spotify.com',
    't-ru.org','t.co','t.me','telegra.ph',
    'telegram.me','telegram.org','telesco.pe','threads.com',
    'threads.net','tiktok.com','tiktokcdn.com','tiktokv.com',
    'ttvnw.net','ttwstatic.com','twimg.com','twitch.tv',
    'twitter.com','viber.com','wa.me','whatsapp.com',
    'whatsapp.net','x.com','youtu.be','youtube-nocookie.com',
    'youtube.com','youtubei.googleapis.com','youtubekids.com','yt.be',
    'yt3.googleusercontent.com','ytimg.com'
)
$script:SeedExclude=@('localhost','local','example.com')
$script:SeedWarp=@(
    '# Сайты, которые открываются через WARP (sing-box), а не через zapret.',
    '# Пополняется автоматически (меню WARP -> [3]) или вручную, по домену в строке.'
)

# Подсети хостингов, которые ТСПУ режет "по 16 КБ". Для них работает
# отдельный профиль с белым SNI - сайты, которых нет в списках доменов,
# тоже открываются. Файл можно дополнять своими подсетями.
$script:SeedHostingIpset=@(
    '# Cloudflare (https://www.cloudflare.com/ips/)',
    '173.245.48.0/20',
    '103.21.244.0/22',
    '103.22.200.0/22',
    '103.31.4.0/22',
    '141.101.64.0/18',
    '108.162.192.0/18',
    '190.93.240.0/20',
    '188.114.96.0/20',
    '197.234.240.0/22',
    '198.41.128.0/17',
    '162.158.0.0/15',
    '104.16.0.0/13',
    '104.24.0.0/14',
    '172.64.0.0/13',
    '131.0.72.0/22',
    '2400:cb00::/32',
    '2606:4700::/32',
    '2803:f800::/32',
    '2405:b500::/32',
    '2405:8100::/32',
    '2a06:98c0::/29',
    '2c0f:f248::/32',
    '# Amazon CloudFront',
    '13.32.0.0/15',
    '13.35.0.0/16',
    '13.224.0.0/14',
    '18.64.0.0/14',
    '18.154.0.0/15',
    '18.160.0.0/15',
    '18.164.0.0/15',
    '18.172.0.0/15',
    '52.84.0.0/15',
    '54.182.0.0/16',
    '54.192.0.0/16',
    '54.230.0.0/16',
    '54.239.128.0/18',
    '99.84.0.0/16',
    '99.86.0.0/16',
    '108.138.0.0/15',
    '108.156.0.0/14',
    '143.204.0.0/16',
    '205.251.192.0/19',
    '# Hetzner',
    '5.9.0.0/16',
    '5.75.128.0/17',
    '23.88.0.0/17',
    '37.27.0.0/16',
    '46.4.0.0/16',
    '49.12.0.0/15',
    '65.21.0.0/16',
    '65.108.0.0/15',
    '78.46.0.0/15',
    '88.99.0.0/16',
    '88.198.0.0/16',
    '91.107.128.0/17',
    '95.216.0.0/15',
    '116.202.0.0/15',
    '128.140.0.0/17',
    '135.181.0.0/16',
    '136.243.0.0/16',
    '138.201.0.0/16',
    '144.76.0.0/16',
    '148.251.0.0/16',
    '157.90.0.0/16',
    '159.69.0.0/16',
    '162.55.0.0/16',
    '167.235.0.0/16',
    '168.119.0.0/16',
    '176.9.0.0/16',
    '178.63.0.0/16',
    '188.40.0.0/16',
    '195.201.0.0/16',
    '213.133.96.0/19',
    '213.239.192.0/18',
    '# OVH',
    '5.39.0.0/17',
    '5.135.0.0/16',
    '5.196.0.0/16',
    '37.59.0.0/16',
    '37.187.0.0/16',
    '46.105.0.0/16',
    '51.38.0.0/16',
    '51.68.0.0/16',
    '51.75.0.0/16',
    '51.77.0.0/16',
    '51.89.0.0/16',
    '51.91.0.0/16',
    '51.195.0.0/16',
    '54.36.0.0/14',
    '87.98.128.0/17',
    '91.121.0.0/16',
    '92.222.0.0/16',
    '94.23.0.0/16',
    '137.74.0.0/16',
    '141.94.0.0/15',
    '145.239.0.0/16',
    '147.135.0.0/16',
    '149.202.0.0/16',
    '151.80.0.0/16',
    '164.132.0.0/16',
    '176.31.0.0/16',
    '178.32.0.0/15',
    '188.165.0.0/16',
    '193.70.0.0/17',
    '213.186.32.0/19',
    '213.251.128.0/18',
    '217.182.0.0/16',
    '# DigitalOcean',
    '46.101.0.0/16',
    '64.225.0.0/16',
    '64.227.0.0/16',
    '68.183.0.0/16',
    '104.131.0.0/16',
    '104.236.0.0/16',
    '107.170.0.0/16',
    '128.199.0.0/16',
    '134.122.0.0/16',
    '134.209.0.0/16',
    '137.184.0.0/16',
    '138.68.0.0/16',
    '138.197.0.0/16',
    '139.59.0.0/16',
    '142.93.0.0/16',
    '143.198.0.0/16',
    '146.190.0.0/16',
    '157.230.0.0/16',
    '157.245.0.0/16',
    '159.65.0.0/16',
    '159.89.0.0/16',
    '159.203.0.0/16',
    '161.35.0.0/16',
    '164.90.0.0/16',
    '164.92.0.0/16',
    '165.22.0.0/16',
    '165.227.0.0/16',
    '167.71.0.0/16',
    '167.99.0.0/16',
    '167.172.0.0/16',
    '170.64.0.0/16',
    '174.138.0.0/17',
    '178.62.0.0/16',
    '178.128.0.0/16',
    '188.166.0.0/16',
    '206.189.0.0/16'
)

function Test-Admin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Ensure-Admin {
    if(Test-Admin){return}
    $self=$PSCommandPath
    if(-not $self){ $self = Join-Path $script:AppRoot 'Zapret2Windows.ps1' }
    $argList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $self),
               '-Action',$Action,'-ZapretRoot',('"{0}"' -f $ZapretRoot))
    if($NoAutostart){$argList+='-NoAutostart'}
    if($WarpConfig){$argList+=@('-WarpConfig',('"{0}"' -f $WarpConfig))}
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
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
    # На чистой/старой системе TLS 1.2 может быть выключен — тогда загрузка
    # с GitHub не работает. Включаем до скачивания.
    if(-not (Test-Tls12Enabled)){
        [void](Install-Tls12)
        Write-Host '  Включён TLS 1.2 для скачивания.' -ForegroundColor DarkGray
    }
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
function Merge-ListFile {
    <#
      Дописывает в файл списка недостающие строки из $Seed, ничего не
      удаляя: ручные правки и комментарии пользователя сохраняются.
      Возвращает число добавленных строк.
    #>
    param([string]$Path,[string[]]$Seed)
    $have=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $lines=New-Object System.Collections.Generic.List[string]
    if(Test-Path -LiteralPath $Path){
        foreach($l in [IO.File]::ReadAllLines($Path)){ $lines.Add($l); [void]$have.Add($l.Trim()) }
    }
    $added=0
    foreach($x in $Seed){
        if(-not $x){continue}
        if($have.Add($x.Trim())){ $lines.Add($x); $added++ }
    }
    if($added -or -not (Test-Path -LiteralPath $Path)){
        [IO.File]::WriteAllLines($Path,$lines,[Text.UTF8Encoding]::new($false))
    }
    return $added
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
    $null=Merge-ListFile (Join-Path $script:Runtime 'lists\blocked.txt') $script:SeedDomains

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

    # Списки живут в защищённом каталоге. Недостающие записи дописываются,
    # ручные правки и выученный autohostlist сохраняются.
    $lists=Join-Path $script:TrustedRuntime 'lists'
    $n=Merge-ListFile (Join-Path $lists 'blocked.txt') $script:SeedDomains
    if($n){Write-Host "  Добавлено доменов в список обхода: $n" -ForegroundColor DarkGray}
    $null=Merge-ListFile (Join-Path $lists 'exclude.txt') $script:SeedExclude
    $null=Merge-ListFile (Join-Path $lists 'warp.txt') $script:SeedWarp
    $n=Merge-ListFile (Join-Path $lists 'ipset-hosting.txt') $script:SeedHostingIpset
    if($n){Write-Host "  Добавлено подсетей хостингов: $n" -ForegroundColor DarkGray}
    $auto=Join-Path $lists 'autohostlist.txt'
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
    $blocked=Join-Path $lists 'blocked.txt'
    $auto=Join-Path $lists 'autohostlist.txt'
    $exclude=Join-Path $lists 'exclude.txt'
    $hosting=Join-Path $lists 'ipset-hosting.txt'
    # Домены, переведённые в WARP, zapret не трогает: их трафик идёт в туннель.
    $warpList=Join-Path $lists 'warp.txt'
    if(-not (Test-Path -LiteralPath $warpList)){ $null=Merge-ListFile $warpList $script:SeedWarp }
    $sni=$script:WhiteSni
    # Если пользователь удалил файл подсетей - профиль хостингов не включаем.
    $useHosting=$false
    if(Test-Path -LiteralPath $hosting){
        $useHosting=@(Get-Content -LiteralPath $hosting -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -notmatch '^\s*#' }).Count -gt 0
    }

    $wsArgs=@(
      # СКОРОСТЬ. Перехватываем только ИСХОДЯЩИЕ пакеты 80/443. Входящие
      # SYN+ACK, FIN, RST и HTTP-редиректы фильтр-конструктор winws2
      # добавляет сам - этого хватает и стратегиям, и детекторам сбоев.
      # Раньше здесь были --wf-tcp-in/--wf-udp-in (весь скачиваемый трафик,
      # включая видео, шёл через winws2) и --wf-tcp-empty (все пустые ACK):
      # по документации zapret2 это до ~50% лишней нагрузки на CPU.
      '--wf-tcp-out=80,443','--wf-udp-out=443',
      "--wf-raw-part=@$(Join-Path $wf 'windivert_part.discord_media.txt')",
      "--wf-raw-part=@$(Join-Path $wf 'windivert_part.stun.txt')",
      "--wf-raw-part=@$(Join-Path $wf 'windivert_part.wireguard.txt')",
      "--lua-init=@$(Join-Path $lua 'zapret-lib.lua')",
      "--lua-init=@$(Join-Path $lua 'zapret-antidpi.lua')",
      # zapret-auto.lua: оркестратор circular (автоперебор стратегий).
      "--lua-init=@$(Join-Path $lua 'zapret-auto.lua')",
      '--hostlist-auto-fail-threshold=3','--hostlist-auto-fail-time=60',
      '--hostlist-auto-retrans-threshold=3','--hostlist-auto-retrans-reset=1',
      '--hostlist-auto-incoming-maxseq=4096','--hostlist-auto-retrans-maxseq=32768',

      # [1] HTTP
      '--filter-tcp=80','--filter-l7=http',
      "--hostlist=$blocked","--hostlist-auto=$auto","--hostlist-exclude=$exclude","--hostlist-exclude=$warpList",
      '--out-range=-d10','--payload=http_req',
      '--lua-desync=fake:blob=fake_default_http:tcp_md5',
      '--lua-desync=multisplit:pos=method+2'
    )
    if($useHosting){
      $wsArgs+=@(
        # [2] Хостинги ("16 КБ"). Любой сайт на Cloudflare/Hetzner/OVH/AWS/DO,
        # которого НЕТ в списках доменов: фейк с белым SNI + разрезание
        # настоящего ClientHello. Домены из списков обрабатывает профиль [3].
        # Профиль должен стоять ДО [3]: профиль с autohostlist забирает
        # себе любой поток, у которого известно имя.
        '--new','--filter-tcp=443','--filter-l7=tls',"--ipset=$hosting",
        "--hostlist-exclude=$exclude","--hostlist-exclude=$blocked","--hostlist-exclude=$auto","--hostlist-exclude=$warpList",
        '--out-range=-d10','--payload=tls_client_hello',
        "--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:tls_mod=rnd,dupsid,sni=${sni}:repeats=6",
        '--lua-desync=multidisorder:pos=1,midsld'
      )
    }
    $wsArgs+=@(
      # [3] TLS для доменов из списков. circular перебирает стратегии для
      # каждого домена 2-го уровня отдельно (nld=2), если текущая не
      # проходит: 2 сбоя (ретрансмиссии ClientHello или RST от DPI) - и
      # домен переключается на следующую стратегию. Стратегия 1 - прежняя.
      '--new','--filter-tcp=443','--filter-l7=tls',
      "--hostlist=$blocked","--hostlist-auto=$auto","--hostlist-exclude=$exclude","--hostlist-exclude=$warpList",
      '--out-range=-d10',
      '--in-range=-s5556','--lua-desync=circular:fails=2:retrans=2:nld=2',
      '--in-range=x','--payload=tls_client_hello',
      '--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=6:strategy=1',
      '--lua-desync=multidisorder:pos=1,midsld:strategy=1',
      "--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:tls_mod=rnd,dupsid,sni=${sni}:repeats=6:strategy=2",
      '--lua-desync=multisplit:pos=1,sniext+1:strategy=2',
      '--lua-desync=hostfakesplit:host=google.com:tcp_md5:strategy=3',
      '--lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=fake_default_tls:strategy=4',

      # [4] QUIC. Без автообучения: детектору UDP нужны входящие пакеты,
      # а их мы больше не перехватываем (иначе весь QUIC-трафик YouTube шёл
      # бы через winws2). Выученные TCP-домены применяются и к QUIC.
      '--new','--filter-udp=443','--filter-l7=quic',
      "--hostlist=$blocked","--hostlist=$auto","--hostlist-exclude=$exclude","--hostlist-exclude=$warpList",
      '--payload=quic_initial','--lua-desync=fake:blob=fake_default_quic:repeats=6',

      # [5] Голос/медиа Discord: IP-discovery (STUN-подобный) и STUN/WireGuard.
      # Официальная схема zapret2 (init.d/custom.d.examples.*/50-discord-media,
      # 50-stun4all, 50-wg4all): fake с нулевым блобом, repeats=2.
      # Фильтровать по hostlist здесь нельзя - в UDP-медиа нет SNI.
      '--new','--filter-l7=stun,discord,wireguard',
      '--payload=stun,discord_ip_discovery,wireguard_initiation,wireguard_cookie',
      '--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
    )
    [IO.File]::WriteAllLines($cfg,$wsArgs,[Text.UTF8Encoding]::new($false))
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
    if((Get-WarpStatus).Enabled){
        try { Start-Warp } catch { Write-Host ('  WARP не запущен: ' + $_.Exception.Message) -ForegroundColor Yellow }
    }
}
function Stop-Zapret {
    param([switch]$Quiet)
    Stop-Warp -Quiet
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
# ============================================================================
#  Зависимости: определение отсутствующих и их установка.
#
#  Что можно поставить автоматически:
#    * .NET Framework 4.x  — winget/choco, иначе прямая загрузка установщика
#    * TLS 1.2 для .NET    — ключи реестра (чинится без переустановки)
#    * Node.js (опция)     — только для диагностики в tools/
#    * сборка zapret2      — скачивается с GitHub
#  Что поставить нельзя:
#    * Windows PowerShell 5.1 — скрипт исполняется ИМ ЖЕ (курица и яйцо);
#      WMF 5.1 снят с сайта Microsoft, нужен ручной шаг.
#    * права администратора — выдаёт пользователь через UAC.
# ============================================================================

function Get-PackageManager {
    foreach($c in @('winget','choco')){
        $g=Get-Command $c -ErrorAction SilentlyContinue
        if($g){ return @{ Name=$c; Path=$g.Source } }
    }
    return $null
}

function Get-DotNetRelease {
    foreach($k in @(
        'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\NET Framework Setup\NDP\v4\Full')){
        $v=(Get-ItemProperty $k -Name Release -ErrorAction SilentlyContinue).Release
        if($v){ return [int]$v }
    }
    return 0
}

function Test-Tls12Enabled {
    # 1) системный флаг .NET
    foreach($k in @('HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319')){
        $v=(Get-ItemProperty $k -Name SchUseStrongCrypto -ErrorAction SilentlyContinue).SchUseStrongCrypto
        if($v -eq 1){ return $true }
    }
    # 2) явные ключи SCHANNEL
    $base='HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2'
    $c=(Get-ItemProperty "$base\Client" -Name Enabled,DisabledByDefault -ErrorAction SilentlyContinue)
    if($c -and $c.Enabled -eq 1 -and $c.DisabledByDefault -eq 0){ return $true }
    # 3) современная сборка Windows 10/11 включает TLS 1.2 по умолчанию
    $build=[int](Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).BuildNumber
    return ($build -ge 17763)
}

function Get-DependencyReport {
    <#
      Возвращает список проверок. Каждый элемент:
        Name, Detail, Status (OK/FAIL/WARN), Required, Fixable
    #>
    $r=New-Object System.Collections.Generic.List[object]
    $os=Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $build=if($os){[int]$os.BuildNumber}else{0}

    $r.Add([pscustomobject]@{
        Name='Windows 10/11'; Required=$true; Fixable=$false
        Status=$(if($build -ge 10240){'OK'}else{'FAIL'})
        Detail=$(if($os){"$($os.Caption) (build $build)"}else{'не удалось определить'})
    })

    $r.Add([pscustomobject]@{
        Name='Разрядность x64'; Required=$true; Fixable=$false
        Status=$(if([Environment]::Is64BitOperatingSystem){'OK'}else{'FAIL'})
        Detail=$(if([Environment]::Is64BitOperatingSystem){'x64'}else{'32-битная Windows не поддерживается'})
    })

    $psv=$PSVersionTable.PSVersion
    $r.Add([pscustomobject]@{
        Name='PowerShell 5.1+'; Required=$true; Fixable=$false
        Status=$(if($psv.Major -ge 5 -and $psv.Minor -ge 1){'OK'}else{'FAIL'})
        Detail="$psv"
    })

    $rel=Get-DotNetRelease
    $r.Add([pscustomobject]@{
        Name='.NET Framework 4.x'; Required=$true; Fixable=$true
        Status=$(if($rel -ge 378389){'OK'}else{'FAIL'})
        Detail=$(if($rel -ge 528040){"4.8 (release $rel)"}
                 elseif($rel -ge 378389){"4.x (release $rel)"}
                 elseif($rel -gt 0){"устаревшая версия (release $rel)"}
                 else{'не установлен'})
    })

    $tls=Test-Tls12Enabled
    $r.Add([pscustomobject]@{
        Name='TLS 1.2 для .NET'; Required=$true; Fixable=$true
        Status=$(if($tls){'OK'}else{'FAIL'})
        Detail=$(if($tls){'включён'}else{'выключен — скачивание релиза не сработает'})
    })

    $r.Add([pscustomobject]@{
        Name='Права администратора'; Required=$true; Fixable=$false
        Status=$(if(Test-Admin){'OK'}else{'WARN'})
        Detail=$(if(Test-Admin){'есть'}else{'нет — потребуется подтверждение UAC'})
    })

    $r.Add([pscustomobject]@{
        Name='Сборка zapret2'; Required=$true; Fixable=$true
        Status=$(if(Test-Path $ZapretRoot){'OK'}else{'FAIL'})
        Detail=$(if(Test-Path $ZapretRoot){$ZapretRoot}else{'нет — скачается при установке'})
    })

    $pm=Get-PackageManager
    $nodeOk=[bool](Get-Command node -ErrorAction SilentlyContinue)
    $r.Add([pscustomobject]@{
        Name='Node.js (диагностика)'; Required=$false; Fixable=$true
        Status=$(if($nodeOk){'OK'}else{'WARN'})
        Detail=$(if($nodeOk){'есть'}else{'нет — необязательно, нужен только для tools/'})
    })

    $r.Add([pscustomobject]@{
        Name='Менеджер пакетов'; Required=$false; Fixable=$false
        Status=$(if($pm){'OK'}else{'WARN'})
        Detail=$(if($pm){"$($pm.Name): $($pm.Path)"}else{'winget/choco нет — установка через прямой загрузчик'})
    })

    return $r
}

function Install-Tls12 {
    <#
      Включает TLS 1.2 для .NET и Schannel. Нужны права администратора.
      Применяется без перезагрузки, но часть приложений увидит изменение
      только после перезапуска.
    #>
    $changed=$false
    foreach($k in @('HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319')){
        try {
            if(-not (Test-Path $k)){New-Item -Path $k -Force | Out-Null}
            $cur=(Get-ItemProperty $k -Name SchUseStrongCrypto -ErrorAction SilentlyContinue).SchUseStrongCrypto
            if($cur -ne 1){
                Set-ItemProperty -Path $k -Name SchUseStrongCrypto -Value 1 -Type DWord -Force
                $changed=$true
            }
        } catch {}
    }
    $base='HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2'
    foreach($side in @('Client','Server')){
        $k="$base\$side"
        try {
            if(-not (Test-Path $k)){New-Item -Path $k -Force | Out-Null}
            Set-ItemProperty -Path $k -Name Enabled -Value 1 -Type DWord -Force
            Set-ItemProperty -Path $k -Name DisabledByDefault -Value 0 -Type DWord -Force
            $changed=$true
        } catch {}
    }
    # Включаем TLS 1.2 в текущем процессе тоже.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}
    return $changed
}

function Install-DotNet {
    <#
      Устанавливает .NET Framework 4.8: сначала менеджером пакетов,
      иначе прямым загрузчиком Microsoft. Возвращает $true при успехе.
    #>
    $pm=Get-PackageManager
    if($pm -and $pm.Name -eq 'winget'){
        Write-Host '    Установка через winget...' -ForegroundColor DarkGray
        & winget install --id Microsoft.DotNet.Framework.DeveloperPack_4 -e `
            --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
        if((Get-DotNetRelease) -ge 378389){return $true}
        & winget install --id Microsoft.DotNet.Framework.Runtime --silent `
            --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        if((Get-DotNetRelease) -ge 378389){return $true}
    }
    if($pm -and $pm.Name -eq 'choco'){
        Write-Host '    Установка через chocolatey...' -ForegroundColor DarkGray
        & choco install dotnetfx -y --no-progress 2>&1 | Out-Null
        if((Get-DotNetRelease) -ge 378389){return $true}
    }
    # Прямая загрузка официального установщика .NET Framework 4.8
    Write-Host '    Прямая загрузка установщика .NET Framework 4.8...' -ForegroundColor DarkGray
    $exe=Join-Path $env:TEMP 'ndp48-installer.exe'
    $url='https://go.microsoft.com/fwlink/?linkid=2088631'
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
    } catch {
        Write-Host ('    Не удалось скачать: ' + $_.Exception.Message) -ForegroundColor Red
        return $false
    }
    Write-Host '    Тихая установка (может занять несколько минут)...' -ForegroundColor DarkGray
    $proc=Start-Process -FilePath $exe -ArgumentList '/q','/norestart' -Wait -PassThru
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    # 0 - успех, 3010 - нужна перезагрузка (тоже успех установки)
    if($proc.ExitCode -in @(0,3010)){
        if($proc.ExitCode -eq 3010){
            Write-Host '    Требуется перезагрузка Windows для завершения.' -ForegroundColor Yellow
        }
        return $true
    }
    return $false
}

function Install-Node {
    $pm=Get-PackageManager
    if(-not $pm){ return $false }
    if($pm.Name -eq 'winget'){
        & winget install --id OpenJS.NodeJS.LTS -e --silent `
            --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    } else {
        & choco install nodejs-lts -y --no-progress 2>&1 | Out-Null
    }
    # Обновляем PATH текущего процесса, иначе node не виден до перелогина
    $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
               [Environment]::GetEnvironmentVariable('Path','User')
    return [bool](Get-Command node -ErrorAction SilentlyContinue)
}

function Install-Dependencies {
    <#
      Ставит отсутствующие зависимости. Спрашивает подтверждение,
      если не указан -Yes. Ничего не перезагружает автоматически.
    #>
    param([switch]$IncludeOptional,[switch]$Yes)

    Ensure-Admin
    $report=Get-DependencyReport
    $missing=@($report | Where-Object { $_.Status -eq 'FAIL' -and $_.Fixable })
    $manual=@($report | Where-Object { $_.Status -eq 'FAIL' -and -not $_.Fixable })

    Write-Host ''
    Write-Host '  Установка зависимостей' -ForegroundColor Cyan
    Write-Host ''

    if(-not $missing.Count -and -not $manual.Count){
        Write-Host '  Все обязательные зависимости уже на месте.' -ForegroundColor Green
        if($IncludeOptional){
            $opt=@($report | Where-Object { -not $_.Required -and $_.Status -ne 'OK' -and $_.Fixable })
            if($opt.Count -and $Yes){
                Write-Host '  Установка необязательных компонентов...' -ForegroundColor Yellow
                foreach($o in $opt){
                    if($o.Name -like 'Node.js*' -and (Install-Node)){Write-Host '    Node.js установлен' -ForegroundColor Green}
                }
            }
        }
        Write-Host ''
        return $true
    }

    Write-Host '  Отсутствует:' -ForegroundColor Yellow
    foreach($m in $missing){ Write-Host ('    - ' + $m.Name + ': ' + $m.Detail) -ForegroundColor DarkGray }
    foreach($m in $manual){ Write-Host ('    - ' + $m.Name + ': ' + $m.Detail + ' (нужен ручной шаг)') -ForegroundColor DarkGray }
    Write-Host ''

    if(-not $Yes){
        $a=Read-Host '  Установить автоматически? (y/N)'
        if($a -notmatch '^\s*[yYдД]'){ Write-Host '  Отменено.' -ForegroundColor Yellow; return $false }
    }

    $ok=$true
    foreach($m in $missing){
        Write-Host ('  [' + $m.Name + ']') -ForegroundColor Cyan
        switch -Wildcard ($m.Name){
            '.NET Framework*' {
                if(Install-DotNet){ Write-Host '    Готово.' -ForegroundColor Green }
                else { Write-Host '    Не удалось установить автоматически.' -ForegroundColor Red; $ok=$false }
            }
            'TLS 1.2*' {
                [void](Install-Tls12)
                if(Test-Tls12Enabled){ Write-Host '    Готово.' -ForegroundColor Green }
                else { Write-Host '    Не удалось применить настройки.' -ForegroundColor Red; $ok=$false }
            }
            'Сборка zapret2*' {
                try { Get-Upstream; Write-Host '    Готово.' -ForegroundColor Green }
                catch { Write-Host ('    ' + $_.Exception.Message) -ForegroundColor Red; $ok=$false }
            }
            default { Write-Host '    Пропущено (нет автоматического способа).' -ForegroundColor DarkGray }
        }
    }

    if($IncludeOptional -and $Yes){
        if(-not (Get-Command node -ErrorAction SilentlyContinue)){
            Write-Host '  [Node.js]' -ForegroundColor Cyan
            if(Install-Node){ Write-Host '    Готово.' -ForegroundColor Green }
            else { Write-Host '    Необязательно — пропущено.' -ForegroundColor DarkGray }
        }
    }

    Write-Host ''
    if($manual.Count){
        Write-Host '  Требуют ручного вмешательства:' -ForegroundColor Yellow
        foreach($m in $manual){
            Write-Host ('    - ' + $m.Name + ': ' + $m.Detail) -ForegroundColor Yellow
            if($m.Name -like 'PowerShell*'){
                Write-Host '      Windows PowerShell 5.1 нельзя поставить из него самого.' -ForegroundColor DarkGray
                Write-Host '      Обновите Windows или поставьте Windows Management Framework 5.1.' -ForegroundColor DarkGray
            }
        }
        Write-Host ''
    }
    return $ok
}
function Show-Check {
    <#
      Проверка требований. Единый источник данных — Get-DependencyReport,
      поэтому здесь видны те же зависимости, что ставит Install-Dependencies.
    #>
    $report=Get-DependencyReport
    Write-Host ''
    Write-Host '  Проверка требований Zapret2 Windows' -ForegroundColor Cyan
    Write-Host ''
    $ok=0; $warn=0; $fail=0
    foreach($d in $report){
        $mark=switch($d.Status){'OK'{[char]0x2714}'WARN'{'!'}default{[char]0x2718}}
        $color=switch($d.Status){'OK'{'Green'}'WARN'{'Yellow'}default{'Red'}}
        if($d.Status -eq 'OK'){$ok++}elseif($d.Status -eq 'WARN'){$warn++}else{$fail++}
        $suffix=''
        if($d.Status -ne 'OK'){
            $suffix=if($d.Fixable){' [можно установить автоматически]'}else{' [нужен ручной шаг]'}
        }
        Write-Host ('  {0} {1,-32} {2}{3}' -f $mark,$d.Name,$d.Detail,$suffix) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host ("  Итог: успешно $ok, предупреждений $warn, ошибок $fail") `
        -ForegroundColor $(if($fail){'Red'}elseif($warn){'Yellow'}else{'Green'})
    if($fail){
        $fixable=@($report | Where-Object { $_.Status -eq 'FAIL' -and $_.Fixable }).Count
        if($fixable){
            Write-Host ("  Часть проблем исправляется автоматически (пункт [12]): $fixable") -ForegroundColor Yellow
        }
        Write-Host '  Остальное требует ручного вмешательства — см. пометки выше.' -ForegroundColor Red
    } elseif($warn){
        Write-Host '  Запуск возможен, но учтите предупреждения.' -ForegroundColor Yellow
    } else {
        Write-Host '  Всё готово. Можно выполнять установку (пункт [1]).' -ForegroundColor Green
    }
    Write-Host ''
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
# ============================================================================
#  Самообновление скрипта из репозитория GitHub.
#  Источник: $script:UpdateRepo. Обновляется только сам .ps1; среда zapret2
#  и списки не трогаются (для них — пункт [1]).
# ============================================================================

function Get-ScriptVersionFromText {
    param([string]$Text)
    if($Text -match 'ScriptVersion\s*=\s*[''"]?([\w.\-]+)[''"]?'){
        return $Matches[1]
    }
    return $null
}

function Compare-VersionString {
    <#
      Возвращает -1/0/1. Версии вида 1.2.3 сравниваются по числам.
      Нечисловые части сравниваются как строки — этого достаточно.
    #>
    param([string]$A,[string]$B)
    $pa=@($A -split '[.\-+]'); $pb=@($B -split '[.\-+]')
    $n=[Math]::Max($pa.Count,$pb.Count)
    for($i=0;$i -lt $n;$i++){
        $x=if($i -lt $pa.Count){$pa[$i]}else{'0'}
        $y=if($i -lt $pb.Count){$pb[$i]}else{'0'}
        $nx=0;$ny=0
        if([int]::TryParse($x,[ref]$nx) -and [int]::TryParse($y,[ref]$ny)){
            if($nx -lt $ny){return -1}
            if($nx -gt $ny){return 1}
        } else {
            $c=[string]::CompareOrdinal($x,$y)
            if($c -lt 0){return -1}
            if($c -gt 0){return 1}
        }
    }
    return 0
}

function Get-RemoteScript {
    <#
      Скачивает скрипт из репозитория обновлений.
      Пробует указанную ветку, затем main/master.
    #>
    $branches=@($script:UpdateBranch,'main','master') | Select-Object -Unique
    $lastMsg=''
    foreach($b in $branches){
        $url="https://raw.githubusercontent.com/$($script:UpdateRepo)/$b/Zapret2Windows.ps1"
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $r=Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $text=$r.Content
            # Invoke-WebRequest возвращает текст, начинающийся с символа BOM
            # (U+FEFF). Если его не убрать, при записи добавится второй BOM
            # и файл перестанет парситься. Снимаем все ведущие BOM.
            $text=$text.TrimStart([char]0xFEFF)
            # Защита от HTML-страницы ошибки вместо скрипта.
            if($text -notmatch 'param\s*\(' -or $text -notmatch 'Zapret2Windows'){
                $lastMsg="по адресу $url вернулся не скрипт"
                continue
            }
            return [pscustomobject]@{ Text=$text; Url=$url; Branch=$b }
        } catch {
            $lastMsg=$_.Exception.Message
        }
    }
    throw ("Не удалось скачать обновление из https://github.com/$($script:UpdateRepo).`n  " + $lastMsg)
}

function Update-Self {
    <#
      Обновляет сам скрипт. Перед заменой делает резервную копию,
      проверяет, что скачался действительно скрипт, и сохраняет UTF-8 BOM
      (без него PowerShell 5.1 ломает кириллицу).
    #>
    param([switch]$Force)

    $self=Join-Path $script:AppRoot 'Zapret2Windows.ps1'
    if(-not (Test-Path $self)){ throw "Не найден файл скрипта: $self" }

    Write-Host ''
    Write-Host '  Обновление скрипта' -ForegroundColor Cyan
    Write-Host ("    источник: https://github.com/" + $script:UpdateRepo) -ForegroundColor DarkGray
    Write-Host ("    текущая версия: " + $script:ScriptVersion) -ForegroundColor DarkGray
    Write-Host ''

    Write-Host '    Проверка обновлений...' -ForegroundColor DarkGray
    $remote=Get-RemoteScript
    $remoteVer=Get-ScriptVersionFromText $remote.Text
    $curText=[IO.File]::ReadAllText($self,[Text.Encoding]::UTF8)

    # Сравнение: сначала по версии, иначе по содержимому (старые копии
    # без маркера версии иначе всегда считались бы «новыми»).
    $norm={ param($s) (($s -replace "`r`n","`n") -replace "^\uFEFF",'').Trim() }
    $sameText = (& $norm $curText) -eq (& $norm $remote.Text)

    if($sameText){
        Write-Host '    Уже установлена последняя версия.' -ForegroundColor Green
        if($remoteVer){ Write-Host ("    Версия в репозитории: " + $remoteVer) -ForegroundColor DarkGray }
        Write-Host ''
        return
    }

    # Отдельно разбираем случай, когда в репозитории файл БЕЗ маркера версии:
    # это, скорее всего, старая копия, и молча «обновлять» ею рабочий скрипт
    # нельзя — получится откат.
    $verdict='update'
    if($remoteVer){
        $cmp=Compare-VersionString $remoteVer $script:ScriptVersion
        if($cmp -gt 0){ $verdict='update' }
        elseif($cmp -eq 0){ $verdict='same-version-differs' }
        else { $verdict='downgrade' }
    } else {
        $verdict='unversioned'
    }

    switch($verdict){
        'update'              { Write-Host ('    Доступна версия: ' + $remoteVer) -ForegroundColor Green }
        'same-version-differs'{
            Write-Host ('    Версия совпадает (' + $remoteVer + '), но содержимое отличается.') -ForegroundColor Yellow
            Write-Host '    Возможно, локальный файл правился вручную.' -ForegroundColor Yellow
        }
        'downgrade'           {
            Write-Host ('    В репозитории версия ' + $remoteVer + ', у вас ' + $script:ScriptVersion + '.') -ForegroundColor Yellow
            Write-Host '    Это ОТКАТ на более старую версию.' -ForegroundColor Red
        }
        'unversioned'         {
            Write-Host '    В репозитории файл без маркера версии.' -ForegroundColor Yellow
            Write-Host '    Скорее всего это старая копия: замена может откатить скрипт.' -ForegroundColor Red
        }
    }

    if(-not $Force){
        $prompt=if($verdict -eq 'update'){'    Установить обновление? (y/N)'}
                else{'    Всё равно заменить локальный файл? (y/N)'}
        $a=Read-Host $prompt
        if($a -notmatch '^\s*[yYдД]'){ Write-Host '    Отменено.' -ForegroundColor Yellow; Write-Host ''; return }
    }

    # Резервная копия с отметкой времени
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak="$self.$stamp.bak"
    Copy-Item -LiteralPath $self -Destination $bak -Force
    Write-Host ("    Резервная копия: " + (Split-Path -Leaf $bak)) -ForegroundColor DarkGray

    # Запись с UTF-8 BOM — иначе PowerShell 5.1 сломает кириллицу.
    try {
        [IO.File]::WriteAllText($self,$remote.Text,(New-Object Text.UTF8Encoding $true))
    } catch {
        Copy-Item -LiteralPath $bak -Destination $self -Force
        throw ("Не удалось записать обновление, восстановлена резервная копия.`n  " + $_.Exception.Message)
    }

    # Проверка синтаксиса нового файла до перезапуска.
    $parseErrors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($self,[ref]$null,[ref]$parseErrors)
    if($parseErrors.Count){
        Copy-Item -LiteralPath $bak -Destination $self -Force
        throw ("Скачанный скрипт содержит синтаксические ошибки, восстановлена резервная копия:`n  " + $parseErrors[0].Message)
    }

    Write-Host ''
    Write-Host '    Скрипт обновлён.' -ForegroundColor Green
    Write-Host ("    Было: " + $script:ScriptVersion + " -> Стало: " + $(if($remoteVer){$remoteVer}else{'обновлённая версия'})) -ForegroundColor Green
    Write-Host ("    Резервная копия: " + $bak) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    Текущий процесс работает со старой версией в памяти.' -ForegroundColor Yellow
    if(-not $Force){
        $a=Read-Host '    Перезапустить скрипт сейчас? (y/N)'
        if($a -match '^\s*[yYдД]'){
            Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $self),
                '-ZapretRoot',('"{0}"' -f $ZapretRoot)
            ) -Verb RunAs
            exit
        }
    }
    Write-Host '    Перезапустите скрипт вручную, чтобы применить обновление.' -ForegroundColor DarkGray
    Write-Host ''
}

# ============================================================================
#  Переключатели: один пункт меню вместо двух парных.
# ============================================================================

function Toggle-Run {
    $st=Get-Status
    if($st.Running){
        Stop-Zapret
        Write-Host '  Обход остановлен.' -ForegroundColor Yellow
    } else {
        Start-Zapret
    }
}

function Toggle-Autostart {
    $on=[bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)
    if($on){
        Remove-Autostart
        Write-Host '  Автозапуск при входе выключен.' -ForegroundColor Yellow
    } else {
        Install-Autostart
        Write-Host '  Автозапуск при входе включён.' -ForegroundColor Green
    }
}

# ============================================================================
#  WARP через sing-box: запасной маршрут для сайтов, с которыми не
#  справляется zapret (блокировка по IP, обрыв "16 КБ", полная недоступность).
#
#  Схема (скорость остального трафика не страдает):
#    * sing-box поднимает TUN, но маршрутизирует в него ТОЛЬКО диапазон FakeIP
#      (198.18.0.0/15) и свой DNS-адрес. Весь прочий трафик идёт мимо
#      sing-box, напрямую, через zapret.
#    * DNS-запросы системы обрабатывает sing-box: домены из lists\warp.txt
#      получают FakeIP и попадают в TUN -> WireGuard-туннель WARP,
#      остальные разрешаются обычным системным DNS.
#    * Настоящий адрес домена из warp.txt разрешается DNS 1.1.1.1 ВНУТРИ
#      туннеля - подмена DNS провайдером на эти домены не действует.
#    * Узел Cloudflare (IP:порт WARP) подбирается автоматически: пробный
#      туннель к каждому кандидату и замер задержки через него. При каждом
#      запуске узел проверяется, нерабочий заменяется следующим.
#    * zapret помогает и самому WARP: профиль [5] подмешивает фейки к
#      WireGuard-рукопожатию.
# ============================================================================

$script:SingBoxVersion='1.14.4'
$script:WarpMixedPort=40480     # локальный прокси sing-box для проверок
$script:WarpProbePort=40481     # порт для пробных туннелей при подборе узла
$script:WarpPrefixes=@('162.159.192','162.159.193','162.159.195','188.114.96','188.114.97','188.114.98','188.114.99')
$script:WarpPorts=@(2408,500,1701,4500)
$script:WarpApi='https://api.cloudflareclient.com/v0a5641/reg'
$script:WarpHeaders=@{ 'CF-Client-Version'='a-6.38.9-5641' }
$script:WarpUserAgent='1.1.1.1/6.38.9-5641 (Android 16.0.0)'

function Get-WarpPaths {
    $d=Join-Path $script:TrustedRuntime 'warp'
    [pscustomobject]@{
        Dir=$d
        Exe=Join-Path $d 'sing-box.exe'
        Account=Join-Path $d 'account.json'
        State=Join-Path $d 'state.json'
        Config=Join-Path $d 'config.json'
        Probe=Join-Path $d 'probe.json'
        Rules=Join-Path $d 'rules-warp.json'
        Cache=Join-Path $d 'cache.db'
        Pid=Join-Path $d 'sing-box.pid'
        Enabled=Join-Path $d 'enabled'
        Log=Join-Path $script:TrustedRuntime 'logs\sing-box.log'
        ErrLog=Join-Path $script:TrustedRuntime 'logs\sing-box-stderr.log'
        ProbeLog=Join-Path $script:TrustedRuntime 'logs\sing-box-probe.log'
        LastError=Join-Path $d 'last-error.txt'
        List=Join-Path $script:TrustedRuntime 'lists\warp.txt'
    }
}

function Write-JsonFile {
    param([string]$Path,$Object)
    $json=$Object | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($Path,$json,[Text.UTF8Encoding]::new($false))
}

function Read-JsonFile {
    param([string]$Path)
    if(-not (Test-Path -LiteralPath $Path)){ return $null }
    try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { return $null }
}

function Get-ListEntries {
    param([string]$Path)
    if(-not (Test-Path -LiteralPath $Path)){ return @() }
    return @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue |
             ForEach-Object { $_.Trim().ToLowerInvariant() } |
             Where-Object { $_ -and $_ -notmatch '^#' } | Select-Object -Unique)
}

function Install-SingBox {
    # stderr внешних программ при 'Stop' в PS 5.1 превращается в исключение.
    $ErrorActionPreference='Continue'
    # Скачивает официальную сборку sing-box с GitHub (один раз).
    $p=Get-WarpPaths
    New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null
    if(Test-Path $p.Exe){
        $v=(& $p.Exe version 2>$null | Select-Object -First 1)
        if($v -match [regex]::Escape($script:SingBoxVersion)){ return }
    }
    $arch=$env:PROCESSOR_ARCHITEW6432; if(-not $arch){ $arch=$env:PROCESSOR_ARCHITECTURE }
    $sbArch=switch($arch){ 'AMD64' {'amd64'} 'ARM64' {'arm64'} 'x86' {'386'} default {'amd64'} }
    $name="sing-box-$($script:SingBoxVersion)-windows-$sbArch"
    $url="https://github.com/SagerNet/sing-box/releases/download/v$($script:SingBoxVersion)/$name.zip"
    $tmp=Join-Path $env:TEMP ("sb-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Write-Host "  Скачивание sing-box $($script:SingBoxVersion)..." -ForegroundColor Yellow
        Write-Host "    $url" -ForegroundColor DarkGray
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $zip=Join-Path $tmp 'sb.zip'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $inner=Join-Path $tmp $name
        if(-not (Test-Path (Join-Path $inner 'sing-box.exe'))){ throw "В архиве нет sing-box.exe: $url" }
        Stop-Warp -Quiet
        Copy-Item (Join-Path $inner '*') $p.Dir -Recurse -Force
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "  sing-box установлен: $($p.Exe)" -ForegroundColor Green
}

function New-WarpAccount {
    # stderr внешних программ при 'Stop' в PS 5.1 превращается в исключение.
    $ErrorActionPreference='Continue'
    # Регистрирует бесплатное устройство WARP (как приложение 1.1.1.1).
    $p=Get-WarpPaths
    $kp=@(& $p.Exe generate wg-keypair)
    $priv=($kp | Where-Object { $_ -like 'PrivateKey:*' }) -replace '^PrivateKey:\s*',''
    $pub=($kp | Where-Object { $_ -like 'PublicKey:*' }) -replace '^PublicKey:\s*',''
    if(-not $priv -or -not $pub){ throw 'sing-box не сгенерировал ключи WireGuard.' }
    $body=[ordered]@{
        fcm_token=''; install_id=''; key=$pub; locale='en_US'; model='PC'
        tos=(Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'); serial_number=''
        os_version='16.0.0'; key_type='curve25519'; tunnel_type='wireguard'
    } | ConvertTo-Json
    Write-Host '  Регистрация устройства WARP...' -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    try {
        $r=Invoke-RestMethod -Method Post -Uri $script:WarpApi -Headers $script:WarpHeaders -UserAgent $script:WarpUserAgent `
             -ContentType 'application/json; charset=UTF-8' -Body $body -TimeoutSec 30 -ErrorAction Stop
    } catch {
        throw ("Не удалось зарегистрировать WARP: " + $_.Exception.Message +
               "`nМожно импортировать готовый WireGuard-конфиг WARP (wgcf, WarpGen): -Action WarpImport -WarpConfig <файл>")
    }
    $cfg=$r.config
    if(-not $cfg -and $r.id -and $r.token){
        $r=Invoke-RestMethod -Uri "$($script:WarpApi)/$($r.id)" -Headers @{ 'CF-Client-Version'=$script:WarpHeaders['CF-Client-Version']; Authorization="Bearer $($r.token)" } `
             -UserAgent $script:WarpUserAgent -TimeoutSec 30 -ErrorAction Stop
        $cfg=$r.config
    }
    if(-not $cfg -or -not $cfg.peers){ throw 'Ответ WARP не содержит конфигурации туннеля.' }
    $reserved=@(0,0,0)
    if($cfg.client_id){ try { $reserved=@([Convert]::FromBase64String($cfg.client_id) | ForEach-Object { [int]$_ }) } catch {} }
    $acc=[ordered]@{
        private_key=$priv
        peer_public_key=$cfg.peers[0].public_key
        address_v4=$cfg.interface.addresses.v4
        address_v6=$cfg.interface.addresses.v6
        reserved=$reserved
        device_id=$r.id
        token=$r.token
        source='register'
    }
    Write-JsonFile $p.Account $acc
    Write-Host '  Устройство WARP зарегистрировано.' -ForegroundColor Green
}

function Import-WarpConfig {
    # Импорт WireGuard-конфига WARP (wgcf-profile.conf, WarpGen и т.п.).
    param([string]$Path)
    if(-not $Path -or -not (Test-Path -LiteralPath $Path)){ throw "Файл конфига не найден: $Path" }
    $kv=@{}
    foreach($l in Get-Content -LiteralPath $Path){
        if($l -match '^\s*([A-Za-z]+)\s*=\s*(.+?)\s*$'){ $kv[$Matches[1].ToLowerInvariant()]=$Matches[2] }
    }
    if(-not $kv['privatekey'] -or -not $kv['publickey']){ throw 'В конфиге нет PrivateKey/PublicKey.' }
    $v4=$null; $v6=$null
    foreach($a in ($kv['address'] -split ',')){
        $a=$a.Trim() -replace '/\d+$',''
        if($a -match ':'){ $v6=$a } elseif($a){ $v4=$a }
    }
    $reserved=@(0,0,0)
    if($kv['reserved']){
        $parts=@($kv['reserved'] -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
        if($parts.Count -eq 3){ $reserved=$parts }
    }
    $p=Get-WarpPaths
    New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null
    Write-JsonFile $p.Account ([ordered]@{
        private_key=$kv['privatekey']; peer_public_key=$kv['publickey']
        address_v4=$v4; address_v6=$v6; reserved=$reserved; source='import'
    })
    Remove-Item $p.State -Force -ErrorAction SilentlyContinue
    Write-Host '  Конфиг WARP импортирован. Узел будет подобран заново.' -ForegroundColor Green
}

function New-WarpEndpointJson {
    param($Acc,[string]$Endpoint)
    $ip,$port=$Endpoint -split ':'
    $addr=@()
    if($Acc.address_v4){ $addr+="$($Acc.address_v4)/32" }
    if($Acc.address_v6){ $addr+="$($Acc.address_v6)/128" }
    [ordered]@{
        type='wireguard'; tag='warp'; mtu=1280
        address=$addr
        private_key=$Acc.private_key
        peers=@([ordered]@{
            address=$ip; port=[int]$port
            public_key=$Acc.peer_public_key
            allowed_ips=@('0.0.0.0/0','::/0')
            persistent_keepalive_interval=25
            reserved=@($Acc.reserved | ForEach-Object { [int]$_ })
        })
    }
}

function Write-WarpRules {
    # rule-set для sing-box из lists\warp.txt; sing-box перечитывает его сам.
    $p=Get-WarpPaths
    $d=@(Get-ListEntries $p.List)
    if(-not $d.Count){ $d=@('warp.invalid') }   # пустое правило sing-box не примет
    Write-JsonFile $p.Rules ([ordered]@{ version=2; rules=@([ordered]@{ domain_suffix=$d }) })
}

function Write-WarpConfig {
    param([string]$Endpoint)
    $p=Get-WarpPaths
    $acc=Read-JsonFile $p.Account
    Write-WarpRules
    $cfg=[ordered]@{
        log=[ordered]@{ level='warn'; timestamp=$true; output=$p.Log }
        dns=[ordered]@{
            servers=@(
                [ordered]@{ type='local'; tag='local' },
                [ordered]@{ type='fakeip'; tag='fakeip'; inet4_range='198.18.0.0/15'; inet6_range='fc00::/18' },
                [ordered]@{ type='udp'; tag='warp-dns'; server='1.1.1.1'; detour='warp' }
            )
            rules=@([ordered]@{ inbound=@('tun-in'); rule_set=@('warp-domains'); query_type=@('A','AAAA'); server='fakeip' })
            final='local'
        }
        endpoints=@(New-WarpEndpointJson $acc $Endpoint)
        inbounds=@(
            [ordered]@{
                type='tun'; tag='tun-in'; interface_name='Zapret2WARP'
                address=@('172.19.0.1/30','fdfe:dcba:9876::1/126'); mtu=1400
                auto_route=$true; strict_route=$true; stack='gvisor'
                # В TUN идут только FakeIP: остальной трафик мимо sing-box.
                route_address=@('198.18.0.0/15','fc00::/18')
            },
            [ordered]@{ type='mixed'; tag='mixed-in'; listen='127.0.0.1'; listen_port=$script:WarpMixedPort }
        )
        outbounds=@([ordered]@{ type='direct'; tag='direct' })
        route=[ordered]@{
            rule_set=@([ordered]@{ type='local'; tag='warp-domains'; format='source'; path=$p.Rules })
            rules=@(
                [ordered]@{ action='sniff' },
                [ordered]@{ protocol='dns'; action='hijack-dns' },
                [ordered]@{ inbound=@('tun-in','mixed-in'); action='resolve'; server='warp-dns' },
                [ordered]@{ inbound=@('tun-in','mixed-in'); outbound='warp' }
            )
            final='direct'
            auto_detect_interface=$true
            default_domain_resolver='local'
        }
        experimental=[ordered]@{ cache_file=[ordered]@{ enabled=$true; path=$p.Cache; store_fakeip=$true } }
    }
    Write-JsonFile $p.Config $cfg
}

function Write-WarpProbeConfig {
    param([string]$Endpoint,[int]$Port)
    $p=Get-WarpPaths
    $acc=Read-JsonFile $p.Account
    Write-JsonFile $p.Probe ([ordered]@{
        log=[ordered]@{ level='info' }
        endpoints=@(New-WarpEndpointJson $acc $Endpoint)
        inbounds=@([ordered]@{ type='mixed'; tag='mixed-in'; listen='127.0.0.1'; listen_port=$Port })
        route=[ordered]@{ final='warp'; auto_detect_interface=$true }
    })
}

function Get-FileTail {
    param([string]$Path,[int]$Lines=12)
    if(-not (Test-Path -LiteralPath $Path)){ return @() }
    try {
        # sing-box держит файл открытым - читаем с FileShare.ReadWrite.
        $fs=[IO.File]::Open($Path,'Open','Read','ReadWrite')
        $sr=New-Object IO.StreamReader($fs)
        $all=$sr.ReadToEnd(); $sr.Close()
        $all=$all -replace "$([char]27)\[[0-9;]*m",''   # цвета sing-box
        return @($all -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last $Lines)
    } catch { return @() }
}

function Set-WarpError {
    # Запоминает причину сбоя: её видно в меню WARP, а не только в момент запуска.
    param([string]$Message,[string[]]$Details=@())
    $p=Get-WarpPaths
    Write-Host "  $Message" -ForegroundColor Red
    foreach($l in $Details){ Write-Host "    $l" -ForegroundColor DarkGray }
    try {
        New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null
        [IO.File]::WriteAllLines($p.LastError,@("$((Get-Date).ToString('s')) $Message")+$Details,[Text.UTF8Encoding]::new($false))
    } catch {}
}

function Clear-WarpError {
    Remove-Item (Get-WarpPaths).LastError -Force -ErrorAction SilentlyContinue
}

function Wait-LocalPort {
    param([int]$Port,[int]$TimeoutMs=4000,$Process=$null)
    $sw=[Diagnostics.Stopwatch]::StartNew()
    while($sw.ElapsedMilliseconds -lt $TimeoutMs){
        if($Process -and $Process.HasExited){ return $false }
        if(Test-TcpQuick -IP '127.0.0.1' -Port $Port -TimeoutMs 300){ return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

function Invoke-WarpTrace {
    # Запрос https://1.1.1.1/cdn-cgi/trace через локальный прокси sing-box.
    # Возвращает время ответа в мс или -1. "warp=on" подтверждает туннель.
    param([int]$Port,[int]$TimeoutMs=5000)
    try {
        $req=[Net.HttpWebRequest]::Create('http://1.1.1.1/cdn-cgi/trace')
        $req.Proxy=New-Object Net.WebProxy("http://127.0.0.1:$Port")
        $req.Timeout=$TimeoutMs; $req.ReadWriteTimeout=$TimeoutMs; $req.KeepAlive=$false
        $sw=[Diagnostics.Stopwatch]::StartNew()
        $resp=$req.GetResponse()
        $text=(New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
        $resp.Close(); $sw.Stop()
        if($text -match 'warp=(on|plus)'){ return [int]$sw.ElapsedMilliseconds }
    } catch {}
    return -1
}

function Test-WarpEndpoint {
    # Пробный туннель к узлу: 3 запроса, задержка = лучший из 2-го и 3-го
    # (первый включает рукопожатие WireGuard).
    param([string]$Endpoint)
    $p=Get-WarpPaths
    Write-WarpProbeConfig -Endpoint $Endpoint -Port $script:WarpProbePort
    $proc=Start-Process -FilePath $p.Exe -ArgumentList @('run','-c',"`"$($p.Probe)`"") -WindowStyle Hidden -PassThru `
              -RedirectStandardError $p.ProbeLog -RedirectStandardOutput "$($p.ProbeLog).out"
    try {
        if(-not (Wait-LocalPort $script:WarpProbePort 8000 $proc)){ return -1 }
        if((Invoke-WarpTrace $script:WarpProbePort 4000) -lt 0){ return -1 }
        $t=@(); foreach($i in 1..2){ $x=Invoke-WarpTrace $script:WarpProbePort 3000; if($x -ge 0){ $t+=$x } }
        if(-not $t.Count){ return -1 }
        return ($t | Measure-Object -Minimum).Minimum
    } finally {
        if(-not $proc.HasExited){ Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        $proc.WaitForExit(3000) | Out-Null
    }
}

function Find-WarpEndpoint {
    # Автоподбор узла Cloudflare. Этап 1: по случайному адресу из каждой
    # подсети WARP на порту 2408. Этап 2 (если рабочих мало): другие
    # официальные порты WARP - провайдер может резать отдельные порты.
    param([string[]]$Skip=@())
    $p=Get-WarpPaths
    $wasRunning=(Get-WarpStatus).Running
    Stop-Warp -Quiet
    $rnd=New-Object Random
    $cands=New-Object System.Collections.Generic.List[string]
    $cands.Add('162.159.192.1:2408')
    foreach($pre in $script:WarpPrefixes){ $cands.Add(("{0}.{1}:2408" -f $pre,$rnd.Next(1,255))) }
    $results=New-Object System.Collections.Generic.List[object]
    Write-Host '  Подбор узла Cloudflare WARP...' -ForegroundColor Yellow
    $test={
        param($ep)
        if($Skip -contains $ep){ return }
        Write-Host ("    {0,-22} " -f $ep) -NoNewline
        $ms=Test-WarpEndpoint $ep
        if($ms -ge 0){ $results.Add([pscustomobject]@{ endpoint=$ep; ms=[int]$ms }); Write-Host "$ms мс" -ForegroundColor Green }
        else { Write-Host 'нет ответа' -ForegroundColor DarkGray }
    }
    foreach($c in $cands){ & $test $c }
    if($results.Count -lt 2){
        foreach($port in ($script:WarpPorts | Where-Object { $_ -ne 2408 })){
            foreach($pre in $script:WarpPrefixes){
                & $test ("{0}.{1}:{2}" -f $pre,$rnd.Next(1,255),$port)
                if($results.Count -ge 3){ break }
            }
            if($results.Count -ge 3){ break }
        }
    }
    $ranked=@($results | Sort-Object ms)
    if(-not $ranked.Count){
        Set-WarpError 'Ни один узел WARP не ответил.' (@('Журнал последней пробы sing-box:') + @(Get-FileTail $p.ProbeLog 8))
        Write-Host '  Возможно, WireGuard к Cloudflare заблокирован провайдером.' -ForegroundColor Yellow
        Write-Host '  Попробуйте с запущенным обходом zapret (он маскирует рукопожатие) или импортируйте' -ForegroundColor DarkGray
        Write-Host '  другой конфиг: -Action WarpImport -WarpConfig <файл>.' -ForegroundColor DarkGray
        return $null
    }
    Write-JsonFile $p.State ([ordered]@{ best=$ranked[0].endpoint; ranked=$ranked; tested=(Get-Date).ToString('s') })
    Write-Host ("  Лучший узел: {0} ({1} мс)" -f $ranked[0].endpoint,$ranked[0].ms) -ForegroundColor Green
    if($wasRunning){ Start-Warp }
    return $ranked[0].endpoint
}

function Get-WarpStatus {
    $p=Get-WarpPaths
    $proc=@(Get-CimInstance Win32_Process -Filter "Name='sing-box.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -eq $p.Exe })
    $st=Read-JsonFile $p.State
    [pscustomobject]@{
        Enabled=(Test-Path $p.Enabled)
        Installed=(Test-Path $p.Exe) -and (Test-Path $p.Account)
        Running=[bool]$proc.Count
        Endpoint=if($st){$st.best}else{$null}
        Domains=@(Get-ListEntries $p.List).Count
    }
}

function Start-WarpProcess {
    <#
      Возвращает 'ok', 'crash' (sing-box завершился: ошибка конфига, TUN,
      прав - перебор узлов тут не поможет) или 'notunnel' (sing-box работает,
      но трафик через WARP не идёт - стоит попробовать другой узел).
    #>
    param([string]$Endpoint)
    # stderr внешних программ при 'Stop' в PS 5.1 превращается в исключение.
    $ErrorActionPreference='Continue'
    $p=Get-WarpPaths
    Write-WarpConfig -Endpoint $Endpoint
    $chk=& $p.Exe check -c $p.Config 2>&1
    if($LASTEXITCODE -ne 0){
        Set-WarpError 'Конфиг sing-box не прошёл проверку.' @($chk | ForEach-Object { "$_" })
        return 'crash'
    }
    foreach($f in @($p.Log,$p.ErrLog)){ Remove-Item $f -Force -ErrorAction SilentlyContinue }
    $proc=Start-Process -FilePath $p.Exe -ArgumentList @('run','-c',"`"$($p.Config)`"") -WorkingDirectory $p.Dir -WindowStyle Hidden -PassThru `
              -RedirectStandardError $p.ErrLog -RedirectStandardOutput "$($p.ErrLog).out"
    $null=$proc.Handle   # без этого ExitCode после завершения бывает пустым
    [IO.File]::WriteAllText($p.Pid,[string]$proc.Id,[Text.Encoding]::ASCII)
    # При первом запуске Windows создаёт адаптер Wintun - это бывает дольше
    # 10 секунд. Ждём, пока процесс жив, до 30 секунд.
    if(-not (Wait-LocalPort $script:WarpMixedPort 30000 $proc)){
        $why=@(Get-FileTail $p.ErrLog 10) + @(Get-FileTail $p.Log 10)
        if($proc.HasExited){
            Set-WarpError ("sing-box завершился с кодом $($proc.ExitCode).") $why
        } else {
            Set-WarpError 'sing-box не открыл локальный порт за 30 секунд.' $why
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
        return 'crash'
    }
    # Рукопожатие WireGuard и маршруты TUN - даём три попытки.
    foreach($i in 1..3){
        if($proc.HasExited){ break }
        if((Invoke-WarpTrace $script:WarpMixedPort 6000) -ge 0){ Clear-WarpError; return 'ok' }
        Start-Sleep -Seconds 1
    }
    if($proc.HasExited){
        Set-WarpError ("sing-box завершился с кодом $($proc.ExitCode).") (@(Get-FileTail $p.ErrLog 10) + @(Get-FileTail $p.Log 10))
        return 'crash'
    }
    Set-WarpError "Через узел $Endpoint не идёт трафик." @(Get-FileTail $p.Log 8)
    return 'notunnel'
}

function Start-Warp {
    Ensure-Admin
    $p=Get-WarpPaths
    try {
        if(-not (Test-Path $p.Exe)){ Install-SingBox }
        if(-not (Test-Path $p.Account)){ New-WarpAccount }
    } catch {
        Set-WarpError ($_.Exception.Message -split "`n")[0] @(($_.Exception.Message -split "`n") | Select-Object -Skip 1)
        return
    }
    Stop-Warp -Quiet
    $st=Read-JsonFile $p.State
    $ep=if($st){ $st.best } else { $null }
    if(-not $ep){ $ep=Find-WarpEndpoint }
    if(-not $ep){ return }
    Write-Host "  Запуск sing-box (узел $ep)..." -ForegroundColor Yellow
    $r=Start-WarpProcess $ep
    if($r -eq 'notunnel'){
        # Узел перестал отвечать (заблокирован или ушёл) - подбираем новый.
        Write-Host "  Узел $ep не отвечает, подбираю другой..." -ForegroundColor Yellow
        Stop-Warp -Quiet
        $ep=Find-WarpEndpoint -Skip @($ep)
        $r=if($ep){ Start-WarpProcess $ep } else { 'crash' }
    }
    if($r -ne 'ok'){
        Stop-Warp -Quiet
        Write-Host '  WARP не запущен. Причина выше; она же в меню WARP и в журналах:' -ForegroundColor Red
        Write-Host "    $($p.Log)" -ForegroundColor DarkGray
        Write-Host "    $($p.ErrLog)" -ForegroundColor DarkGray
        return
    }
    & ipconfig.exe /flushdns | Out-Null
    Write-Host "  WARP работает через узел $ep. Сайтов в списке WARP: $((Get-WarpStatus).Domains)" -ForegroundColor Green
}

function Stop-Warp {
    param([switch]$Quiet)
    $p=Get-WarpPaths
    for($i=0;$i -lt 10;$i++){
        $procs=@(Get-CimInstance Win32_Process -Filter "Name='sing-box.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.ExecutablePath -eq $p.Exe })
        if(-not $procs.Count){ break }
        $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 300
    }
    Remove-Item $p.Pid -Force -ErrorAction SilentlyContinue
    if(-not $Quiet){ Write-Host '  WARP остановлен.' -ForegroundColor Yellow }
}

function Enable-Warp {
    Ensure-Admin
    $p=Get-WarpPaths
    New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null
    if(-not (Test-Path $p.List)){ $null=Merge-ListFile $p.List $script:SeedWarp }
    [IO.File]::WriteAllText($p.Enabled,'1',[Text.Encoding]::ASCII)
    Start-Warp
    if((Get-WarpStatus).Running){
        $a='y'
        if($Action -eq 'Menu'){ $a=Read-Host '  Проверить сайты из списков и перенести в WARP те, что не открываются через zapret? (Y/n)' }
        if($a -notmatch '^\s*[nNнН]'){ Update-WarpRoutes }
    }
}

function Disable-Warp {
    $p=Get-WarpPaths
    Remove-Item $p.Enabled -Force -ErrorAction SilentlyContinue
    Stop-Warp
    & ipconfig.exe /flushdns | Out-Null
}

function Toggle-Warp {
    if((Get-WarpStatus).Enabled){ Disable-Warp } else { Enable-Warp }
}

function Test-HttpsBatch {
    <#
      Параллельная проверка https://<домен>/ . Успех - получен HTTP-ответ и
      прочитано 64 КБ тела (или оно кончилось раньше): так ловится и обрыв
      "16 КБ", а не только недоступность. Код ответа не важен - сам факт
      ответа значит, что сеть до сайта работает.
    #>
    param([string[]]$Domains,[string]$Proxy)
    Add-Type -AssemblyName System.Net.Http
    $proto=[Net.SecurityProtocolType]::Tls12
    try { $proto=$proto -bor [Net.SecurityProtocolType]'Tls13' } catch {}
    [Net.ServicePointManager]::SecurityProtocol=$proto
    $h=New-Object System.Net.Http.HttpClientHandler
    $h.AllowAutoRedirect=$false
    if($Proxy){ $h.Proxy=New-Object Net.WebProxy($Proxy); $h.UseProxy=$true } else { $h.UseProxy=$false }
    $c=New-Object System.Net.Http.HttpClient($h)
    $c.Timeout=[TimeSpan]::FromSeconds(12)
    [void]$c.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent','Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36')
    $tasks=@{}
    foreach($d in $Domains){
        $tasks[$d]=$c.GetAsync("https://$d/",[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
    }
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($tasks.Values),15000) } catch {}
    $res=@{}
    foreach($d in $Domains){
        $t=$tasks[$d]; $ok=$false
        if($t.Status -eq 'RanToCompletion'){
            try {
                $s=$t.Result.Content.ReadAsStreamAsync().Result
                $buf=New-Object byte[] 16384; $total=0
                while($total -lt 65536){
                    $rt=$s.ReadAsync($buf,0,$buf.Length)
                    if(-not $rt.Wait(5000)){ break }
                    if($rt.Result -le 0){ $ok=$true; break }
                    $total+=$rt.Result
                }
                if($total -ge 65536){ $ok=$true }
                $s.Dispose()
            } catch {}
            try { $t.Result.Dispose() } catch {}
        }
        $res[$d]=$ok
    }
    $c.Dispose()
    return $res
}

function Remove-HostsDomains {
    # Убирает из нашего блока hosts строки этих доменов: иначе hosts
    # перекроет DNS sing-box и домен не попадёт в WARP.
    param([string[]]$Domains)
    $hf=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if(-not $Domains.Count -or -not (Test-Path $hf)){ return }
    $set=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($d in $Domains){ [void]$set.Add($d); [void]$set.Add("www.$d") }
    $in=$false; $changed=$false
    $out=New-Object System.Collections.Generic.List[string]
    foreach($l in [IO.File]::ReadAllLines($hf)){
        if($l -match 'Zapret2Windows DoH begin'){ $in=$true }
        elseif($l -match 'Zapret2Windows DoH end'){ $in=$false }
        elseif($in -and $l -match '^\s*\S+\s+(\S+)' -and $set.Contains($Matches[1])){ $changed=$true; continue }
        $out.Add($l)
    }
    if($changed){ [IO.File]::WriteAllLines($hf,$out,[Text.Encoding]::ASCII) }
}

function Update-WarpRoutes {
    <#
      "WARP там, где не справляется zapret": проверяем домены из списков
      zapret напрямую (через zapret); не открывшиеся проверяем через WARP и,
      если там они работают, переносим в lists\warp.txt.
    #>
    Ensure-Admin
    $p=Get-WarpPaths
    if(-not (Get-WarpStatus).Running){ Write-Host '  WARP не запущен.' -ForegroundColor Red; return }
    if(-not (Get-Status).Running){
        Write-Host '  Внимание: zapret не запущен - в WARP попадут и сайты, которые zapret открыл бы сам.' -ForegroundColor Yellow
    }
    $lists=Join-Path $script:TrustedRuntime 'lists'
    $inWarp=@(Get-ListEntries $p.List)
    $excl=@(Get-ListEntries (Join-Path $lists 'exclude.txt'))
    $cands=@(@(Get-ListEntries (Join-Path $lists 'blocked.txt')) + @(Get-ListEntries (Join-Path $lists 'autohostlist.txt')) |
             Select-Object -Unique | Where-Object { $inWarp -notcontains $_ -and $excl -notcontains $_ })
    if(-not $cands.Count){ Write-Host '  Нечего проверять.' -ForegroundColor DarkGray; return }
    Write-Host ("  Проверка {0} сайтов через zapret..." -f $cands.Count) -ForegroundColor Yellow
    $direct=Test-HttpsBatch -Domains $cands
    $failed=@($cands | Where-Object { -not $direct[$_] })
    Write-Host ("  Открываются через zapret: {0}, не открываются: {1}" -f ($cands.Count-$failed.Count),$failed.Count) -ForegroundColor DarkGray
    if(-not $failed.Count){ Write-Host '  WARP не нужен ни одному сайту из списков.' -ForegroundColor Green; return }
    Write-Host '  Проверка неоткрывшихся через WARP...' -ForegroundColor Yellow
    $viaWarp=Test-HttpsBatch -Domains $failed -Proxy "http://127.0.0.1:$($script:WarpMixedPort)"
    $move=@($failed | Where-Object { $viaWarp[$_] })
    $dead=@($failed | Where-Object { -not $viaWarp[$_] })
    if($move.Count){
        $null=Merge-ListFile $p.List $move
        Write-WarpRules
        Remove-HostsDomains $move
        & ipconfig.exe /flushdns | Out-Null
        Write-Host ("  Перенесено в WARP: {0}" -f ($move -join ', ')) -ForegroundColor Green
    }
    if($dead.Count){
        Write-Host ("  Не открываются и через WARP (нет сайта на корне домена, геоблок или сбой): {0}" -f ($dead -join ', ')) -ForegroundColor DarkGray
    }
    Write-Host "  Список WARP: $($p.List) (можно править вручную)." -ForegroundColor DarkGray
}

function Show-WarpMenu {
    while($true){
        $w=Get-WarpStatus
        Write-Host ''
        Write-Host ('  WARP: ' + $(if($w.Enabled){'включён'}else{'выключен'}) + ' | ' +
                    $(if($w.Running){"работает, узел $($w.Endpoint)"}else{'не запущен'}) +
                    ' | сайтов в списке: ' + $w.Domains) -ForegroundColor Cyan
        if($w.Enabled -and -not $w.Running){
            $le=Get-FileTail (Get-WarpPaths).LastError 6
            if($le.Count){
                Write-Host '  Последняя ошибка:' -ForegroundColor Red
                $le | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            }
        }
        Write-Host ('  [1] ' + $(if($w.Enabled){'Выключить WARP'}else{'Включить WARP'}))
        Write-Host '  [2] Подобрать лучший узел Cloudflare заново'
        Write-Host '  [3] Проверить сайты и перенести в WARP те, что не открываются через zapret'
        Write-Host '  [4] Добавить домен в WARP вручную'
        Write-Host '  [5] Импортировать WireGuard-конфиг WARP (если регистрация не проходит)'
        Write-Host '  [0] Назад'
        $choice=Read-Host '  Выбор'
        if($choice -eq '0'){ return }
        try {
        switch($choice){
            '1' { Toggle-Warp }
            '2' { [void](Find-WarpEndpoint) }
            '3' { Update-WarpRoutes }
            '4' {
                $d=(Read-Host '  Домен (например, example.com)').Trim().ToLowerInvariant()
                if($d -match '^[a-z0-9.-]+\.[a-z0-9-]+$'){
                    $p=Get-WarpPaths
                    $null=Merge-ListFile $p.List @($d); Write-WarpRules; Remove-HostsDomains @($d)
                    & ipconfig.exe /flushdns | Out-Null
                    Write-Host "  $d добавлен в WARP." -ForegroundColor Green
                } else { Write-Host '  Некорректный домен.' -ForegroundColor Red }
            }
            '5' { Import-WarpConfig -Path (Read-Host '  Путь к .conf'); if((Get-WarpStatus).Enabled){ Start-Warp } }
        }
        } catch {
            Set-WarpError ('Ошибка: ' + $_.Exception.Message)
        }
    }
}

function Show-Menu {
    # При первом запуске проверяем зависимости и предлагаем их поставить.
    if(-not $script:DepsChecked){
        $script:DepsChecked=$true
        $rep=Get-DependencyReport
        $miss=@($rep | Where-Object { $_.Status -eq 'FAIL' -and $_.Fixable })
        $hard=@($rep | Where-Object { $_.Status -eq 'FAIL' -and -not $_.Fixable })
        if($miss.Count -or $hard.Count){
            Clear-Host
            Write-Host ''
            Write-Host '  Обнаружены отсутствующие зависимости' -ForegroundColor Yellow
            Write-Host ''
            foreach($m in $miss){ Write-Host ('    - ' + $m.Name + ': ' + $m.Detail) -ForegroundColor DarkGray }
            foreach($m in $hard){ Write-Host ('    - ' + $m.Name + ': ' + $m.Detail + ' (ручной шаг)') -ForegroundColor DarkGray }
            Write-Host ''
            if($miss.Count){
                $a=Read-Host '  Установить автоматически сейчас? (y/N)'
                if($a -match '^\s*[yYдД]'){ [void](Install-Dependencies -IncludeOptional -Yes) }
            }
            Write-Host ''
            Write-Host '  Нажмите Enter для продолжения...' -ForegroundColor DarkGray
            [void](Read-Host)
        }
    }
    while($true){
        Clear-Host
        Write-Host '  Zapret2 Windows — системная DPI-десинхронизация' -ForegroundColor Cyan
        Write-Host ('  Версия ' + $script:ScriptVersion + ' | zapret2 v1.0.6 | перехват WinDivert') -ForegroundColor DarkGray
        $st=Get-Status
        Write-Host ('  winws2: ' + $(if($st.Running){"работает (PID $($st.Pid))"}else{'остановлен'}) +
                    ' | автозапуск: ' + $(if($st.AutoStart){'включён'}else{'выключен'}) +
                    ' | доменов: ' + $st.LearnedDomains)
        $w=Get-WarpStatus
        if($w.Enabled -or $w.Installed){
            Write-Host ('  WARP: ' + $(if($w.Running){"работает (узел $($w.Endpoint))"}else{'не запущен'}) + ' | сайтов в WARP: ' + $w.Domains)
        }
        Write-Host ''
        Write-Host ('  [1] ' + $(if($st.Runtime){'Обновить среду zapret2'}else{'Установить среду zapret2'}))
        Write-Host ('  [2] ' + $(if($st.Running){'Остановить обход'}else{'Запустить обход'}))
        Write-Host ('  [3] Автозапуск при входе: ' + $(if($st.AutoStart){'выключить'}else{'включить'}))
        Write-Host '  [4] Диагностика ресурсов'
        Write-Host '  [5] Проверить требования'
        Write-Host '  [6] Установить отсутствующие зависимости'
        Write-Host '  [7] Обновить DNS через DoH'
        Write-Host '  [8] Выученные домены и журналы'
        Write-Host ('  [9] Обновить скрипт (у вас ' + $script:ScriptVersion + ')')
        Write-Host '  [10] Удалить из системы' -ForegroundColor Yellow
        Write-Host '  [11] WARP для сайтов, которые не открывает zapret'
        Write-Host '  [0] Выход'
        $choice=Read-Host '  Выбор'
        try {
            switch($choice){
                '1' {Install-Runtime; Read-Host '  Нажмите Enter'}
                '2' {Toggle-Run; Read-Host '  Нажмите Enter'}
                '3' {Toggle-Autostart; Read-Host '  Нажмите Enter'}
                '4' {Diagnose; Read-Host '  Нажмите Enter'}
                '5' {Show-Check; Read-Host '  Нажмите Enter'}
                '6' {Install-Dependencies -IncludeOptional; Read-Host '  Нажмите Enter'}
                '7' {Update-DohHosts; Read-Host '  Нажмите Enter'}
                '8' {
                    $f=Join-Path $script:TrustedRuntime 'lists\autohostlist.txt'
                    Write-Host ''
                    if(Test-Path $f){
                        $learned=@(Get-Content $f | Where-Object { $_ -and $_ -notmatch '^\s*#' })
                        Write-Host ("  Выучено доменов: " + $learned.Count) -ForegroundColor Cyan
                        $learned | Select-Object -First 30 | ForEach-Object { Write-Host ('    ' + $_) -ForegroundColor DarkGray }
                        if($learned.Count -gt 30){ Write-Host ('    ... и ещё ' + ($learned.Count-30)) -ForegroundColor DarkGray }
                    } else {
                        Write-Host '  Среда не установлена — список пуст.' -ForegroundColor Yellow
                    }
                    $logs=Join-Path $script:TrustedRuntime 'logs'
                    if(Test-Path $logs){
                        Write-Host ''
                        Write-Host ('  Журналы: ' + $logs) -ForegroundColor DarkGray
                        Start-Process explorer.exe $logs
                    }
                    Read-Host '  Нажмите Enter'
                }
                '9' {Update-Self; if($script:ScriptVersion){Read-Host '  Нажмите Enter'}}
                '10' {Remove-All}
                '11' {Show-WarpMenu}
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
    <#
      Собирает A-записи домена со ВСЕХ DoH-провайдеров, а не с первого
      ответившего. Это принципиально: разные провайдеры и разные edge-узлы
      CDN отдают разные адреса, и среди них бывает мёртвый (типично для
      Meta/Instagram: 31.13.72.174 не работает, 57.145.12.34 работает).
      Если вернуть только первый ответ, рабочий адрес потеряется.
    #>
    param([string]$Name,[int]$TimeoutSec=6,[switch]$FirstProviderOnly)
    $all=New-Object System.Collections.Generic.List[string]
    foreach($p in $script:DohProviders){
        try {
            $sep=if($p -match '\?'){'&'}else{'?'}
            $u="$p${sep}name=$Name&type=A"
            $r=Invoke-RestMethod -Uri $u -Headers @{accept='application/dns-json'} -TimeoutSec $TimeoutSec -ErrorAction Stop
            foreach($ip in @($r.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data } |
                              Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })){
                if(-not $all.Contains($ip)){ $all.Add($ip) }
            }
            if($FirstProviderOnly -and $all.Count){ break }
        } catch {}
    }
    return @($all)
}

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
      Возвращает первый РАБОЧИЙ IP домена или $null.
      DoH часто отдаёт мёртвый edge-IP (типично для Meta/Instagram), поэтому
      все кандидаты проверяются реальным TCP-соединением на 443. Источники
      кандидатов, по порядку:
        1. A-записи самого домена (со всех DoH-провайдеров);
        2. CNAME-цели и их A-записи (рабочие адреса часто лежат там);
        3. A-записи родительского домена (www.X -> X).
      Приоритет отдаётся адресам, полученным при опросе нескольких
      провайдеров: именно так находится живой узел вместо мёртвого.
    #>
    param([string]$Domain,[int]$MaxCandidates=8)
    $cands=New-Object System.Collections.Generic.List[string]
    $add={
        param($list)
        foreach($ip in @($list)){ if($ip -and -not $cands.Contains($ip)){ [void]$cands.Add($ip) } }
    }

    & $add (Resolve-DohName -Name $Domain)

    foreach($cn in @(Resolve-DohCname -Name $Domain)){
        & $add (Resolve-DohName -Name $cn)
    }

    # www.X -> X: у родительского имени набор узлов шире
    if($Domain -match '^www\.(.+)$'){ & $add (Resolve-DohName -Name $Matches[1]) }

    if(-not $cands.Count){ return $null }

    # Последовательная проверка. Runspace-пул в PowerShell 5.1 ненадёжен
    # внутри функций, а кандидатов обычно 2-6, так что это быстро.
    $limit=[Math]::Min($cands.Count,$MaxCandidates)
    # Сначала ищем адрес с правильным сертификатом. Если DPI рвёт
    # TLS-рукопожатие (обход ещё не запущен), ни один не пройдёт - тогда,
    # как раньше, берём первый адрес, принимающий TCP-соединение.
    for($i=0;$i -lt $limit;$i++){
        if(Test-TlsCert -IP $cands[$i] -HostName $Domain -TimeoutMs 2000){ return $cands[$i] }
    }
    for($i=0;$i -lt $limit;$i++){
        if(Test-TcpQuick -IP $cands[$i] -Port 443 -TimeoutMs 1500){ return $cands[$i] }
    }
    return $null
}

function Test-BogonIP {
    # Адреса, которые провайдерский DNS подставляет вместо настоящих
    # (заглушки, 0.0.0.0, локальные сети) - это признак DNS-подмены.
    param([string]$IP)
    return ($IP -match '^(0\.|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)')
}

function Test-TlsCert {
    <#
      TLS-рукопожатие с IP и проверка, что сертификат действительно выдан
      на HostName. Заглушка провайдера или чужой узел такой сертификат
      предъявить не могут, поэтому это надёжнее простого TCP-коннекта.
    #>
    param([string]$IP,[string]$HostName,[int]$TimeoutMs=2500)
    $tcp=$null; $ssl=$null
    try {
        $tcp=[Net.Sockets.TcpClient]::new()
        $ar=$tcp.BeginConnect($IP,443,$null,$null)
        if(-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)){ return $false }
        $tcp.EndConnect($ar)
        $tcp.ReceiveTimeout=$TimeoutMs; $tcp.SendTimeout=$TimeoutMs
        $ssl=[Net.Security.SslStream]::new($tcp.GetStream(),$false)
        $proto=[Security.Authentication.SslProtocols]::Tls12
        try { $proto=$proto -bor [Security.Authentication.SslProtocols]'Tls13' } catch {}
        $ar2=$ssl.BeginAuthenticateAsClient($HostName,$null,$proto,$false,$null,$null)
        if(-not $ar2.AsyncWaitHandle.WaitOne($TimeoutMs)){ return $false }
        $ssl.EndAuthenticateAsClient($ar2)
        return [bool]$ssl.IsAuthenticated
    } catch { return $false }
    finally { if($ssl){$ssl.Dispose()}; if($tcp){$tcp.Dispose()} }
}

function Test-SystemDnsOk {
    <#
      Отвечает на вопрос: нужен ли этому домену пиннинг в hosts вообще?
      Берём адреса от СИСТЕМНОГО DNS (минуя hosts) и проверяем сертификат.
      Если системный DNS отдаёт рабочий адрес - пиннинг не нужен и даже
      вреден: CDN (YouTube, Discord, Cloudflare) выбирает ближайший к вам
      узел, а адрес из DoH-ответа другого резолвера бывает дальним и со
      временем устаревает, то есть замедляет или ломает доступ.
    #>
    param([string]$Domain)
    try {
        $ips=@(Resolve-DnsName -Name $Domain -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop |
               Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
    } catch { return $false }
    if(-not $ips.Count){ return $false }
    if(@($ips | Where-Object { Test-BogonIP $_ }).Count){ return $false }
    foreach($ip in @($ips | Select-Object -First 2)){
        if(Test-TlsCert -IP $ip -HostName $Domain){ return $true }
    }
    return $false
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
    # Домены WARP разрешает DNS sing-box; запись в hosts увела бы их мимо туннеля.
    $inWarp=@(Get-ListEntries (Join-Path $script:TrustedRuntime 'lists\warp.txt'))
    $domains=@($domains | Where-Object { $inWarp -notcontains $_.ToLowerInvariant() })
    if(-not $domains.Count){Write-Host '  Список доменов пуст.' -ForegroundColor Yellow; return}
    # hosts сопоставляет ТОЧНОЕ имя, поэтому www-вариант разрешаем отдельно:
    # запись youtube.com не покрывает www.youtube.com.
    $targets=New-Object System.Collections.Generic.List[string]
    foreach($d in $domains){
        $targets.Add($d)
        # www-вариант имеет смысл только для доменов 2-го уровня.
        if($d -notmatch '^www\.' -and ($d.Split('.').Count -eq 2)){$targets.Add("www.$d")}
    }
    $domains=@($targets | Select-Object -Unique)

    if(-not $Quiet){Write-Host ("  DoH-разрешение {0} доменов..." -f $domains.Count) -ForegroundColor Yellow}
    $resolved=New-Object System.Collections.Generic.List[string]
    $failed=New-Object System.Collections.Generic.List[string]
    $sysOk=New-Object System.Collections.Generic.List[string]
    $haveResolveDns=[bool](Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)
    $i=0
    foreach($d in $domains){
        $i++
        if(-not $Quiet){Write-Host ("    [{0}/{1}] {2,-34} " -f $i,$domains.Count,$d) -NoNewline}
        # Системный DNS честный и адрес рабочий - в hosts не пишем.
        if($haveResolveDns -and (Test-SystemDnsOk -Domain $d)){
            $sysOk.Add($d)
            if(-not $Quiet){Write-Host 'системный DNS в порядке' -ForegroundColor DarkGray}
            continue
        }
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
    Write-Host ("  Записано в hosts: {0}, системный DNS в порядке: {1}, не разрешилось: {2}" -f $resolved.Count,$sysOk.Count,$failed.Count) -ForegroundColor Green
    if($resolved.Count -and -not (Get-Status).Running){
        Write-Host '  Совет: повторите это обновление при ЗАПУЩЕННОМ обходе - тогда проверка' -ForegroundColor DarkGray
        Write-Host '  сертификатов проходит и в hosts попадут только домены с подменой DNS.' -ForegroundColor DarkGray
    }
    if($failed.Count){
        Write-Host ("  Без рабочего IP: {0}" -f ($failed -join ', ')) -ForegroundColor DarkGray
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
    Write-Host '    - процессы winws2 и sing-box (WARP), если запущены' -ForegroundColor DarkGray
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
    Write-Host '  [1/5] Остановка winws2 и WARP...' -ForegroundColor Yellow
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

try {
switch($Action){
    'Install' {Install-Runtime}
    'Start' {Start-Zapret}
    'Stop' {Stop-Zapret}
    'Status' {Show-Status}
    'Diagnose' {Diagnose}
    'Check' {Show-Check}
    'Deps' {Install-Dependencies -IncludeOptional -Yes:$Force}
    'DohHosts' {Update-DohHosts}
    'Update' {Update-Self -Force:$Force}
    'Uninstall' {Remove-All -KeepLogs:$KeepLogs -Force:$Force}
    'Purge' {Remove-All -KeepLogs:$KeepLogs -IncludeProject:$IncludeProject -Force:$Force}
    'WarpOn' {Enable-Warp}
    'WarpOff' {Disable-Warp}
    'WarpScan' {Ensure-Admin; [void](Find-WarpEndpoint)}
    'WarpRoutes' {Update-WarpRoutes}
    'WarpImport' {Ensure-Admin; Import-WarpConfig -Path $WarpConfig; if((Get-WarpStatus).Enabled){Start-Warp}}
    'Menu' {Show-Menu}
}
} catch {
    Write-Host ''
    Write-Host '  ОШИБКА ЗАПУСКА' -ForegroundColor Red
    Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    Write-Host ('  Скрипт: ' + $script:AppRoot) -ForegroundColor DarkGray
    Write-Host ('  Действие: ' + $Action) -ForegroundColor DarkGray
    Write-Host ('  Релиз zapret2: ' + $ZapretRoot + ' (' + $(if(Test-Path $ZapretRoot){'найден'}else{'НЕ НАЙДЕН'}) + ')') -ForegroundColor DarkGray
    Write-Host ('  Права администратора: ' + $(if(Test-Admin){'есть'}else{'НЕТ'})) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Подробности:' -ForegroundColor Yellow
    Write-Host ('  ' + $_.ScriptStackTrace) -ForegroundColor DarkGray
    Write-Host ''
    if($Host.Name -eq 'ConsoleHost'){ [void](Read-Host '  Нажмите Enter для выхода') }
    exit 1
}
