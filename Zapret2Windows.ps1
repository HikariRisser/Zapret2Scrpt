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

  Zapret2Windows.ps1 и Zapret2Windows.cmd - один и тот же скрипт в двух
  видах, каждый работает сам по себе, второй файл рядом не нужен:
    * Zapret2Windows.cmd - запуск двойным щелчком;
    * Zapret2Windows.ps1 - правой кнопкой "Выполнить с помощью PowerShell"
      либо  powershell -ExecutionPolicy Bypass -File .\Zapret2Windows.ps1
      (файл .ps1 должен оставаться в кодировке UTF-8 с BOM).
  Права администратора скрипт запрашивает сам.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu','Install','Start','Stop','Status','Diagnose','Check','Deps','DohHosts','Update','Uninstall','Purge','TunnelOn','TunnelOff','TunnelImport','TunnelSelect','TunnelUse','TunnelGeo','TunnelGeoList','TunnelGeoListAuto','TunnelRoutes','TunnelTest','TunnelList','TunnelStart')]
    [string]$Action='Menu',
    [string]$ZapretRoot = '',
    [switch]$NoAutostart,
    [switch]$KeepLogs,        # с Uninstall/Purge: сохранить копию логов
    [switch]$IncludeProject,  # с Uninstall/Purge: удалить и runtime рабочей папки
    [switch]$Force,           # с Uninstall/Purge: без запроса подтверждения
    [string]$TunnelConfig = '',  # с TunnelImport: путь к файлу (WireGuard .conf, JSON, список ссылок)
    [string]$TunnelLink = '',    # с TunnelImport: ссылка на сервер или адрес подписки
    [switch]$Proton,             # с TunnelImport: это конфиг Proton VPN Free
    [string]$TunnelProfile = '', # с TunnelUse: номер или имя профиля; auto - выбрать автоматически
    [switch]$Elevated            # служебный: скрипт перезапущен с правами администратора
)
$ErrorActionPreference='Stop'
# Прогресс-бар Invoke-WebRequest в PS 5.1 замедляет загрузку в разы и
# мусорит вывод фоновых задач - глобально отключаем.
$ProgressPreference='SilentlyContinue'
try { [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false) } catch {}
# Windows PowerShell 5.0 не годится (нет части API), pwsh 6/7 - не тестировался.
$v=$PSVersionTable.PSVersion
if($v.Major -lt 5 -or ($v.Major -eq 5 -and $v.Minor -lt 1)){
    Write-Host 'Нужен Windows PowerShell 5.1 (есть в Windows 10/11).' -ForegroundColor Red
    exit 1
}
if($PSVersionTable.PSEdition -eq 'Core'){
    Write-Host 'Проверено только в Windows PowerShell 5.1; в pwsh поведение может отличаться.' -ForegroundColor Yellow
}
# Путь к самому файлу скрипта. При запуске из Zapret2Windows.cmd код
# исполняется как блок, $PSCommandPath пуст - путь и аргументы командной
# строки лаунчер передаёт в переменных окружения ZAPRET2_SELF и ZAPRET2_ARGS.
$script:SelfPath=$PSCommandPath
if(-not $script:SelfPath -and $env:ZAPRET2_SELF){
    $script:SelfPath=$env:ZAPRET2_SELF
    $zArgs="$env:ZAPRET2_ARGS"
    $env:ZAPRET2_SELF=$null; $env:ZAPRET2_ARGS=$null     # не передавать дочерним процессам
    $zTokens=@([regex]::Matches($zArgs,'"([^"]*)"|(\S+)') |
               ForEach-Object { if($_.Groups[1].Success){ $_.Groups[1].Value } else { $_.Groups[2].Value } })
    $zSwitches=@('NoAutostart','KeepLogs','IncludeProject','Force','Proton','Elevated')
    $zStrings=@('Action','ZapretRoot','TunnelConfig','TunnelLink','TunnelProfile')
    for($zi=0; $zi -lt $zTokens.Count; $zi++){
        $zName=$zTokens[$zi].TrimStart('-')
        if($zTokens[$zi] -notmatch '^-' -or (($zSwitches + $zStrings) -notcontains $zName)){
            Write-Host "Неизвестный параметр: $($zTokens[$zi])" -ForegroundColor Red
            exit 1
        }
        if($zSwitches -contains $zName){ Set-Variable -Name $zName -Value ([switch]$true); continue }
        $zi++
        if($zi -ge $zTokens.Count){ Write-Host "У параметра -$zName нет значения." -ForegroundColor Red; exit 1 }
        try { Set-Variable -Name $zName -Value $zTokens[$zi] }
        catch { Write-Host "Недопустимое значение параметра -${zName}: $($zTokens[$zi])" -ForegroundColor Red; exit 1 }
    }
}
if(-not $script:SelfPath -and $MyInvocation.MyCommand.Path){ $script:SelfPath=$MyInvocation.MyCommand.Path }
$script:SelfIsCmd=("$($script:SelfPath)" -match '\.(cmd|bat)$')
$script:SelfName=$(if($script:SelfIsCmd){'Zapret2Windows.cmd'}else{'Zapret2Windows.ps1'})
# Корень проекта - каталог, где лежит файл скрипта.
$script:AppRoot=$(if($script:SelfPath){ Split-Path -Parent $script:SelfPath } else { (Get-Location).Path })
$script:IsAdmin=$null
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
$script:ScriptVersion='1.8.4'
$script:UpdateRepo='HikariRisser/Zapret2Scrpt'
$script:UpdateBranch='main'

# Версии и SHA-256 скачиваемых артефактов (F-06). Хэш берётся из
# официального релиза (API GitHub отдаёт digest каждого asset). При
# обновлении версии меняйте и хэш. Сверка выполняется ПОСЛЕ скачивания:
# несовпадение - отказ от установки (файл мог быть подменён).
$script:XrayVersion='v26.11.9'   # xray-core закреплён, вместо releases/latest
$script:Sha256=@{
    'zapret2-v1.0.6.zip'              ='e141b51b60c895fe9548f4d644365461dcad8155e068d284a9aae1724504237d'
    'sing-box-1.14.4-windows-amd64.zip'='99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df'
    'sing-box-1.14.4-windows-arm64.zip'='8cd0a4d0cd8cd480be5731ac31f17038969a42d12add9feb6e031fd43d85bbae'
    'sing-box-1.14.4-windows-386.zip'  ='7994c40c5c1316777bdd29216a5dd7f134f894fad0afaa1efe7b872e60ed1dd9'
    'Xray-windows-64.zip'             ='1262522266337b824f07beb8e1375786b437683b3890105469088f8e17e0a69d'
    'Xray-windows-32.zip'             ='a5b6d456688612b678d2d528626d192972c96e645ae4e1e7fbb2566421f60bce'
    'Xray-windows-arm64-v8a.zip'      ='9fdd48ff890e54ffdc37f92df9037c940fe4d4f914755b70cc644b97e9678a83'
}

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
$script:SeedTunnel=@(
    '# Сайты, которые открываются через туннель (sing-box), а не через zapret.',
    '# Пополняется автоматически (меню туннеля) или вручную, по домену в строке.'
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
    # Результат не меняется, пока процесс жив, - считаем один раз.
    if($null -eq $script:IsAdmin){
        $id=[Security.Principal.WindowsIdentity]::GetCurrent()
        $script:IsAdmin=([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    return $script:IsAdmin
}
function Get-SelfLaunch {
    <#
      Команда для повторного запуска этого же скрипта (с правами
      администратора, в фоне, из планировщика): File и Args.
      Скрипт в виде .cmd запускается через cmd.exe, в виде .ps1 - через
      powershell.exe -File.
    #>
    param([string[]]$Arguments=@(),[switch]$Hidden)
    $self=$script:SelfPath
    if(-not $self -or -not (Test-Path -LiteralPath $self)){ throw "Не найден файл скрипта: $self" }
    $tail=($Arguments -join ' ')
    if($script:SelfIsCmd){
        return [pscustomobject]@{ File=$env:ComSpec; Args=('/c ""{0}" {1}"' -f $self,$tail) }
    }
    $hide=$(if($Hidden){'-WindowStyle Hidden '}else{''})
    return [pscustomobject]@{ File=(Join-Path $PSHOME 'powershell.exe')
                              Args=('-NoProfile -ExecutionPolicy Bypass {0}-File "{1}" {2}' -f $hide,$self,$tail) }
}
function Get-ProcessByExe {
    <#
      Процессы с данным именем, запущенные из данного файла. Заметно быстрее
      запроса WMI (Win32_Process), а статус нужен при каждой отрисовке меню.
      Без прав администратора путь чужого процесса не читается - тогда
      считаем совпадением само имя.
    #>
    param([string]$Name,[string]$Path)
    $found=@()
    foreach($pr in [Diagnostics.Process]::GetProcessesByName($Name)){
        $file=$null
        try { $file=$pr.MainModule.FileName } catch {}
        if(-not $file -or $file -ieq $Path){ $found+=$pr }
    }
    return $found
}
function Test-AutostartTask {
    # Есть ли задача автозапуска. Файл задачи проверяется мгновенно, но виден
    # только администратору; иначе - обычный (медленный) запрос планировщика.
    if(Test-Admin){ return (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\Tasks\$($script:TaskName)")) }
    return [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)
}
function Ensure-Admin {
    if(Test-Admin){return}
    # Путь попадает в командную строку перезапуска с ручным квотированием:
    # кавычки и переводы строк в нём исказили бы её. Это параметр пользователя.
    foreach($v in @($ZapretRoot,$TunnelConfig,$TunnelLink,$TunnelProfile)){
        if($v -and ($v -match '["`r`n]')){
            Write-Host "Недопустимые символы в параметре: $v" -ForegroundColor Red
            exit 1
        }
    }
    $argList=@('-Action',$Action,'-ZapretRoot',('"{0}"' -f $ZapretRoot))
    if($NoAutostart){$argList+='-NoAutostart'}
    if($KeepLogs){$argList+='-KeepLogs'}
    if($IncludeProject){$argList+='-IncludeProject'}
    if($Force){$argList+='-Force'}
    # Новое окно закрылось бы сразу после действия - по этому признаку
    # скрипт в конце ждёт нажатия Enter.
    $argList+='-Elevated'
    if($TunnelConfig){$argList+=@('-TunnelConfig',('"{0}"' -f $TunnelConfig))}
    if($TunnelLink){$argList+=@('-TunnelLink',('"{0}"' -f $TunnelLink))}
    if($Proton){$argList+='-Proton'}
    if($TunnelProfile){$argList+=@('-TunnelProfile',('"{0}"' -f $TunnelProfile))}
    $l=Get-SelfLaunch $argList
    Start-Process -FilePath $l.File -ArgumentList $l.Args -Verb RunAs | Out-Null
    exit
}
function Find-Source {
    if(-not (Test-Path $ZapretRoot)){throw "Не найден исходный релиз zapret2: $ZapretRoot"}
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
      Служба другого приложения (тот же путь за пределами наших каталогов)
      не трогается.
    #>
    $svc=Get-CimInstance Win32_SystemDriver -Filter "Name='WinDivert'" -ErrorAction SilentlyContinue
    if(-not $svc){return}
    $cur=($svc.PathName -replace '^\\\?\?\\','')
    $want=Join-Path $script:TrustedRuntime 'WinDivert64.sys'
    if($cur -ieq $want){return}
    # Трогаем службу только если ImagePath относится к нашим каталогам:
    # иначе это легитимная служба стороннего приложения.
    $ours=@($script:TrustedRuntime,$script:Runtime) |
        ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    if(-not ($ours | Where-Object { $cur -like "$_*" })){
        Write-Host "  Служба WinDivert указывает на чужой каталог, не трогаю:" -ForegroundColor DarkGray
        Write-Host "    $cur" -ForegroundColor DarkGray
        return
    }
    Write-Host "  Перерегистрация драйвера WinDivert:" -ForegroundColor Yellow
    Write-Host "    было:  $cur" -ForegroundColor DarkGray
    Write-Host "    станет: $want" -ForegroundColor DarkGray
    Stop-Zapret -Quiet
    & sc.exe stop WinDivert | Out-Null
    if($LASTEXITCODE -ne 0){
        Write-Host "  Служба WinDivert не остановилась (код $LASTEXITCODE); файл драйвера может не замениться." -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 2
    & sc.exe delete WinDivert | Out-Null
    if($LASTEXITCODE -ne 0){
        Write-Host "  Служба WinDivert не удалена (код $LASTEXITCODE)." -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 2
    Write-Host '    служба удалена; будет создана заново из защищённого каталога при старте.' -ForegroundColor DarkGray
}
function Get-FileSha256 {
    # SHA-256 файла строчными hex-символами.
    param([string]$Path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $fs=[IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-','').ToLowerInvariant() }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}
function Test-FileHash {
    <#
      Сверяет файл с контрольной суммой из $script:Sha256 (ключ - имя файла).
      Если хэш в таблице не задан - открыто предупреждает и пропускает:
      отказ от загрузки целиком хуже честного предупреждения.
    #>
    param([string]$Path)
    $name=Split-Path -Leaf $Path
    if(-not $script:Sha256.ContainsKey($name)){
        Write-Host "    ВНИМАНИЕ: контрольная сумма для $name не задана, сверка пропущена." -ForegroundColor Yellow
        return
    }
    $want=$script:Sha256[$name].ToLowerInvariant()
    $got=Get-FileSha256 $Path
    if($got -ne $want){
        throw ("Контрольная сумма {0} НЕ СОВПАЛА. Скачанный файл может быть подменён.`n  ожидалось: {1}`n  получено:  {2}" -f $name,$want,$got)
    }
}
function Protect-Directory {
    <#
      Явные ACL (F-17): наследование от родителя заменяется на прямые grants.
      По умолчанию Пользователи сохраняют только чтение (нужно, например,
      для меню без прав администратора). -HideFromUsers убирает и чтение -
      для каталога с ключами туннеля (profiles.json и др.).
    #>
    param([string]$Path,[switch]$HideFromUsers)
    if(-not (Test-Path -LiteralPath $Path)){ return }
    # /T: права применяются и к уже существующим дочерним файлам - они могли
    # быть созданы раньше с наследованием от System32.
    $icaclsArgs=@($Path,'/T','/inheritance:r','/grant:r','SYSTEM:(OI)(CI)F','Administrators:(OI)(CI)F')
    # Без /deny: deny для группы Users заблокировал бы и администраторов -
    # они тоже члены Users. Отсутствие grant даёт тот же эффект безопасно.
    if(-not $HideFromUsers){ $icaclsArgs+=@('/grant:r','Users:(OI)(CI)RX') }
    & icacls.exe @icaclsArgs 2>$null | Out-Null
    if($LASTEXITCODE -ne 0){
        Write-Host "    Не удалось задать права на $Path (код $LASTEXITCODE)." -ForegroundColor Yellow
    }
}
function Sync-TrustedScriptCopy {
    <#
      Поддерживает копию скрипта в защищённом каталоге (F-05). Задачи
      планировщика запускают ТОЛЬКО эту копию: файл в рабочей папке может
      подменить любая программа от имени пользователя, а копию в System32 -
      только администратор.
    #>
    if(-not (Test-Path -LiteralPath $script:TrustedRuntime)){ return $null }
    $dst=Join-Path $script:TrustedRuntime $script:SelfName
    $self=if($script:SelfPath){ [IO.Path]::GetFullPath($script:SelfPath) } else { $null }
    if($self -and ($self.TrimEnd('\') -ine ([IO.Path]::GetFullPath($dst).TrimEnd('\')))){
        # Повторы: копию может удерживать запущенная из неё задача.
        for($try=1; $try -le 6; $try++){
            try { Copy-Item -LiteralPath $script:SelfPath -Destination $dst -Force -ErrorAction Stop; break }
            catch {
                if($try -eq 6){
                    Write-Host "    Не удалось обновить копию скрипта в $($script:TrustedRuntime): $($_.Exception.Message)" -ForegroundColor Yellow
                    return $null
                }
                Start-Sleep -Milliseconds 700
            }
        }
    }
    return $dst
}
function Get-TrustedLaunch {
    <#
      Как Get-SelfLaunch, но команда указывает на защищённую копию скрипта
      в System32\Zapret2Windows. Для задач планировщика (F-05).
    #>
    param([string[]]$Arguments=@(),[switch]$Hidden)
    $dst=Sync-TrustedScriptCopy
    if(-not $dst -or -not (Test-Path -LiteralPath $dst)){
        Write-Host '    Защищённая копия скрипта недоступна - задача создана на путь запуска (менее безопасно).' -ForegroundColor Yellow
        return (Get-SelfLaunch $Arguments -Hidden:$Hidden)
    }
    $tail=($Arguments -join ' ')
    if($script:SelfIsCmd){
        return [pscustomobject]@{ File=$env:ComSpec; Args=('/c ""{0}" {1}"' -f $dst,$tail) }
    }
    $hide=$(if($Hidden){'-WindowStyle Hidden '}else{''})
    return [pscustomobject]@{ File=(Join-Path $PSHOME 'powershell.exe')
                              Args=('-NoProfile -ExecutionPolicy Bypass {0}-File "{1}" {2}' -f $hide,$dst,$tail) }
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
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
    } catch {
        throw ("Не удалось скачать релиз. Скачайте вручную и распакуйте в: $ZapretRoot`n" + $_.Exception.Message)
    }
    Test-FileHash $zip
    Write-Host '  Распаковка...' -ForegroundColor Yellow
    Expand-Archive -LiteralPath $zip -DestinationPath $dl -Force
    $dir=Get-ChildItem $dl -Directory -ErrorAction SilentlyContinue |
         Where-Object { Test-Path (Join-Path $_.FullName 'binaries') } | Select-Object -First 1
    if(-not $dir){throw "В архиве не найден каталог с binaries: $zip"}
    if(Test-Path $ZapretRoot){
        # Каталог мог появиться, пока шла загрузка (второй экземпляр, ручная
        # распаковка). Молча удалять его нельзя - там могут быть файлы
        # пользователя.
        if(Test-Path (Join-Path $ZapretRoot 'binaries')){
            Write-Host '  Релиз уже распакован - использую его.' -ForegroundColor Green
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            return
        }
        throw "Каталог $ZapretRoot занят и не похож на релиз zapret2. Удалите его вручную и повторите."
    }
    Move-Item $dir.FullName $ZapretRoot -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Write-Host "  Релиз распакован в: $ZapretRoot" -ForegroundColor Green
}
function Read-TextLinesAuto {
    <#
      Читает текстовый файл, определяя кодировку: BOM (UTF-8/UTF-16) ->
      UTF-8, если байты валидны как UTF-8 -> иначе системная ANSI (cp1251).

      Без этого ReadAllLines в .NET Framework на русской Windows давал для
      ANSI-файла мусор вместо кириллицы: «комментарий» превращался в
      «ÐºÐ¾Ð¼Ð¼ÐµÐ½Ñ‚Ð°Ñ€Ð¸Ð¹», и повторные строки не распознавались как дубликаты.
    #>
    param([string]$Path)
    $bytes=[IO.File]::ReadAllBytes($Path)
    if($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF){
        $enc=[Text.UTF8Encoding]::new($true)
    } elseif($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE){
        $enc=[Text.Encoding]::Unicode
    } elseif($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF){
        $enc=[Text.Encoding]::BigEndianUnicode
    } else {
        $enc=[Text.UTF8Encoding]::new($false)
        try { [void]$enc.GetString($bytes) }
        catch { $enc=[Text.Encoding]::Default }   # не UTF-8 -> системная ANSI
    }
    # Разбор строк вручную: ReadAllLines не принимает готовую кодировку
    # вместе с проверкой валидности UTF-8.
    $text=$enc.GetString($bytes)
    if($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF){ $text=$text.Substring(1) }
    if($text.Length -eq 0){ return @() }
    $raw=@($text -split "`r`n|`n")
    # Хвостовой перевод строки не даёт пустого элемента.
    if($raw.Count -gt 0 -and $raw[$raw.Count-1] -eq ''){ $raw=@($raw | Select-Object -First ($raw.Count-1)) }
    return $raw
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
        foreach($l in (Read-TextLinesAuto $Path)){ $lines.Add($l); [void]$have.Add($l.Trim()) }
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
    # Автозапуск включаем только при первой установке: при обновлении среды
    # выключенный пользователем автозапуск не должен включаться снова.
    $firstInstall=-not (Test-Path (Join-Path $script:TrustedRuntime 'winws2.exe'))
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
    Remove-LegacyWarp
    $null=Merge-ListFile (Join-Path $lists 'tunnel.txt') $script:SeedTunnel
    $null=Merge-ListFile (Join-Path $lists 'tunnel-geo.txt') $script:SeedGeo
    $n=Merge-ListFile (Join-Path $lists 'ipset-hosting.txt') $script:SeedHostingIpset
    if($n){Write-Host "  Добавлено подсетей хостингов: $n" -ForegroundColor DarkGray}
    $auto=Join-Path $lists 'autohostlist.txt'
    if(-not (Test-Path $auto)){[IO.File]::WriteAllText($auto,'',[Text.UTF8Encoding]::new($false))}

    # Явные права вместо наследования (F-17): боевое содержимое - чтение
    # для Пользователей, запись только SYSTEM/Администраторы.
    Protect-Directory $script:TrustedRuntime

    Write-LaunchConfig
    Fix-DriverService
    # Задачи планировщика запускают защищённую копию скрипта (F-05):
    # поддерживаем её в актуальном состоянии уже при установке.
    [void](Sync-TrustedScriptCopy)
    # Проверка DNS (DoH) выполняется при первом запуске обхода, а не здесь:
    # без обхода нельзя отличить подмену DNS от блокировки DPI, и проверка
    # каждого домена упиралась в таймауты (установка шла минутами).
    if(-not $NoAutostart -and $firstInstall){Install-Autostart}
    Write-Host "Среда установлена ($($script:Arch))" -ForegroundColor Green
    Write-Host "Боевой каталог: $script:TrustedRuntime" -ForegroundColor DarkGray
    Write-Host 'Права: Администраторы/SYSTEM — полный доступ, Пользователи — только чтение.' -ForegroundColor DarkGray
}
function Get-CircularResetFlag { Join-Path $script:TrustedRuntime 'circular-reset.off' }
function Test-CircularReset {
    # Обрыв зависших соединений при подборе стратегии (по умолчанию включён).
    -not (Test-Path -LiteralPath (Get-CircularResetFlag))
}
function Toggle-CircularReset {
    Ensure-Admin
    if(-not (Test-Path (Join-Path $script:TrustedRuntime 'winws2.exe'))){
        throw 'Среда не установлена - сначала выполните установку (пункт 1).'
    }
    $f=Get-CircularResetFlag
    if(Test-CircularReset){
        [IO.File]::WriteAllText($f,'off',[Text.Encoding]::ASCII)
        Write-Host '  Обрыв зависших соединений при подборе стратегии выключен.' -ForegroundColor Yellow
    } else {
        Remove-Item -LiteralPath $f -Force
        Write-Host '  Обрыв зависших соединений при подборе стратегии включён.' -ForegroundColor Green
    }
    Write-Host '  Соединение, на котором стратегия не сработала, сразу обрывается, и программа' -ForegroundColor DarkGray
    Write-Host '  переподключается со следующей стратегией, а не ждёт таймаутов (видео не зависает).' -ForegroundColor DarkGray
    Write-LaunchConfig
    if((Get-Status).Running){
        Write-Host '  Перезапуск обхода...' -ForegroundColor DarkGray
        Start-Zapret
    }
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
    # Домены, переведённые в туннель, zapret не трогает: их трафик идёт на сервер.
    $warpList=Join-Path $lists 'tunnel.txt'
    if(-not (Test-Path -LiteralPath $warpList)){ $null=Merge-ListFile $warpList $script:SeedTunnel }
    # Соединение с самим сервером туннеля zapret тоже не трогает.
    $tunnelServers=Join-Path $lists 'ipset-tunnel-servers.txt'
    # Туда же входит диапазон FakeIP: трафик, идущий в туннель, zapret не трогает.
    # Домены из списка туннеля по имени НЕ исключаются: если браузер обошёл DNS
    # туннеля (свой DNS через HTTPS, старый адрес в памяти) и пошёл на сайт
    # напрямую, zapret остаётся запасным путём, как до переноса.
    $null=Merge-ListFile $tunnelServers $script:TunnelIpsetHeader
    $srvEx=@("--ipset-exclude=$tunnelServers")
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
      "--hostlist=$blocked","--hostlist-auto=$auto","--hostlist-exclude=$exclude",
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
        "--hostlist-exclude=$exclude","--hostlist-exclude=$blocked","--hostlist-exclude=$auto",
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
      "--hostlist=$blocked","--hostlist-auto=$auto","--hostlist-exclude=$exclude",
      '--out-range=-d10',
      # reset: соединение, на котором обнаружен сбой, сразу обрывается, и
      # программа переподключается, а не ждёт таймаутов TCP (иначе видео
      # YouTube и подобное надолго зависают, пока подбирается стратегия).
      '--in-range=-s5556',$(if(Test-CircularReset){'--lua-desync=circular:fails=2:retrans=2:nld=2:reset'}else{'--lua-desync=circular:fails=2:retrans=2:nld=2'}),
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
      "--hostlist=$blocked","--hostlist=$auto","--hostlist-exclude=$exclude",
      '--payload=quic_initial','--lua-desync=fake:blob=fake_default_quic:repeats=6',

      # [5] Голос/медиа Discord: IP-discovery (STUN-подобный) и STUN/WireGuard.
      # Официальная схема zapret2 (init.d/custom.d.examples.*/50-discord-media,
      # 50-stun4all, 50-wg4all): fake с нулевым блобом, repeats=2.
      # Фильтровать по hostlist здесь нельзя - в UDP-медиа нет SNI.
      '--new','--filter-l7=stun,discord,wireguard',
      '--payload=stun,discord_ip_discovery,wireguard_initiation,wireguard_cookie',
      '--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2'
    )
    # Исключение адресов туннеля - в каждый профиль TCP и QUIC (перед его --new).
    if($srvEx.Count){
        $fixed=New-Object System.Collections.Generic.List[string]
        $tcp=$false
        foreach($a in $wsArgs){
            if($a -eq '--new'){ if($tcp){ $fixed.Add($srvEx[0]) }; $tcp=$false }
            elseif($a -like '--filter-tcp=*' -or $a -eq '--filter-udp=443'){ $tcp=$true }
            $fixed.Add($a)
        }
        if($tcp){ $fixed.Add($srvEx[0]) }
        $wsArgs=$fixed.ToArray()
    }
    [IO.File]::WriteAllLines($cfg,$wsArgs,[Text.UTF8Encoding]::new($false))
}
function Start-Zapret {
    Ensure-Admin
    if(-not (Test-Path (Join-Path $script:TrustedRuntime 'winws2.exe'))){Install-Runtime}
    Stop-Zapret -Quiet
    if(-not (Test-Path (Join-Path $script:TrustedRuntime 'winws2.exe'))){Install-Runtime}
    # Параметры запуска - по текущей версии скрипта и настройкам меню (после
    # обновления скрипта не нужно помнить про пункт [1]).
    Write-LaunchConfig
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
    # Первичная проверка DNS - один раз, когда обход уже работает.
    $dohDone=Join-Path $script:TrustedRuntime 'lists\doh.done'
    if(-not (Test-Path -LiteralPath $dohDone)){
        Write-Host 'Первичная проверка DNS (один раз, до минуты)...' -ForegroundColor DarkGray
        try {
            Update-DohHosts -Quiet
            [IO.File]::WriteAllText($dohDone,(Get-Date).ToString('s'),[Text.Encoding]::ASCII)
        } catch { Write-Host ('  Проверка DNS не выполнена: ' + $_.Exception.Message) -ForegroundColor Yellow }
    }
    if((Get-TunnelStatus).Enabled){ Start-TunnelBackground }
}
function Stop-Zapret {
    param([switch]$Quiet)
    Stop-Tunnel -Quiet
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
        $procs=@(Get-ProcessByExe 'winws2' $exe)
        if(-not $procs.Count){break}
        $procs | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 400
    }
    if(-not $Quiet){Write-Host 'winws2 остановлен.' -ForegroundColor Yellow}
}
function Get-Status {
    $p=@(Get-ProcessByExe 'winws2' (Join-Path $script:TrustedRuntime 'winws2.exe')) | Select-Object -First 1
    [pscustomobject]@{
        Running=[bool]$p; Pid=if($p){$p.Id}else{$null};
        Runtime=(Test-Path (Join-Path $script:TrustedRuntime 'winws2.exe'));
        AutoStart=(Test-AutostartTask);
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
    return ([Environment]::OSVersion.Version.Build -ge 17763)
}

function Get-DependencyReport {
    <#
      Возвращает список проверок. Каждый элемент:
        Name, Detail, Status (OK/FAIL/WARN), Required, Fixable
    #>
    $r=New-Object System.Collections.Generic.List[object]
    # Сведения о системе - из реестра и .NET: запрос WMI занимал до секунды
    # при каждом открытии меню.
    $build=[Environment]::OSVersion.Version.Build
    $osName=''
    try { $osName="$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ProductName -ErrorAction Stop).ProductName)" } catch {}
    if($build -ge 22000){ $osName=($osName -replace 'Windows 10','Windows 11') }   # в реестре Windows 11 записана как 10

    $r.Add([pscustomobject]@{
        Name='Windows 10/11'; Required=$true; Fixable=$false
        Status=$(if($build -ge 10240){'OK'}else{'FAIL'})
        Detail=$(if($osName){"$osName (build $build)"}else{"build $build"})
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
    # stderr внешних программ при 'Stop' в PS 5.1 превращается в исключение.
    $ErrorActionPreference='Continue'
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
    # Установщик .NET подписан Microsoft: проверяем подпись, а не только HTTPS.
    $sig=Get-AuthenticodeSignature $exe
    if($sig.Status -ne 'Valid' -or -not ($sig.SignerCertificate.Subject -match 'Microsoft')){
        Write-Host '    Подпись установщика не прошла проверку - загрузка отменена.' -ForegroundColor Red
        Remove-Item $exe -Force -ErrorAction SilentlyContinue
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
    $ErrorActionPreference='Continue'
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
            Write-Host ("  Часть проблем исправляется автоматически (пункт [6]): $fixable") -ForegroundColor Yellow
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
    # Команда ссылается на защищённую копию скрипта в System32 (F-05):
    # файл в рабочей папке может быть подменён любой программой пользователя.
    $l=Get-TrustedLaunch @('-Action','Start','-NoAutostart') -Hidden
    $act=New-ScheduledTaskAction -Execute $l.File -Argument $l.Args
    $trg=New-ScheduledTaskTrigger -AtLogOn
    $pr=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # По умолчанию планировщик не запускает задачи при работе от батареи и
    # снимает их через 3 дня - на ноутбуке автозапуск не срабатывал бы.
    $set=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $script:TaskName -Action $act -Trigger $trg -Principal $pr -Settings $set -Force | Out-Null
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
            # Прямой вызов без cmd.exe /c: домены фиксированные, но так
            # паттерн не зависит от экранирования и быстрее.
            $ErrorActionPreference='Continue'
            $r = & curl.exe -sS -o NUL -L --max-time 8 -A 'Mozilla/5.0' -w '%{http_code}' ("https://{0}/" -f $d) 2>$null
            $ErrorActionPreference='Stop'
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
        $url="https://raw.githubusercontent.com/$($script:UpdateRepo)/$b/$($script:SelfName)"
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
            if($text -notmatch 'param\s*\(' -or $text -notmatch 'Zapret2Windows' -or ($script:SelfIsCmd -and $text -notmatch '^<\# :')){
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

    $self=$script:SelfPath
    if(-not $self -or -not (Test-Path -LiteralPath $self)){ throw "Не найден файл скрипта: $self" }

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

    # Синтаксис нового текста проверяем ДО того, как тронем рабочий файл.
    $parseErrors=$null
    $parseTokens=$null
    $newText=$remote.Text
    if($script:SelfIsCmd){ $newText=(($newText -replace "`r`n","`n") -replace "`n","`r`n") }
    [void][System.Management.Automation.Language.Parser]::ParseInput($newText,[ref]$parseTokens,[ref]$parseErrors)
    if($parseErrors.Count){
        throw ("Скачанный скрипт содержит синтаксические ошибки, обновление отменено:`n  " + $parseErrors[0].Message)
    }

    # Резервная копия с отметкой времени
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak="$self.$stamp.bak"
    Copy-Item -LiteralPath $self -Destination $bak -Force
    Write-Host ("    Резервная копия: " + (Split-Path -Leaf $bak)) -ForegroundColor DarkGray

    # .ps1 - с UTF-8 BOM (иначе PowerShell 5.1 сломает кириллицу); .cmd - без
    # BOM (иначе cmd.exe споткнётся на первой строке) и с переводами строк CRLF.
    try {
        # Атомарная подмена: сначала пишем во временный файл рядом, затем
        # Replace. Падение процесса не оставит полузаписанный скрипт.
        $tmp="$self.new"
        [IO.File]::WriteAllText($tmp,$newText,(New-Object Text.UTF8Encoding (-not $script:SelfIsCmd)))
        try { [IO.File]::Replace($tmp,$self,$null) }
        catch { Move-Item -LiteralPath $tmp -Destination $self -Force }  # FAT и пр.: без Replace
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    } catch {
        Copy-Item -LiteralPath $bak -Destination $self -Force
        throw ("Не удалось записать обновление, восстановлена резервная копия.`n  " + $_.Exception.Message)
    }

    Write-Host ''
    Write-Host '    Скрипт обновлён.' -ForegroundColor Green
    Write-Host ("    Было: " + $script:ScriptVersion + " -> Стало: " + $(if($remoteVer){$remoteVer}else{'обновлённая версия'})) -ForegroundColor Green
    Write-Host ("    Резервная копия: " + $bak) -ForegroundColor DarkGray
    # Защищённая копия для задач планировщика (F-05) - тоже обновляется.
    if(Test-Path -LiteralPath $script:TrustedRuntime){ [void](Sync-TrustedScriptCopy) }
    Write-Host ''
    Write-Host '    Текущий процесс работает со старой версией в памяти.' -ForegroundColor Yellow
    if(-not $Force){
        $a=Read-Host '    Перезапустить скрипт сейчас? (y/N)'
        if($a -match '^\s*[yYдД]'){
            $l=Get-SelfLaunch @('-ZapretRoot',('"{0}"' -f $ZapretRoot))
            Start-Process -FilePath $l.File -ArgumentList $l.Args -Verb RunAs
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
    $on=Test-AutostartTask
    if($on){
        Remove-Autostart
        Write-Host '  Автозапуск при входе выключен.' -ForegroundColor Yellow
    } else {
        Install-Autostart
        Write-Host '  Автозапуск при входе включён.' -ForegroundColor Green
        if((Get-TunnelStatus).Enabled){ Write-Host '  Туннель будет запускаться вместе с обходом.' -ForegroundColor Green }
    }
}

# ============================================================================
#  Туннель через sing-box: внешний выход для сайтов, с которыми не
#  справляется zapret (блокировка по IP, запрет самого сервиса для России).
#
#  Выход - Proton VPN Free (конфиг WireGuard) или свой сервер (WireGuard,
#  VLESS, VMess, Trojan, Shadowsocks, Hysteria2, TUIC, SOCKS, JSON sing-box,
#  ссылки и подписки).
#
#  Схема (скорость остального трафика не страдает):
#    * sing-box поднимает TUN, но маршрутизирует в него ТОЛЬКО диапазон FakeIP
#      и подсети Telegram (приложение ходит к серверам по IP, без DNS).
#      Весь прочий трафик идёт мимо sing-box, напрямую, через zapret.
#    * DNS-запросы доменов из lists\tunnel.txt Windows отправляет в sing-box
#      (правило NRPT): они получают FakeIP и попадают в туннель. Остальной
#      DNS не меняется.
#    * Настоящий адрес такого домена ищется через сам туннель.
#    * zapret эти домены и сам сервер туннеля не трогает.
# ============================================================================

$script:SingBoxVersion='1.14.4'
$script:TunnelMixedPort=40480    # локальный прокси sing-box для проверок
$script:TunnelProbePort=40481    # порт для пробного запуска профиля
$script:TunnelIf='Zapret2Tunnel'
# Свои адреса и диапазон FakeIP - намеренно НЕ значения sing-box по
# умолчанию: их используют другие клиенты на sing-box в режиме TUN
# (Throne, Hiddify, NekoBox...), при одновременной работе был бы конфликт.
$script:TunnelAddr4='172.31.251.1/30'
$script:TunnelDns4='172.31.251.2'
$script:TunnelAddr6='fd7a:7a70:7761::1/126'
$script:TunnelFake4='10.249.0.0/16'
$script:TunnelFake4Prefix='10.249.'
$script:TunnelFake6='fd7a:7a70:fa4e::/64'
$script:TunnelNrptComment='Zapret2Tunnel'
# Подсети Telegram (https://core.telegram.org/resources/cidr.txt). Приложение
# Telegram подключается к серверам по IP, без DNS и без TLS-имени, поэтому
# ни FakeIP, ни профили zapret его не ловят. Эти подсети всегда идут в туннель.
$script:TelegramCidr4=@(
    '91.108.56.0/22','91.108.4.0/22','91.108.8.0/22','91.108.16.0/22',
    '91.108.12.0/22','149.154.160.0/20','91.105.192.0/23','91.108.20.0/22',
    '185.76.151.0/24'
)
$script:TelegramCidr6=@(
    '2001:b28:f23d::/48','2001:b28:f23f::/48','2001:67c:4e8::/48',
    '2001:b28:f23c::/48','2a0a:f280::/32'
)
# Медиасерверы Discord в сети Cloudflare (трансляции, всё больше и голос).
# Discord шлёт на них UDP по адресу из сигнального соединения, без DNS, поэтому
# список доменов туннеля их не касается. У части провайдеров UDP к ним обрезается
# через ~1 с после начала соединения, и zapret это не исправляет: тогда (по
# итогам проверки) в туннель направляется UDP к этим адресам, TCP идёт напрямую.
$script:DiscordMediaCidr4=@('104.29.0.0/16')
# Серверы для проверки: отвечают на пакет определения IP без входа в аккаунт.
$script:DiscordProbeServers=@(@('104.29.149.69',19298),@('104.29.155.188',19298))
$script:TunnelIpsetHeader=@(
    '# Адреса, которые zapret не трогает: трафик в туннель (FakeIP, Telegram) и серверы туннеля.',
    '# Файл создаётся автоматически.',
    $script:TunnelFake4,
    $script:TunnelFake6
)+$script:TelegramCidr4+$script:TelegramCidr6
# Firefox спрашивает этот домен у системного DNS; ответ "нет такого домена"
# выключает его встроенный DNS через HTTPS (если тот включён по умолчанию, а
# не вручную). Иначе Firefox узнаёт адреса сайтов мимо туннеля.
$script:DohCanary='use-application-dns.net'
$script:SupportedFormats='конфиг WireGuard (.conf); ссылки vless://, vmess://, trojan://, ss://, hysteria2:// (hy2://), hysteria://, tuic://, anytls://, socks5://, wireguard://; несколько ссылок или подписка (адрес https://... либо base64); JSON sing-box (outbound или целый конфиг); JSON Xray (outbound или целый конфиг). Транспорт XHTTP и конфиги Xray работают через xray-core, остальное - через sing-box'
# xray-core: только для профилей, которые sing-box не умеет (транспорт XHTTP,
# конфиги Xray). Работает локальным прокси, в который sing-box отправляет трафик.
$script:XrayPort=40482
$script:XrayProbePort=40483
# Сайты, по которым проверяется, пускает ли сервис с адреса профиля.
$script:SeedGeo=@(
    '# Сайты с региональными ограничениями: по ним выбирается профиль туннеля.',
    '# По домену в строке. Профиль, с которого открывается больше сайтов, - лучший.',
    'claude.ai',
    'chatgpt.com',
    'gemini.google.com'
)
# Признаки отказа по региону: в адресе перенаправления или в тексте страницы.
$script:GeoRegex='(?i)app-unavailable-in-region|unavailable[-_ ]in[-_ ](your[-_ ])?(region|country)|unsupported[-_ ](country|region)|country[-_ ]not[-_ ]supported|not[-_ ](available|supported)[-_ ]in[-_ ]your[-_ ](country|region|location)|region[-_ ](restricted|blocked)|geo[-_ ]?(block|restrict)|недоступ\w+ в ваш\w+ (стране|регионе)'
$script:GeoLabel=@{ ok='открывается'; challenge='отвечает (проверка браузера)'; geo='отказ по региону'; deny='отказ (403)'; fail='нет ответа' }
# Внешний список сайтов, которые сами не пускают из России (claude.ai,
# chatgpt.com...). "Обучением" их не найти: соединение проходит, отказ приходит
# уже от сайта. Список ведёт сообщество (itdoginfo/allow-domains, раздел
# GeoBlock). При включённом туннеле он скачивается, добавляется к списку
# туннеля и обновляется раз в сутки. Свой список туннеля при этом не меняется.
$script:GeoListUrl='https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Categories/geoblock.lst'
$script:GeoListTask='Zapret2WindowsGeoList'
$script:TunnelDomainsMax=1000
$script:TunnelTraceLast=''       # чем закончилась последняя проверка туннеля
$script:TunnelExit=@{}           # откуда туннель выходит в интернет: loc, ip

function Get-TunnelPaths {
    $d=Join-Path $script:TrustedRuntime 'tunnel'
    [pscustomobject]@{
        Dir=$d
        Exe=Join-Path $d 'sing-box.exe'
        Xray=Join-Path $d 'xray.exe'
        XrayConfig=Join-Path $d 'xray.json'
        XrayProbe=Join-Path $d 'probe-xray.json'
        XrayLog=Join-Path $script:TrustedRuntime 'logs\xray.log'
        XrayProbeLog=Join-Path $script:TrustedRuntime 'logs\xray-probe.log'
        Geo=Join-Path $script:TrustedRuntime 'lists\tunnel-geo.txt'
        Profiles=Join-Path $d 'profiles.json'
        State=Join-Path $d 'state.json'
        ExitInfo=Join-Path $d 'exit.json'
        Config=Join-Path $d 'config.json'
        Probe=Join-Path $d 'probe.json'
        Validate=Join-Path $d 'validate.json'
        Rules=Join-Path $d 'rules.json'
        Cache=Join-Path $d 'cache.db'
        Pid=Join-Path $d 'sing-box.pid'
        StarterPid=Join-Path $d 'starting.pid'
        Enabled=Join-Path $d 'enabled'
        LastError=Join-Path $d 'last-error.txt'
        Log=Join-Path $script:TrustedRuntime 'logs\sing-box.log'
        ErrLog=Join-Path $script:TrustedRuntime 'logs\sing-box-stderr.log'
        ProbeLog=Join-Path $script:TrustedRuntime 'logs\sing-box-probe.log'
        StartLog=Join-Path $script:TrustedRuntime 'logs\tunnel-start.log'
        List=Join-Path $script:TrustedRuntime 'lists\tunnel.txt'
        Servers=Join-Path $script:TrustedRuntime 'lists\ipset-tunnel-servers.txt'
        GeoList=Join-Path $script:TrustedRuntime 'lists\tunnel-geoblock.txt'
        GeoListOff=Join-Path $d 'geolist.off'
        DiscordMedia=Join-Path $d 'discord-media.on'
    }
}

function Initialize-TunnelDirs {
    # Туннель можно настроить и до установки среды zapret (пункт [1]):
    # каталоги для профилей, списков и журналов создаём сами.
    $p=Get-TunnelPaths
    foreach($d in @($p.Dir,(Join-Path $script:TrustedRuntime 'lists'),(Join-Path $script:TrustedRuntime 'logs'))){
        if(-not (Test-Path -LiteralPath $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    # В tunnel лежат profiles.json с закрытыми ключами и паролями - Пользователям
    # читать нельзя (F-17). Вызывается только с правами администратора.
    Protect-Directory $p.Dir -HideFromUsers
}

function Test-Ipv6Available {
    # Если IPv6 в системе выключен, sing-box не сможет назначить TUN v6-адрес.
    try { return [bool][Net.Sockets.Socket]::OSSupportsIPv6 } catch { return $false }
}

function Write-JsonFile {
    param([string]$Path,$Object)
    # -InputObject, а не конвейер: иначе массив из одного элемента стал бы объектом.
    $json=ConvertTo-Json -InputObject $Object -Depth 30
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
    # Обычный цикл вместо конвейера: списки читаются при каждой отрисовке
    # меню, а внешний список - это сотни строк.
    $seen=New-Object 'System.Collections.Generic.HashSet[string]'
    $out=New-Object System.Collections.Generic.List[string]
    try {
        foreach($l in [IO.File]::ReadAllLines($Path)){
            $x=$l.Trim().ToLowerInvariant()
            if($x -and -not $x.StartsWith('#') -and $seen.Add($x)){ $out.Add($x) }
        }
    } catch {}
    return $out.ToArray()
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

function Set-TunnelError {
    # Запоминает причину сбоя: её видно в меню туннеля, а не только в момент запуска.
    param([string]$Message,[string[]]$Details=@())
    $p=Get-TunnelPaths
    Write-Host "  $Message" -ForegroundColor Red
    foreach($l in $Details){ Write-Host "    $l" -ForegroundColor DarkGray }
    try {
        New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null
        [IO.File]::WriteAllLines($p.LastError,@("$((Get-Date).ToString('s')) $Message")+$Details,[Text.UTF8Encoding]::new($false))
    } catch {}
}

function Clear-TunnelError {
    Remove-Item (Get-TunnelPaths).LastError -Force -ErrorAction SilentlyContinue
}

function Remove-LegacyWarp {
    # Убирает следы прежней реализации (WARP): процессы, каталог, список.
    $old=Join-Path $script:TrustedRuntime 'warp'
    $p=Get-TunnelPaths
    if(Test-Path $old){
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($old,[StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 500
        New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null
        # sing-box и его библиотеки переносим, чтобы не скачивать заново.
        Get-ChildItem -Path $old -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'sing-box.exe' -or $_.Extension -eq '.dll' } |
            ForEach-Object { if(-not (Test-Path (Join-Path $p.Dir $_.Name))){ Move-Item $_.FullName $p.Dir -Force -ErrorAction SilentlyContinue } }
        Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue
    }
    $oldList=Join-Path $script:TrustedRuntime 'lists\warp.txt'
    if(Test-Path $oldList){
        # Сайты из списка WARP переходят в список туннеля.
        $null=Merge-ListFile $p.List @(Get-Content -LiteralPath $oldList)
        Remove-Item $oldList -Force -ErrorAction SilentlyContinue
    }
}

function Install-SingBox {
    # Скачивает официальную сборку sing-box с GitHub (один раз).
    # stderr внешних программ при 'Stop' в PS 5.1 превращается в исключение.
    $ErrorActionPreference='Continue'
    $p=Get-TunnelPaths
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
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
        Test-FileHash $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $inner=Join-Path $tmp $name
        if(-not (Test-Path (Join-Path $inner 'sing-box.exe'))){ throw "В архиве нет sing-box.exe: $url" }
        Stop-Tunnel -Quiet
        # Копируем только ожидаемые имена: в каталоге не должно оказаться
        # лишних исполняемых файлов из архива.
        Copy-Item (Join-Path $inner 'sing-box.exe') $p.Dir -Force
        Get-ChildItem $inner -Filter '*.dll' -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName $p.Dir -Force }
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "  sing-box установлен: $($p.Exe)" -ForegroundColor Green
}

function Install-Xray {
    # Скачивает официальную сборку xray-core с GitHub (один раз).
    $ErrorActionPreference='Continue'
    $p=Get-TunnelPaths
    if(Test-Path $p.Xray){ return }
    New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null
    $arch=$env:PROCESSOR_ARCHITEW6432; if(-not $arch){ $arch=$env:PROCESSOR_ARCHITECTURE }
    $xa=switch($arch){ 'AMD64' {'64'} 'ARM64' {'arm64-v8a'} 'x86' {'32'} default {'64'} }
    $zipName="Xray-windows-$xa.zip"
    $url="https://github.com/XTLS/Xray-core/releases/download/$($script:XrayVersion)/$zipName"
    $tmp=Join-Path $env:TEMP ("xray-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Write-Host "  Скачивание xray-core $($script:XrayVersion) (нужен для профилей с XHTTP и конфигов Xray)..." -ForegroundColor Yellow
        Write-Host "    $url" -ForegroundColor DarkGray
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $zip=Join-Path $tmp 'xray.zip'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
        Test-FileHash $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        if(-not (Test-Path (Join-Path $tmp 'xray.exe'))){ throw "В архиве нет xray.exe: $url" }
        Copy-Item (Join-Path $tmp 'xray.exe') $p.Xray -Force
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "  xray-core установлен: $($p.Xray)" -ForegroundColor Green
}

function Copy-ToOrdered {
    # Копия объекта (словарь или объект из JSON) в упорядоченный словарь.
    param($Object)
    $o=[ordered]@{}
    if($Object -is [System.Collections.IDictionary]){ foreach($k in @($Object.Keys)){ $o[$k]=$Object[$k] } }
    elseif($Object){ foreach($prop in $Object.PSObject.Properties){ $o[$prop.Name]=$prop.Value } }
    return $o
}

# --- разбор конфигов и ссылок -------------------------------------------------
#
# Профиль: name, source ('proton' | 'custom'), type, endpoint ($true для
# WireGuard), outbound (объект sing-box без tag).
# Профиль для xray-core дополнительно: engine='xray', xray (outbound Xray),
# server (хост, порт); его outbound - SOCKS на локальный xray.

function ConvertFrom-AnyBase64 {
    # Base64 в любом варианте (обычный/URL-safe, с выравниванием и без).
    param([string]$Text)
    $s=($Text -replace '\s','').Replace('-','+').Replace('_','/')
    $s+=('=' * ((4 - $s.Length % 4) % 4))
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}

function Test-IpLiteral {
    param([string]$HostName)
    $ip=$null
    return [Net.IPAddress]::TryParse($HostName,[ref]$ip)
}

function Test-Truthy { param($v) return (@('1','true','yes') -contains "$v".ToLowerInvariant()) }

function Split-ServerLink {
    # scheme://userinfo@host:port?query#name -> объект с полями.
    param([string]$Link)
    $u=[uri]$Link.Trim()
    $q=@{}
    foreach($pair in $u.Query.TrimStart('?') -split '&'){
        if(-not $pair){ continue }
        $kv=$pair -split '=',2
        $k=[uri]::UnescapeDataString($kv[0])
        if(-not $q.ContainsKey($k)){ $q[$k]=if($kv.Count -gt 1){ [uri]::UnescapeDataString($kv[1].Replace('+',' ')) } else { '' } }
    }
    $user=''; $pass=''
    if($u.UserInfo){
        $ui=$u.UserInfo -split ':',2
        $user=[uri]::UnescapeDataString($ui[0])
        if($ui.Count -gt 1){ $pass=[uri]::UnescapeDataString($ui[1]) }
    }
    [pscustomobject]@{
        Scheme=$u.Scheme.ToLowerInvariant(); User=$user; Pass=$pass
        Host=$u.DnsSafeHost; Port=$(if($u.Port -gt 0){ $u.Port } else { 0 })
        Q=$q; Name=[uri]::UnescapeDataString($u.Fragment.TrimStart('#'))
    }
}

function Assert-Server {
    param($L)
    if(-not $L.Host -or -not $L.Port){ throw 'в ссылке нет адреса сервера или порта' }
}

function New-TlsBlock {
    # Блок tls для sing-box из параметров ссылки (security, sni, fp, pbk...).
    param($Q,[string]$HostName,[switch]$Force)
    $sec="$($Q['security'])".ToLowerInvariant()
    if(-not $Force -and (@('tls','reality','xtls') -notcontains $sec)){ return $null }
    $tls=[ordered]@{ enabled=$true }
    $sni=$Q['sni']; if(-not $sni){ $sni=$Q['peer'] }; if(-not $sni){ $sni=$Q['servername'] }
    if(-not $sni -and -not (Test-IpLiteral $HostName)){ $sni=$HostName }
    if($sni){ $tls.server_name=$sni }
    if((Test-Truthy $Q['allowInsecure']) -or (Test-Truthy $Q['insecure']) -or (Test-Truthy $Q['allow_insecure'])){ $tls.insecure=$true }
    if($Q['alpn']){ $tls.alpn=@($Q['alpn'] -split ',' | Where-Object { $_ }) }
    $fp=$Q['fp']; if(-not $fp){ $fp=$Q['fingerprint'] }
    if($sec -eq 'reality'){
        if(-not $Q['pbk']){ throw 'в ссылке Reality нет открытого ключа (pbk)' }
        $tls.reality=[ordered]@{ enabled=$true; public_key=$Q['pbk']; short_id="$($Q['sid'])" }
        if(-not $fp){ $fp='chrome' }    # Reality требует uTLS
    }
    if($fp){ $tls.utls=[ordered]@{ enabled=$true; fingerprint=$fp } }
    return $tls
}

function New-TransportBlock {
    # Блок transport для sing-box (ws, grpc, http, httpupgrade).
    param($Q)
    $net="$($Q['type'])".ToLowerInvariant(); if(-not $net){ $net="$($Q['net'])".ToLowerInvariant() }
    if(-not $net){ $net='tcp' }
    $h="$($Q['host'])"; $path="$($Q['path'])"
    switch($net){
        { $_ -in @('tcp','raw') } {
            if("$($Q['headerType'])".ToLowerInvariant() -eq 'http'){
                $tr=[ordered]@{ type='http'; path=$(if($path){$path}else{'/'}) }
                if($h){ $tr.host=@($h -split ',') }
                return $tr
            }
            return $null
        }
        'ws' {
            $tr=[ordered]@{ type='ws'; path=$(if($path){$path}else{'/'}) }
            if($tr.path -match '[?&]ed=(\d+)'){   # раннее отправление данных, запись Xray "?ed=2048"
                $ed=[int]$Matches[1]
                $tr.path=($tr.path -replace '[?&]ed=\d+',''); if(-not $tr.path){ $tr.path='/' }
                $tr.max_early_data=$ed; $tr.early_data_header_name='Sec-WebSocket-Protocol'
            }
            if($h){ $tr.headers=[ordered]@{ Host=$h } }
            return $tr
        }
        'grpc' {
            $svc=$Q['serviceName']; if(-not $svc){ $svc=$Q['servicename'] }; if(-not $svc){ $svc=$path }
            return [ordered]@{ type='grpc'; service_name="$svc" }
        }
        { $_ -in @('http','h2') } {
            $tr=[ordered]@{ type='http'; path=$(if($path){$path}else{'/'}) }
            if($h){ $tr.host=@($h -split ',') }
            return $tr
        }
        'httpupgrade' {
            $tr=[ordered]@{ type='httpupgrade'; path=$(if($path){$path}else{'/'}) }
            if($h){ $tr.host=$h }
            return $tr
        }
        default { throw "транспорт '$net' не поддерживается sing-box" }
    }
}

function Test-XhttpQuery {
    param($Q)
    $net="$($Q['type'])".ToLowerInvariant(); if(-not $net){ $net="$($Q['net'])".ToLowerInvariant() }
    return ($net -eq 'xhttp' -or $net -eq 'splithttp')
}

function New-XrayLinkOutbound {
    # Профиль для xray-core из ссылки vless/vmess/trojan с транспортом XHTTP.
    param([string]$Proto,[string]$HostName,[int]$Port,$Q,[string]$Uuid='',[string]$Password='',[string]$Security='auto',[int]$AlterId=0)
    $sec="$($Q['security'])".ToLowerInvariant()
    if(-not $sec){ $sec=$(if($Proto -eq 'trojan'){'tls'}else{'none'}) }
    $sni=$Q['sni']; if(-not $sni){ $sni=$Q['peer'] }
    if(-not $sni -and -not (Test-IpLiteral $HostName)){ $sni=$HostName }
    $fp=$Q['fp']; if(-not $fp){ $fp=$Q['fingerprint'] }
    $xh=[ordered]@{ path=$(if($Q['path']){"$($Q['path'])"}else{'/'}) }
    if($Q['host']){ $xh.host="$($Q['host'])" }
    if($Q['mode']){ $xh.mode="$($Q['mode'])" }
    if($Q['extra']){
        try { $xh.extra=("$($Q['extra'])" | ConvertFrom-Json) } catch { throw 'параметр extra в ссылке XHTTP - не JSON' }
    }
    $ss=[ordered]@{ network='xhttp'; xhttpSettings=$xh }
    if($sec -eq 'reality'){
        if(-not $Q['pbk']){ throw 'в ссылке Reality нет открытого ключа (pbk)' }
        $ss.security='reality'
        $ss.realitySettings=[ordered]@{ serverName="$sni"; fingerprint=$(if($fp){"$fp"}else{'chrome'}); publicKey="$($Q['pbk'])"; shortId="$($Q['sid'])"; spiderX="$($Q['spx'])" }
    } elseif($sec -eq 'tls' -or $sec -eq 'xtls'){
        $tls=[ordered]@{ serverName="$sni" }
        if($fp){ $tls.fingerprint="$fp" }
        if($Q['alpn']){ $tls.alpn=@("$($Q['alpn'])" -split ',' | Where-Object { $_ }) }
        if((Test-Truthy $Q['allowInsecure']) -or (Test-Truthy $Q['insecure'])){ $tls.allowInsecure=$true }
        $ss.security='tls'; $ss.tlsSettings=$tls
    } else { $ss.security='none' }
    if($Proto -eq 'trojan'){
        $settings=[ordered]@{ servers=@([ordered]@{ address=$HostName; port=$Port; password=$Password }) }
    } else {
        $u=[ordered]@{ id=$Uuid }
        if($Proto -eq 'vless'){
            $u.encryption=$(if($Q['encryption']){"$($Q['encryption'])"}else{'none'})
            if($Q['flow']){ $u.flow="$($Q['flow'])" }
        } else { $u.security=$Security; $u.alterId=$AlterId }
        $settings=[ordered]@{ vnext=@([ordered]@{ address=$HostName; port=$Port; users=@($u) }) }
    }
    return [ordered]@{ type="$Proto+xhttp"; _xray=[ordered]@{ protocol=$Proto; settings=$settings; streamSettings=$ss }; _server=@($HostName,$Port) }
}

function New-Profile {
    param([string]$Name,$Outbound,[string]$Source)
    if(-not $Name){ $Name="$($Outbound.type)" }
    if($Outbound -is [System.Collections.IDictionary] -and $Outbound.Contains('_xray')){
        return [pscustomobject]@{ name=$Name.Trim(); source=$Source; type="$($Outbound.type)"; endpoint=$false; engine='xray'
                                  xray=$Outbound['_xray']; server=@($Outbound['_server'])
                                  outbound=[ordered]@{ type='socks'; server='127.0.0.1'; server_port=$script:XrayPort; version='5' } }
    }
    [pscustomobject]@{ name=$Name.Trim(); source=$Source; type="$($Outbound.type)"; endpoint=("$($Outbound.type)" -eq 'wireguard'); outbound=$Outbound }
}

function New-WgEndpoint {
    param([string]$PrivateKey,[string[]]$Addresses,[string]$PeerHost,[int]$PeerPort,[string]$PublicKey,
          [string]$Psk='',$Mtu=$null,$Reserved=$null,$Keepalive=25)
    if(-not ($PrivateKey -and $PublicKey -and $PeerHost -and $PeerPort -and $Addresses)){
        throw 'в конфиге WireGuard не хватает PrivateKey, Address, PublicKey или Endpoint'
    }
    $addrs=@()
    foreach($a in $Addresses){
        $a=$a.Trim(); if(-not $a){ continue }
        if($a -notmatch '/'){ $a+=$(if($a -match ':'){'/128'}else{'/32'}) }
        $addrs+=$a
    }
    $peer=[ordered]@{ address=$PeerHost; port=$PeerPort; public_key=$PublicKey
                      allowed_ips=@('0.0.0.0/0','::/0'); persistent_keepalive_interval=[int]$(if($Keepalive){$Keepalive}else{25}) }
    if($Psk){ $peer.pre_shared_key=$Psk }
    if($Reserved){ $peer.reserved=@($Reserved) }
    return [ordered]@{ type='wireguard'; mtu=[int]$(if($Mtu){$Mtu}else{1408}); address=@($addrs); private_key=$PrivateKey; peers=@($peer) }
}

function ConvertFrom-WireGuardConf {
    # Обычный конфиг WireGuard (.conf): Proton VPN, свой сервер, любой провайдер.
    param([string]$Text,[string]$DefaultName='WireGuard')
    $iface=@{}; $peer=@{}; $cur=$null; $peerSeen=$false
    foreach($ln in $Text -split "`r?`n"){
        $ln=($ln -split '#',2)[0].Trim()
        if(-not $ln){ continue }
        if($ln -ieq '[Interface]'){ $cur=$iface; continue }
        if($ln -ieq '[Peer]'){ if($peerSeen){ $cur=@{} } else { $cur=$peer; $peerSeen=$true }; continue }
        if($ln -match '^([^=]+?)\s*=\s*(.*)$' -and $null -ne $cur){ $cur[$Matches[1].Trim().ToLowerInvariant()]=$Matches[2].Trim() }
    }
    foreach($k in @('jc','jmin','jmax','s1','s2','h1','h2','h3','h4')){
        if($iface.ContainsKey($k)){
            throw 'это конфиг AmneziaWG (параметры Jc/S1/H1...): sing-box его не поддерживает. Нужен обычный WireGuard или другой протокол (VLESS, Shadowsocks...)'
        }
    }
    $ep="$($peer['endpoint'])"
    $h=''; $port=0
    if($ep -match '^\[(.+)\]:(\d+)$'){ $h=$Matches[1]; $port=[int]$Matches[2] }
    elseif($ep -match '^(.+):(\d+)$'){ $h=$Matches[1]; $port=[int]$Matches[2] }
    $resText="$($iface['reserved'])"; if(-not $resText){ $resText="$($peer['reserved'])" }
    $reserved=@($resText -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    $ob=New-WgEndpoint -PrivateKey "$($iface['privatekey'])" -Addresses @("$($iface['address'])" -split ',') -PeerHost $h -PeerPort $port `
          -PublicKey "$($peer['publickey'])" -Psk "$($peer['presharedkey'])" -Mtu $iface['mtu'] `
          -Reserved $(if($reserved.Count -eq 3){$reserved}else{$null}) -Keepalive $peer['persistentkeepalive']
    return ,@("$DefaultName $h",$ob)
}

function ConvertFrom-ServerLink {
    # Одна ссылка -> @(имя, outbound). Бросает исключение с понятным текстом.
    param([string]$Link)
    $scheme=($Link -split '://',2)[0].ToLowerInvariant()
    switch($scheme){
        'vless' {
            $l=Split-ServerLink $Link; Assert-Server $l
            if(Test-XhttpQuery $l.Q){
                return ,@($(if($l.Name){$l.Name}else{"VLESS $($l.Host)"}),(New-XrayLinkOutbound -Proto 'vless' -HostName $l.Host -Port $l.Port -Q $l.Q -Uuid $l.User))
            }
            $ob=[ordered]@{ type='vless'; server=$l.Host; server_port=$l.Port; uuid=$l.User; packet_encoding='xudp' }
            if($l.Q['flow']){ $ob.flow=$l.Q['flow'] }
            $tls=New-TlsBlock $l.Q $l.Host; if($tls){ $ob.tls=$tls }
            $tr=New-TransportBlock $l.Q; if($tr){ $ob.transport=$tr }
            return ,@($(if($l.Name){$l.Name}else{"VLESS $($l.Host)"}),$ob)
        }
        'vmess' {
            $body=$Link.Trim().Substring(8)
            if($body -match '@' -and $body -match '\?'){
                $l=Split-ServerLink $Link; Assert-Server $l
                $ob=[ordered]@{ type='vmess'; server=$l.Host; server_port=$l.Port; uuid=$l.User; security='auto'; alter_id=0 }
                $q=$l.Q; $name=$l.Name; $h=$l.Host
                $tls=New-TlsBlock $q $h
            } else {
                try { $j=(ConvertFrom-AnyBase64 (($body -split '#',2)[0])) | ConvertFrom-Json }
                catch { throw 'ссылка vmess:// не расшифровывается (ожидался base64 с JSON)' }
                $h="$($j.add)"; $port=0; [void][int]::TryParse("$($j.port)",[ref]$port)
                if(-not $h -or -not $port){ throw 'в ссылке нет адреса сервера или порта' }
                $name="$($j.ps)"
                $q=@{}
                if($j.net){ $q['type']="$($j.net)" }; if($j.host){ $q['host']="$($j.host)" }; if($j.path){ $q['path']="$($j.path)" }
                if($j.type){ $q['headerType']="$($j.type)" }; if($j.sni){ $q['sni']="$($j.sni)" }; if($j.alpn){ $q['alpn']="$($j.alpn)" }
                if($j.fp){ $q['fp']="$($j.fp)" }
                if("$($j.tls)".ToLowerInvariant() -eq 'tls'){ $q['security']='tls' }
                if("$($j.net)" -eq 'grpc' -and $j.path){ $q['serviceName']="$($j.path)" }
                $aid=0; [void][int]::TryParse("$($j.aid)",[ref]$aid)
                $ob=[ordered]@{ type='vmess'; server=$h; server_port=$port; uuid="$($j.id)"; security=$(if($j.scy){"$($j.scy)"}else{'auto'}); alter_id=$aid }
                $tls=New-TlsBlock $q $(if($q['host']){$q['host']}else{$h})
            }
            if(Test-XhttpQuery $q){
                return ,@($(if($name){$name}else{"VMess $h"}),(New-XrayLinkOutbound -Proto 'vmess' -HostName "$($ob.server)" -Port ([int]$ob.server_port) -Q $q -Uuid "$($ob.uuid)" -Security "$($ob.security)" -AlterId ([int]$ob.alter_id)))
            }
            if($tls){ $ob.tls=$tls }
            $tr=New-TransportBlock $q; if($tr){ $ob.transport=$tr }
            return ,@($(if($name){$name}else{"VMess $h"}),$ob)
        }
        'trojan' {
            $l=Split-ServerLink $Link; Assert-Server $l
            if(Test-XhttpQuery $l.Q){
                return ,@($(if($l.Name){$l.Name}else{"Trojan $($l.Host)"}),(New-XrayLinkOutbound -Proto 'trojan' -HostName $l.Host -Port $l.Port -Q $l.Q -Password $l.User))
            }
            $ob=[ordered]@{ type='trojan'; server=$l.Host; server_port=$l.Port; password=$l.User }
            if("$($l.Q['security'])".ToLowerInvariant() -ne 'none'){ $ob.tls=New-TlsBlock $l.Q $l.Host -Force }
            $tr=New-TransportBlock $l.Q; if($tr){ $ob.transport=$tr }
            return ,@($(if($l.Name){$l.Name}else{"Trojan $($l.Host)"}),$ob)
        }
        'ss' {
            $body=$Link.Trim().Substring(5); $name=''; $query=''
            if($body -match '#'){ $parts=$body -split '#',2; $body=$parts[0]; $name=[uri]::UnescapeDataString($parts[1]) }
            if($body -match '\?'){ $parts=$body -split '\?',2; $body=$parts[0]; $query=$parts[1] }
            $body=$body.TrimEnd('/')
            if($body -notmatch '@'){ $body=ConvertFrom-AnyBase64 $body }       # ss://base64(method:pass@host:port)
            $at=$body.LastIndexOf('@')
            if($at -lt 1){ throw 'в ссылке ss:// нет userinfo@host:port (повреждённая ссылка или не base64)' }
            $cred=$body.Substring(0,$at); $addr=$body.Substring($at+1)
            if($cred -notmatch ':'){ $cred=ConvertFrom-AnyBase64 ([uri]::UnescapeDataString($cred)) }   # ss://base64(method:pass)@host:port
            else { $cred=[uri]::UnescapeDataString($cred) }
            $mp=$cred -split ':',2
            $h=''; $port=0
            if($addr -match '^\[(.+)\]:(\d+)$'){ $h=$Matches[1]; $port=[int]$Matches[2] }
            elseif($addr -match '^(.+):(\d+)$'){ $h=$Matches[1]; $port=[int]$Matches[2] }
            if(-not $h -or -not $port){ throw 'в ссылке нет адреса сервера или порта' }
            $ob=[ordered]@{ type='shadowsocks'; server=$h; server_port=$port; method=$mp[0]; password=$(if($mp.Count -gt 1){$mp[1]}else{''}) }
            if($query -match '(?:^|&)plugin=([^&]+)'){
                $plugin=[uri]::UnescapeDataString($Matches[1]); $pp=$plugin -split ';',2
                $pn=$pp[0]; if($pn -in @('simple-obfs','obfs')){ $pn='obfs-local' }
                if($pn -notin @('obfs-local','v2ray-plugin')){ throw "плагин Shadowsocks '$pn' sing-box не поддерживает" }
                $ob.plugin=$pn; $ob.plugin_opts=$(if($pp.Count -gt 1){$pp[1]}else{''})
            }
            return ,@($(if($name){$name}else{"Shadowsocks $h"}),$ob)
        }
        { $_ -in @('hysteria2','hy2') } {
            $l=Split-ServerLink $Link; Assert-Server $l
            $pw=$l.User; if($l.Pass){ $pw+=":$($l.Pass)" }
            $ob=[ordered]@{ type='hysteria2'; server=$l.Host; server_port=$l.Port; password=$pw; tls=(New-TlsBlock $l.Q $l.Host -Force) }
            if($l.Q['obfs'] -and $l.Q['obfs'] -ne 'none'){ $ob.obfs=[ordered]@{ type=$l.Q['obfs']; password="$($l.Q['obfs-password'])" } }
            return ,@($(if($l.Name){$l.Name}else{"Hysteria2 $($l.Host)"}),$ob)
        }
        'hysteria' {
            $l=Split-ServerLink $Link; Assert-Server $l
            $up=20; $down=100
            if($l.Q['upmbps']){ $up=[int][double]$l.Q['upmbps'] }; if($l.Q['downmbps']){ $down=[int][double]$l.Q['downmbps'] }
            $ob=[ordered]@{ type='hysteria'; server=$l.Host; server_port=$l.Port; up_mbps=$up; down_mbps=$down; tls=(New-TlsBlock $l.Q $l.Host -Force) }
            if($l.Q['auth']){ $ob.auth_str=$l.Q['auth'] }
            if($l.Q['obfsParam']){ $ob.obfs=$l.Q['obfsParam'] }
            return ,@($(if($l.Name){$l.Name}else{"Hysteria $($l.Host)"}),$ob)
        }
        'tuic' {
            $l=Split-ServerLink $Link; Assert-Server $l
            $cc=$l.Q['congestion_control']; if(-not $cc){ $cc=$l.Q['congestion-control'] }; if(-not $cc){ $cc='bbr' }
            $ob=[ordered]@{ type='tuic'; server=$l.Host; server_port=$l.Port; uuid=$l.User; password=$l.Pass; congestion_control=$cc; tls=(New-TlsBlock $l.Q $l.Host -Force) }
            $mode=$l.Q['udp_relay_mode']; if(-not $mode){ $mode=$l.Q['udp-relay-mode'] }
            if($mode){ $ob.udp_relay_mode=$mode }
            return ,@($(if($l.Name){$l.Name}else{"TUIC $($l.Host)"}),$ob)
        }
        'anytls' {
            $l=Split-ServerLink $Link; Assert-Server $l
            $ob=[ordered]@{ type='anytls'; server=$l.Host; server_port=$l.Port; password=$l.User; tls=(New-TlsBlock $l.Q $l.Host -Force) }
            return ,@($(if($l.Name){$l.Name}else{"AnyTLS $($l.Host)"}),$ob)
        }
        { $_ -in @('socks','socks5','socks4') } {
            $l=Split-ServerLink $Link; Assert-Server $l
            $user=$l.User; $pass=$l.Pass
            if($user -and -not $pass -and $user -notmatch ':'){      # socks://base64(user:pass)@host:port
                try { $dec=ConvertFrom-AnyBase64 $user; if($dec -match ':'){ $up=$dec -split ':',2; $user=$up[0]; $pass=$up[1] } } catch {}
            }
            $ob=[ordered]@{ type='socks'; server=$l.Host; server_port=$l.Port; version=$(if($scheme -eq 'socks4'){'4'}else{'5'}) }
            if($user){ $ob.username=$user; $ob.password=$pass }
            return ,@($(if($l.Name){$l.Name}else{"SOCKS $($l.Host)"}),$ob)
        }
        { $_ -in @('wireguard','wg') } {
            $l=Split-ServerLink $Link; Assert-Server $l
            $reserved=@("$($l.Q['reserved'])" -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
            $priv=$l.User; if(-not $priv){ $priv=$l.Q['privatekey'] }
            $pub=$l.Q['publickey']; if(-not $pub){ $pub=$l.Q['peer'] }
            $addr=$l.Q['address']; if(-not $addr){ $addr=$l.Q['ip'] }
            $ob=New-WgEndpoint -PrivateKey "$priv" -Addresses @("$addr" -split ',') -PeerHost $l.Host -PeerPort $l.Port -PublicKey "$pub" `
                  -Psk "$($l.Q['presharedkey'])" -Mtu $l.Q['mtu'] -Reserved $(if($reserved.Count -eq 3){$reserved}else{$null})
            return ,@($(if($l.Name){$l.Name}else{"WireGuard $($l.Host)"}),$ob)
        }
        default { throw 'формат не поддерживается' }
    }
}

function ConvertFrom-XrayJson {
    # Конфиг Xray (целый или один outbound): массив профилей либо $null.
    param($J,[string]$Source)
    $items=$null
    if($J -is [array]){
        if($J.Count -and -not @($J | Where-Object { -not ($_ -and $_.PSObject.Properties['protocol']) }).Count){ $items=@($J) }
    } elseif($J.PSObject.Properties['outbounds'] -and @($J.outbounds | Where-Object { $_ -and $_.PSObject.Properties['protocol'] }).Count){
        $items=@($J.outbounds)
    } elseif($J.PSObject.Properties['protocol'] -and -not $J.PSObject.Properties['type']){ $items=@($J) }
    if($null -eq $items){ return $null }
    $out=New-Object System.Collections.Generic.List[object]
    foreach($it in $items){
        if(-not $it -or (@('freedom','blackhole','dns','loopback') -contains "$($it.protocol)")){ continue }
        $s=$it.settings; $h=''; $port=$null
        foreach($key in @('vnext','servers','peers')){
            if($h -or -not $s -or -not $s.PSObject.Properties[$key]){ continue }
            $first=@($s.$key)[0]
            if($first -and $first.address){ $h="$($first.address)"; $port=$first.port }
            elseif($first -and $first.endpoint -and "$($first.endpoint)" -match '^\[?(.+?)\]?:(\d+)$'){ $h=$Matches[1]; $port=[int]$Matches[2] }
        }
        if(-not $h -and $s -and $s.address){ $h="$($s.address)"; $port=$s.port }
        if(-not $h){ continue }
        $ob=Copy-ToOrdered $it
        foreach($k in @('tag','proxySettings','sendThrough')){ if($ob.Contains($k)){ $ob.Remove($k) } }
        $net='tcp'
        if($it.streamSettings){
            if($it.streamSettings.network){ $net="$($it.streamSettings.network)" }
            # цепочки на другие outbound не переносим
            if($it.streamSettings.sockopt -and $it.streamSettings.sockopt.PSObject.Properties['dialerProxy']){ $it.streamSettings.sockopt.PSObject.Properties.Remove('dialerProxy') }
        }
        $name="$($it.tag)"; if(-not $name){ $name="$($it.protocol) $h" }
        $out.Add((New-Profile $name ([ordered]@{ type="$($it.protocol)+$net (xray)"; _xray=$ob; _server=@($h,$port) }) $Source))
    }
    if(-not $out.Count){ throw 'в конфиге Xray нет ни одного сервера (outbound с адресом)' }
    return ,$out.ToArray()
}

function ConvertFrom-SingBoxJson {
    # Outbound/endpoint sing-box или целый конфиг: берём все серверы из него.
    param([string]$Text,[string]$Source)
    try { $j=$Text | ConvertFrom-Json } catch { throw ("JSON не разбирается: " + $_.Exception.Message) }
    $xray=ConvertFrom-XrayJson $j $Source
    if($null -ne $xray){ return ,$xray }
    $items=@()
    if($j -is [array]){ $items=@($j) }
    elseif($j.PSObject.Properties['outbounds'] -or $j.PSObject.Properties['endpoints']){ $items=@($j.endpoints)+@($j.outbounds) }
    else { $items=@($j) }
    $skip=@('direct','block','dns','selector','urltest','tor','ssh')
    $out=New-Object System.Collections.Generic.List[object]
    foreach($it in $items){
        if(-not $it -or -not $it.PSObject.Properties['type'] -or ($skip -contains "$($it.type)")){ continue }
        $ob=[ordered]@{}
        foreach($prop in $it.PSObject.Properties){ if(@('tag','detour','domain_resolver') -notcontains $prop.Name){ $ob[$prop.Name]=$prop.Value } }
        $name="$($it.tag)"; if(-not $name){ $name="$($it.type) $($it.server)" }
        $out.Add((New-Profile $name $ob $Source))
    }
    if(-not $out.Count){ throw 'в JSON нет ни одного сервера (outbound с адресом)' }
    return ,$out.ToArray()
}

function ConvertTo-Profiles {
    <#
      Разбирает всё, что дал пользователь: файл, ссылку, список ссылок,
      подписку. Возвращает объект: Profiles (массив) и Errors (массив строк).
    #>
    param([string]$Text,[string]$Source='custom',[int]$Depth=0)
    $Text=$Text.Trim().TrimStart([char]0xFEFF)
    if(-not $Text){ throw 'пустой ввод' }
    $profiles=New-Object System.Collections.Generic.List[object]
    $errors=New-Object System.Collections.Generic.List[string]
    if($Text -match '(?im)^\s*\[interface\]'){
        $r=ConvertFrom-WireGuardConf $Text $(if($Source -eq 'proton'){'Proton VPN'}else{'WireGuard'})
        $profiles.Add((New-Profile $r[0] $r[1] $Source))
        return [pscustomobject]@{ Profiles=$profiles.ToArray(); Errors=$errors.ToArray() }
    }
    if($Text[0] -eq '{' -or $Text[0] -eq '['){
        foreach($pr in (ConvertFrom-SingBoxJson $Text $Source)){ $profiles.Add($pr) }
        return [pscustomobject]@{ Profiles=$profiles.ToArray(); Errors=$errors.ToArray() }
    }
    $lines=@($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' })
    # Подписка: один адрес http(s)://
    if($lines.Count -eq 1 -and $lines[0] -match '^(?i)https?://' -and $Depth -eq 0){
        try {
            [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
            $body=(Invoke-WebRequest -Uri $lines[0] -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content
            if($body -is [byte[]]){ $body=[Text.Encoding]::UTF8.GetString($body) }
        } catch { throw ("подписка не скачалась: " + $_.Exception.Message) }
        return (ConvertTo-Profiles -Text "$body" -Source $Source -Depth ($Depth+1))
    }
    # Подписка в base64 (нет ни одной "://")
    if($Text -notmatch '://' -and $Depth -lt 2){
        $dec=''
        try { $dec=ConvertFrom-AnyBase64 $Text } catch {}
        if($dec -match '://' -or $dec -match '\[Interface\]'){ return (ConvertTo-Profiles -Text $dec -Source $Source -Depth ($Depth+1)) }
        throw ("формат не распознан. Поддерживается: " + $script:SupportedFormats)
    }
    foreach($ln in $lines){
        if($ln -notmatch '^([a-zA-Z0-9]+)://'){ continue }
        $scheme=$Matches[1].ToLowerInvariant()
        try {
            $r=ConvertFrom-ServerLink $ln
            $profiles.Add((New-Profile $r[0] $r[1] $Source))
        } catch { $errors.Add("${scheme}://... - " + $_.Exception.Message) }
    }
    if(-not $profiles.Count -and -not $errors.Count){ throw ("формат не распознан. Поддерживается: " + $script:SupportedFormats) }
    return [pscustomobject]@{ Profiles=$profiles.ToArray(); Errors=$errors.ToArray() }
}

function Get-ProfileServer {
    # Хост и порт сервера профиля.
    param($Prof)
    $ob=$Prof.outbound
    if($Prof.engine -eq 'xray'){
        $net=''; if($Prof.xray.streamSettings){ $net="$($Prof.xray.streamSettings.network)" }
        $udp=(@('kcp','quic','hysteria') -contains $net) -or (@('wireguard','hysteria') -contains "$($Prof.xray.protocol)")
        return [pscustomobject]@{ Host="$(@($Prof.server)[0])"; Port=@($Prof.server)[1]; Udp=$udp }
    }
    if($Prof.endpoint){
        $peer=@($ob.peers)[0]
        return [pscustomobject]@{ Host="$($peer.address)"; Port=$peer.port; Udp=$true }
    }
    return [pscustomobject]@{ Host="$($ob.server)"; Port=$ob.server_port; Udp=(@('hysteria','hysteria2','tuic') -contains "$($ob.type)") }
}

function Get-TunnelProfiles {
    $j=Read-JsonFile (Get-TunnelPaths).Profiles
    if(-not $j){ return @() }
    return @($j.profiles | Where-Object { $_ })
}

function Save-TunnelProfiles {
    param([object[]]$Profiles)
    $p=Get-TunnelPaths
    New-Item -ItemType Directory -Path $p.Dir -Force | Out-Null
    Write-JsonFile $p.Profiles ([ordered]@{ profiles=@($Profiles) })
    Update-TunnelServers $Profiles
}

function Update-TunnelServers {
    <#
      Адреса серверов туннеля - в файл исключений zapret: соединение с самим
      сервером zapret не должен "лечить" подменой SNI и разрезанием (сервер на
      Hetzner/OVH/DigitalOcean попал бы под профиль хостингов).
    #>
    param([object[]]$Profiles)
    $ips=New-Object System.Collections.Generic.List[string]
    foreach($pr in $Profiles){
        $h=(Get-ProfileServer $pr).Host
        if(-not $h){ continue }
        $cand=@()
        if(Test-IpLiteral $h){ $cand=@($h) }
        else { try { $cand=@([Net.Dns]::GetHostAddresses($h) | ForEach-Object { $_.IPAddressToString }) } catch { $cand=@() } }
        foreach($ip in $cand){ if(-not $ips.Contains($ip)){ $ips.Add($ip) } }
    }
    $p=Get-TunnelPaths
    $lines=@($script:TunnelIpsetHeader)+$ips.ToArray()
    [IO.File]::WriteAllLines($p.Servers,$lines,[Text.UTF8Encoding]::new($false))
}

function Get-ProfileParts {
    # endpoints и outbounds для конфига sing-box (профиль получает tag 'tunnel').
    param($Prof,[switch]$Probe)
    # Только что разобранный профиль - словарь, прочитанный из файла - объект.
    $ob=Copy-ToOrdered $Prof.outbound
    $ob['tag']='tunnel'
    if($Prof.engine -eq 'xray'){ $ob['server_port']=$(if($Probe){$script:XrayProbePort}else{$script:XrayPort}) }
    if($Prof.endpoint){ return [pscustomobject]@{ Endpoints=@($ob); Outbounds=@() } }
    return [pscustomobject]@{ Endpoints=@(); Outbounds=@($ob) }
}

function New-XrayConfig {
    # Конфиг xray-core: локальный SOCKS -> сервер профиля.
    param($Prof,[int]$Port)
    $ob=Copy-ToOrdered $Prof.xray
    $ob['tag']='proxy'
    return [ordered]@{
        log=[ordered]@{ loglevel='warning' }
        inbounds=@([ordered]@{ tag='socks-in'; listen='127.0.0.1'; port=$Port; protocol='socks'; settings=[ordered]@{ auth='noauth'; udp=$true } })
        outbounds=@($ob)
    }
}

function Start-XrayProcess {
    # Запускает xray-core с конфигом и ждёт локальный порт. Процесс или $null.
    param($Prof,[int]$Port,[string]$ConfigPath,[string]$LogPath)
    Install-Xray
    $p=Get-TunnelPaths
    Write-JsonFile $ConfigPath (New-XrayConfig $Prof $Port)
    $proc=Start-Process -FilePath $p.Xray -ArgumentList @('run','-c',"`"$ConfigPath`"") -WorkingDirectory $p.Dir -WindowStyle Hidden -PassThru `
              -RedirectStandardOutput $LogPath -RedirectStandardError "$LogPath.err"
    $null=$proc.Handle
    if(-not (Wait-LocalPort $Port 10000 $proc)){
        $script:TunnelTraceLast='xray-core не запустился: ' + ((@(Get-FileTail $LogPath 3) + @(Get-FileTail "$LogPath.err" 3)) -join ' | ')
        if(-not $proc.HasExited){ Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        return $null
    }
    return $proc
}

function Test-ProfileConfig {
    # Проверяет профиль настоящим sing-box или xray-core. Возвращает '' или текст ошибки.
    param($Prof)
    $ErrorActionPreference='Continue'
    $p=Get-TunnelPaths
    if($Prof.engine -eq 'xray'){
        try { Install-Xray } catch { return ('xray-core не скачался: ' + $_.Exception.Message) }
        $vf=Join-Path $p.Dir 'validate-xray.json'
        Write-JsonFile $vf (New-XrayConfig $Prof $script:XrayProbePort)
        $LASTEXITCODE=0
        $out=& $p.Xray run -test -c $vf 2>&1
        $rc=$LASTEXITCODE
        Remove-Item $vf -Force -ErrorAction SilentlyContinue
        if($rc -eq 0){ return '' }
        $msg=@($out | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
        if($msg.Count){ return $msg[-1] }
        return 'ошибка конфигурации'
    }
    $parts=Get-ProfileParts $Prof
    $cfg=[ordered]@{
        log=[ordered]@{ level='error' }
        dns=[ordered]@{ servers=@([ordered]@{ type='local'; tag='local' }) }
        outbounds=@($parts.Outbounds)+@([ordered]@{ type='direct'; tag='direct' })
        route=[ordered]@{ final='tunnel'; default_domain_resolver='local' }
    }
    if($parts.Endpoints.Count){ $cfg.endpoints=@($parts.Endpoints) }
    Write-JsonFile $p.Validate $cfg
    $LASTEXITCODE=0
    $out=& $p.Exe check -c $p.Validate 2>&1
    $rc=$LASTEXITCODE
    Remove-Item $p.Validate -Force -ErrorAction SilentlyContinue
    if($rc -eq 0){ return '' }
    $msg=@($out | ForEach-Object { "$_" -replace "$([char]27)\[[0-9;]*m",'' } | Where-Object { $_.Trim() })
    if($msg.Count){ return $msg[-1] }
    return 'ошибка конфигурации'
}

function Import-TunnelProfiles {
    # Разбирает ввод, проверяет профили sing-box и сохраняет годные.
    param([string]$Text,[string]$Source='custom')
    Ensure-Admin
    Initialize-TunnelDirs
    Remove-LegacyWarp
    $p=Get-TunnelPaths
    if(-not (Test-Path $p.Exe)){ Install-SingBox }
    $parsed=ConvertTo-Profiles -Text $Text -Source $Source
    $good=New-Object System.Collections.Generic.List[object]
    $errors=New-Object System.Collections.Generic.List[string]
    foreach($e in $parsed.Errors){ $errors.Add($e) }
    foreach($pr in $parsed.Profiles){
        $why=Test-ProfileConfig $pr
        if(-not $why){ $good.Add($pr) } else { $errors.Add("$($pr.name) - $(if($pr.engine -eq 'xray'){'xray-core'}else{'sing-box'}) не принял профиль: $why") }
    }
    foreach($e in $errors){ Write-Host "  ! $e" -ForegroundColor Yellow }
    if(-not $good.Count){ throw 'ни один профиль не подошёл' }
    if($good.Count -gt 40){
        Write-Host "  ! В подписке $($good.Count) серверов - беру первые 40." -ForegroundColor Yellow
        $good=New-Object System.Collections.Generic.List[object] (,@($good | Select-Object -First 40))
    }
    $existing=New-Object System.Collections.Generic.List[object]
    foreach($x in (Get-TunnelProfiles)){ $existing.Add($x) }
    $names=New-Object 'System.Collections.Generic.HashSet[string]'
    foreach($x in $existing){ [void]$names.Add($x.name) }
    foreach($pr in $good){
        $base=$pr.name; $n=2
        while($names.Contains($pr.name)){ $pr.name="$base ($n)"; $n++ }    # одинаковые имена различаем номером
        [void]$names.Add($pr.name)
        $existing.Add($pr)
    }
    Save-TunnelProfiles $existing.ToArray()
    Write-Host "  Добавлено профилей: $($good.Count). Всего: $($existing.Count)" -ForegroundColor Green
    foreach($pr in $good){ $s=Get-ProfileServer $pr; Write-Host "    $($pr.name)  [$($pr.type)]  $($s.Host):$($s.Port)" -ForegroundColor DarkGray }
    # zapret должен узнать о новых серверах (исключения).
    Write-LaunchConfig
    if((Get-Status).Running){
        Write-Host '  Перезапуск обхода, чтобы zapret учёл серверы туннеля...' -ForegroundColor DarkGray
        Stop-Zapret -Quiet
        Start-Zapret
    }
    $st=Read-JsonFile $p.State
    if(-not ($st -and $st.pinned -and (Find-TunnelProfile "$($st.active)"))){
        Remove-Item $p.State -Force -ErrorAction SilentlyContinue     # выбрать лучший профиль заново
    }
}

function Read-UserInput {
    # Путь к файлу -> его содержимое; иначе сам текст (ссылка, base64, JSON).
    param([string]$Value)
    $Value=$Value.Trim().Trim('"').Trim("'")
    if($Value -and $Value -notmatch "`n" -and $Value -notmatch '://' -and (Test-Path -LiteralPath $Value -PathType Leaf)){
        return [IO.File]::ReadAllText($Value)
    }
    if($Value -notmatch '://' -and $Value -notmatch '^[\{\[]' -and ($Value -match '[\\/]' -or $Value -match '\.(conf|json|txt)$')){
        throw "файл не найден: $Value"
    }
    return $Value
}

# --- конфигурация sing-box ----------------------------------------------------

# --- внешний список сайтов с региональными ограничениями ----------------------

function Test-GeoListEnabled { return (-not (Test-Path -LiteralPath (Get-TunnelPaths).GeoListOff)) }

function Get-GeoListEntries {
    if(-not (Test-GeoListEnabled)){ return @() }
    return @(Get-ListEntries (Get-TunnelPaths).GeoList)
}

function Get-TunnelDomains {
    # Все домены, идущие в туннель: свой список и внешний, без повторов.
    $p=Get-TunnelPaths
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $all=New-Object System.Collections.Generic.List[string]
    foreach($d in (@(Get-ListEntries $p.List) + @(Get-GeoListEntries))){
        if($all.Count -ge $script:TunnelDomainsMax){ break }
        if($seen.Add($d)){ $all.Add($d) }
    }
    return $all.ToArray()
}

function Get-TunnelSitesSummary {
    $own=@(Get-ListEntries (Get-TunnelPaths).List).Count
    $ext=@(Get-TunnelDomains).Count - $own
    if($ext -gt 0){ return "$own своих + $ext из внешнего списка" }
    return "$own"
}

function Get-GeoListAgeHours {
    # Сколько часов назад список обновлялся; -1, если его ещё нет.
    $f=(Get-TunnelPaths).GeoList
    if(-not (Test-Path -LiteralPath $f)){ return -1 }
    return [Math]::Max(0,((Get-Date) - (Get-Item -LiteralPath $f).LastWriteTime).TotalHours)
}

function Get-GeoListStatus {
    if(-not (Test-GeoListEnabled)){ return 'выключен' }
    $n=@(Get-GeoListEntries).Count
    $age=Get-GeoListAgeHours
    if($age -lt 0 -or -not $n){ return 'ещё не скачан' }
    if($age -lt 1){ return "$n доменов, обновлён меньше часа назад" }
    return "$n доменов, обновлён $([int][Math]::Floor($age)) ч назад"
}

function Update-GeoList {
    <#
      Обновляет внешний список, если он старше суток (или -Force). Возвращает
      $true, если список скачан заново. Сбой не мешает работе: остаётся прежний.
    #>
    param([switch]$Force)
    if(-not (Test-GeoListEnabled)){ return $false }
    $p=Get-TunnelPaths
    $age=Get-GeoListAgeHours
    if(-not $Force -and $age -ge 0 -and $age -lt 23){ return $false }
    Initialize-TunnelDirs
    $text=$null; $lastErr=''
    # Напрямую, а если не вышло и туннель работает - через него.
    $proxies=@('')
    if((Get-TunnelStatus).Running){ $proxies+="http://127.0.0.1:$($script:TunnelMixedPort)" }
    foreach($px in $proxies){
        try {
            [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
            $wr=@{ Uri=$script:GeoListUrl; UseBasicParsing=$true; TimeoutSec=30; ErrorAction='Stop' }
            if($px){ $wr.Proxy=$px }
            $body=(Invoke-WebRequest @wr).Content
            if($body -is [byte[]]){ $body=[Text.Encoding]::UTF8.GetString($body) }
            $text="$body"
            break
        } catch { $lastErr=$_.Exception.Message }
    }
    $doms=New-Object System.Collections.Generic.List[string]
    if($text){
        $seen=New-Object 'System.Collections.Generic.HashSet[string]'
        foreach($ln in $text -split "`r?`n"){
            $d=($ln -split '#',2)[0].Trim().ToLowerInvariant().Trim('.')
            if($d -and $d -match '^([a-z0-9_]([a-z0-9_-]*[a-z0-9_])?\.)+[a-z0-9-]{2,}$' -and $seen.Add($d)){ $doms.Add($d) }
        }
        if($doms.Count -lt 50){ $lastErr="в ответе только $($doms.Count) доменов - это не список" }
    }
    if($doms.Count -lt 50){
        Write-Host "  ! Внешний список сайтов с региональными ограничениями не скачался: $lastErr" -ForegroundColor Yellow
        if($age -ge 0){ Write-Host '    Используется прежний список.' -ForegroundColor DarkGray }
        return $false
    }
    $old=@(Get-ListEntries $p.GeoList)
    $lines=@('# Сайты, которые сами не пускают из России. Источник:',
             "# $($script:GeoListUrl)",
             '# Файл обновляется автоматически раз в сутки - правки здесь будут потеряны.',
             '# Свои сайты добавляйте в tunnel.txt.') + $doms.ToArray()
    [IO.File]::WriteAllLines($p.GeoList,$lines,[Text.UTF8Encoding]::new($false))
    $msg="  Внешний список сайтов с региональными ограничениями: $($doms.Count) доменов"
    if($old.Count){
        $added=@($doms | Where-Object { $old -notcontains $_ }).Count
        $gone=@($old | Where-Object { -not $doms.Contains($_) }).Count
        $msg+=" (добавлено $added, убрано $gone)"
    }
    Write-Host $msg -ForegroundColor Green
    Remove-HostsDomains $doms.ToArray()
    Write-TunnelRules
    return $true
}

function Install-GeoListTask {
    # Обновление списка раз в сутки - задача планировщика.
    # Запускает защищённую копию скрипта (F-05), см. Install-Autostart.
    $l=Get-TrustedLaunch @('-Action','TunnelGeoListAuto') -Hidden
    $act=New-ScheduledTaskAction -Execute $l.File -Argument $l.Args
    $trg=New-ScheduledTaskTrigger -Daily -At (Get-Date)
    $pr=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $set=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $script:GeoListTask -Action $act -Trigger $trg -Principal $pr -Settings $set -Force | Out-Null
}

function Remove-GeoListTask {
    Unregister-ScheduledTask -TaskName $script:GeoListTask -Confirm:$false -ErrorAction SilentlyContinue
}

function Test-GeoListTask {
    return (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\Tasks\$($script:GeoListTask)"))
}

function Sync-GeoList {
    # Задача и свежий список есть, пока включены туннель и внешний список.
    try {
        if((Test-Path -LiteralPath (Get-TunnelPaths).Enabled) -and (Test-GeoListEnabled)){
            if(-not (Test-GeoListTask)){ Install-GeoListTask }
            [void](Update-GeoList)
        } elseif(Test-GeoListTask){ Remove-GeoListTask }
    } catch {
        Write-Host ('  ! Внешний список: ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Switch-GeoList {
    Ensure-Admin
    Initialize-TunnelDirs
    $p=Get-TunnelPaths
    if(Test-GeoListEnabled){
        [IO.File]::WriteAllText($p.GeoListOff,'1',[Text.Encoding]::ASCII)
        Remove-GeoListTask
        Write-TunnelRules
        Write-Host '  Внешний список выключен: в туннель идут только сайты из своего списка.' -ForegroundColor Green
    } else {
        Remove-Item -LiteralPath $p.GeoListOff -Force -ErrorAction SilentlyContinue
        Sync-GeoList
        Write-TunnelRules
        if(Test-Path -LiteralPath $p.Enabled){ Write-Host "  Внешний список включён: $(@(Get-GeoListEntries).Count) доменов." -ForegroundColor Green }
        else { Write-Host '  Внешний список включён: он скачается при включении туннеля.' -ForegroundColor Green }
    }
}

function Write-TunnelRules {
    # rule-set для sing-box из списка туннеля (свой + внешний); sing-box перечитывает его сам.
    $p=Get-TunnelPaths
    Initialize-TunnelDirs
    $d=@(Get-TunnelDomains)
    if(-not $d.Count){ $d=@('tunnel.invalid') }   # пустое правило sing-box не примет
    Write-JsonFile $p.Rules ([ordered]@{ version=2; rules=@([ordered]@{ domain_suffix=@($d) }) })
    if((Get-TunnelStatus).Running){ Set-TunnelDns }
}

function Remove-TunnelDns {
    try {
        Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Comment -eq $script:TunnelNrptComment } |
            ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction SilentlyContinue }
    } catch {}
}

function Set-TunnelDns {
    <#
      DNS-запросы доменов из списка туннеля Windows должна отправлять в
      sing-box, иначе они получат обычные адреса и пойдут мимо туннеля.
      Правило NRPT делает это только для этих доменов и их поддоменов;
      остальной DNS не меняется.
    #>
    $p=Get-TunnelPaths
    Remove-TunnelDns
    $d=@(Get-TunnelDomains)
    if(-not $d.Count){ return }
    $ns=@(); foreach($x in $d){ $ns+=$x; $ns+=".$x" }
    $ns+=$script:DohCanary
    try {
        # Группами: у одного правила NRPT ограничено число пространств имён.
        for($i=0;$i -lt $ns.Count;$i+=40){
            $chunk=@($ns[$i..([Math]::Min($i+39,$ns.Count-1))])
            Add-DnsClientNrptRule -Namespace $chunk -NameServers $script:TunnelDns4 -Comment $script:TunnelNrptComment -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-Host ('  ! Не удалось задать правило DNS для туннеля: ' + $_.Exception.Message) -ForegroundColor Yellow
    }
    & ipconfig.exe /flushdns | Out-Null
}

function Test-TunnelDns {
    # Проверяет, что домен из списка туннеля действительно получает FakeIP.
    $d=@(Get-TunnelDomains)
    if(-not $d.Count){ return }
    $ips=@()
    try { $ips=@(Resolve-DnsName -Name $d[0] -Type A -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }) } catch {}
    if(@($ips | Where-Object { $_.StartsWith($script:TunnelFake4Prefix) }).Count){
        Write-Host "  DNS доменов из списка идёт в туннель ($($d[0]) -> $($ips[0]))" -ForegroundColor Green
    } else {
        Write-Host "  ! DNS: $($d[0]) получает обычный адрес ($($ips -join ', ')), а не адрес туннеля $($script:TunnelFake4Prefix)x.x - сайт пойдёт мимо туннеля." -ForegroundColor Yellow
        Write-Host '    Проверьте: Get-DnsClientNrptRule; запись домена в файле hosts.' -ForegroundColor DarkGray
    }
}

function Write-TunnelConfig {
    param($Prof)
    $p=Get-TunnelPaths
    Write-TunnelRulesFileOnly
    $parts=Get-ProfileParts $Prof
    $fake=[ordered]@{ type='fakeip'; tag='fakeip'; inet4_range=$script:TunnelFake4 }
    # Медиасерверы Discord - в туннель, только если так решила проверка трансляций.
    $discord=@(); if(Test-Path -LiteralPath $p.DiscordMedia){ $discord=@($script:DiscordMediaCidr4) }
    $tunAddr=@($script:TunnelAddr4); $tunRoute=@($script:TunnelFake4)+$script:TelegramCidr4+$discord
    if(Test-Ipv6Available){
        $fake.inet6_range=$script:TunnelFake6
        $tunAddr+=$script:TunnelAddr6; $tunRoute+=@($script:TunnelFake6)+$script:TelegramCidr6
    }
    $cfg=[ordered]@{
        log=[ordered]@{ level='warn'; timestamp=$true; output=$p.Log }
        dns=[ordered]@{
            servers=@(
                [ordered]@{ type='local'; tag='local' },
                $fake,
                # Настоящие адреса сайтов из списка ищем через сам туннель.
                [ordered]@{ type='tcp'; tag='tunnel-dns'; server='1.1.1.1'; detour='tunnel' }
            )
            rules=@(
                [ordered]@{ domain=@($script:DohCanary); action='predefined'; rcode='NXDOMAIN' },
                [ordered]@{ inbound=@('tun-in'); rule_set=@('tunnel-domains'); query_type=@('A','AAAA'); server='fakeip' }
            )
            final='local'
        }
        inbounds=@(
            [ordered]@{
                type='tun'; tag='tun-in'; interface_name=$script:TunnelIf
                address=@($tunAddr); mtu=1400
                auto_route=$true; strict_route=$false; stack='gvisor'
                # В TUN идут только FakeIP, подсети Telegram и (если проверка так
                # решила) медиасерверы Discord: остальной трафик мимо sing-box.
                route_address=@($tunRoute)
            },
            [ordered]@{ type='mixed'; tag='mixed-in'; listen='127.0.0.1'; listen_port=$script:TunnelMixedPort }
        )
        outbounds=@([ordered]@{ type='direct'; tag='direct' })+@($parts.Outbounds)
        route=[ordered]@{
            rule_set=@([ordered]@{ type='local'; tag='tunnel-domains'; format='source'; path=$p.Rules })
            rules=@(
                @(
                    [ordered]@{ action='sniff' },
                    [ordered]@{ protocol='dns'; action='hijack-dns' }
                )+@(
                    # Из адресов Discord в туннель идёт только UDP (медиа); TCP к ним - напрямую.
                    if($discord.Count){ [ordered]@{ inbound=@('tun-in'); network='tcp'; ip_cidr=@($discord); outbound='direct' } }
                )+@(
                    [ordered]@{ inbound=@('tun-in','mixed-in'); action='resolve'; server='tunnel-dns' },
                    [ordered]@{ inbound=@('tun-in','mixed-in'); outbound='tunnel' }
                )
            )
            final='direct'
            auto_detect_interface=$true
            default_domain_resolver='local'
        }
        experimental=[ordered]@{ cache_file=[ordered]@{ enabled=$true; path=$p.Cache; store_fakeip=$true } }
    }
    if($parts.Endpoints.Count){ $cfg.endpoints=@($parts.Endpoints) }
    Write-JsonFile $p.Config $cfg
}

function Write-TunnelRulesFileOnly {
    $p=Get-TunnelPaths
    $d=@(Get-TunnelDomains)
    if(-not $d.Count){ $d=@('tunnel.invalid') }
    Write-JsonFile $p.Rules ([ordered]@{ version=2; rules=@([ordered]@{ domain_suffix=@($d) }) })
}

# --- проверка туннеля ----------------------------------------------------------

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

function Invoke-TunnelTrace {
    <#
      Запрос https://1.1.1.1/cdn-cgi/trace через локальный прокси sing-box.
      Возвращает время ответа в мс или -1. Ответ содержит страну (loc) и
      адрес (ip), под которыми туннель виден сайтам.
    #>
    param([int]$Port,[int]$TimeoutMs=6000)
    $proto=[Net.SecurityProtocolType]::Tls12
    try { $proto=$proto -bor [Net.SecurityProtocolType]'Tls13' } catch {}
    [Net.ServicePointManager]::SecurityProtocol=$proto
    foreach($url in @('https://1.1.1.1/cdn-cgi/trace','https://www.cloudflare.com/cdn-cgi/trace')){
        try {
            $req=[Net.HttpWebRequest]::Create($url)
            $req.Proxy=New-Object Net.WebProxy("http://127.0.0.1:$Port")
            $req.Timeout=$TimeoutMs; $req.ReadWriteTimeout=$TimeoutMs; $req.KeepAlive=$false
            $sw=[Diagnostics.Stopwatch]::StartNew()
            $resp=$req.GetResponse()
            $text=(New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
            $resp.Close(); $sw.Stop()
            if($text -match '(?m)^loc=(\S+)'){
                $script:TunnelExit=@{ loc=$Matches[1] }
                if($text -match '(?m)^ip=(\S+)'){ $script:TunnelExit['ip']=$Matches[1] }
                $script:TunnelTraceLast="${url}: ответ получен, страна $($script:TunnelExit['loc'])"
                return [int]$sw.ElapsedMilliseconds
            }
            $script:TunnelTraceLast="${url}: неожиданный ответ"
        } catch { $script:TunnelTraceLast="${url}: " + $_.Exception.Message }
    }
    return -1
}

function Measure-TunnelPing {
    # Задержка через туннель: время установки TCP-соединения с 1.1.1.1:443
    # через прокси sing-box (CONNECT), лучший из трёх замеров, мс.
    param([int]$Port,[int]$TimeoutMs=4000)
    $best=-1
    foreach($i in 1..3){
        $c=$null
        try {
            $sw=[Diagnostics.Stopwatch]::StartNew()
            $c=[Net.Sockets.TcpClient]::new()
            $c.Connect('127.0.0.1',$Port)
            $s=$c.GetStream(); $s.ReadTimeout=$TimeoutMs; $s.WriteTimeout=$TimeoutMs
            $req=[Text.Encoding]::ASCII.GetBytes("CONNECT 1.1.1.1:443 HTTP/1.1`r`nHost: 1.1.1.1:443`r`n`r`n")
            $s.Write($req,0,$req.Length)
            $buf=New-Object byte[] 256
            $n=$s.Read($buf,0,256); $sw.Stop()
            $reply=[Text.Encoding]::ASCII.GetString($buf,0,$n)
            if($reply -match '^HTTP/\d\.\d 200'){
                $ms=[int]$sw.ElapsedMilliseconds
                if($best -lt 0 -or $ms -lt $best){ $best=$ms }
            }
        } catch {} finally { if($c){ $c.Dispose() } }
    }
    return $best
}

function Test-GeoSite {
    <#
      Пускает ли сайт с адреса туннеля. Запрос идёт через локальный прокси.
      'ok' - открывается; 'geo' - отказ по региону (код 451, перенаправление
      или страница с таким текстом); 'challenge' - сайт отвечает, но требует
      проверку браузера (по ней регион не определить); 'deny' - отказ 403 без
      объяснения (часто так закрывают адреса VPN); 'fail' - нет ответа.
    #>
    param([string]$Domain,[int]$Port,[int]$TimeoutMs=10000)
    $proto=[Net.SecurityProtocolType]::Tls12
    try { $proto=$proto -bor [Net.SecurityProtocolType]'Tls13' } catch {}
    [Net.ServicePointManager]::SecurityProtocol=$proto
    $url="https://$Domain/"
    for($i=0;$i -lt 4;$i++){
        $resp=$null
        try {
            $req=[Net.HttpWebRequest]::Create($url)
            $req.Proxy=New-Object Net.WebProxy("http://127.0.0.1:$Port")
            $req.AllowAutoRedirect=$false
            $req.Timeout=$TimeoutMs; $req.ReadWriteTimeout=$TimeoutMs; $req.KeepAlive=$false
            $req.UserAgent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
            $req.Accept='text/html,application/xhtml+xml,*/*;q=0.8'
            $req.Headers.Add('Accept-Language','en-US,en;q=0.9')
            try { $resp=$req.GetResponse() }
            catch [Net.WebException] { $resp=$_.Exception.Response; if(-not $resp){ return 'fail' } }
            $code=[int]$resp.StatusCode
            $location="$($resp.Headers['Location'])"
            $mitigated="$($resp.Headers['cf-mitigated'])"
            $body=''
            try {
                $sr=New-Object IO.StreamReader($resp.GetResponseStream())
                $buf=New-Object char[] 65536
                $n=$sr.ReadBlock($buf,0,$buf.Length)
                $body=[string]::new($buf,0,$n)
            } catch {}
        } catch { return 'fail' }
        finally { if($resp){ $resp.Close() } }
        if($code -eq 451){ return 'geo' }
        if($code -ge 300 -and $code -lt 400 -and $location){
            $next=([uri]::new([uri]$url,$location)).AbsoluteUri
            if($next -match $script:GeoRegex){ return 'geo' }
            if($next -notmatch '^(?i)https://'){ return 'ok' }
            $url=$next
            continue
        }
        $headText=$(if($body.Length -gt 20000){ $body.Substring(0,20000) } else { $body })
        if($code -ge 400 -and $headText -match $script:GeoRegex){ return 'geo' }
        if($mitigated -ieq 'challenge'){ return 'challenge' }
        if($code -eq 403){ if($body -match $script:GeoRegex){ return 'geo' }; return 'deny' }
        if($body.Length -lt 20000 -and $body -match $script:GeoRegex){ return 'geo' }
        if($code -lt 500){ return 'ok' }
        return 'fail'
    }
    return 'ok'
}

function Get-GeoCheck {
    # Проверка всех сайтов из списка региональных ограничений: словарь сайт -> статус.
    param([int]$Port)
    $geo=[ordered]@{}
    foreach($d in @(Get-ListEntries (Get-TunnelPaths).Geo)){ $geo[$d]=Test-GeoSite $d $Port }
    return $geo
}

function Get-GeoPairs {
    # Результат проверки (словарь или объект из state.json) -> список пар сайт/статус.
    param($Geo)
    $pairs=@()
    if($Geo -is [System.Collections.IDictionary]){ foreach($k in @($Geo.Keys)){ $pairs+=[pscustomobject]@{ Site="$k"; Status="$($Geo[$k])" } } }
    elseif($Geo){ foreach($prop in $Geo.PSObject.Properties){ $pairs+=[pscustomobject]@{ Site=$prop.Name; Status="$($prop.Value)" } } }
    return $pairs
}

function Get-GeoScore {
    # Сколько сайтов пускают с этого адреса (проверка браузера - не отказ).
    param($Geo)
    return @((Get-GeoPairs $Geo) | Where-Object { $_.Status -eq 'ok' -or $_.Status -eq 'challenge' }).Count
}

function Get-GeoSummary {
    param($Geo)
    $pairs=@(Get-GeoPairs $Geo)
    if(-not $pairs.Count){ return '' }
    $bad=@($pairs | Where-Object { $_.Status -ne 'ok' -and $_.Status -ne 'challenge' } | ForEach-Object { "$($_.Site): $($script:GeoLabel[$_.Status])" })
    $s="сайты $(Get-GeoScore $Geo)/$($pairs.Count)"
    if($bad.Count){ $s+=" ($($bad -join '; '))" }
    return $s
}

function Test-TunnelProfile {
    # Пробный запуск профиля. Возвращает объект: Ms (-1 при неудаче), Loc и Geo.
    param($Prof)
    $p=Get-TunnelPaths
    $fail=[pscustomobject]@{ Ms=-1; Loc=$null; Geo=[ordered]@{} }
    $srv=Get-ProfileServer $Prof
    # Быстрый отсев: если TCP-порт сервера не отвечает, туннель не поднимется.
    if($srv.Host -and $srv.Port -and -not $srv.Udp){
        $ok=$false
        try {
            $c=[Net.Sockets.TcpClient]::new()
            $ar=$c.BeginConnect($srv.Host,[int]$srv.Port,$null,$null)
            if($ar.AsyncWaitHandle.WaitOne(3000)){ $c.EndConnect($ar); $ok=$true }
            $c.Dispose()
        } catch {}
        if(-not $ok){
            $script:TunnelTraceLast="сервер $($srv.Host):$($srv.Port) не принимает соединение"
            Remove-Item $p.ProbeLog -Force -ErrorAction SilentlyContinue
            return $fail
        }
    }
    $xproc=$null
    if($Prof.engine -eq 'xray'){
        try { $xproc=Start-XrayProcess $Prof $script:XrayProbePort $p.XrayProbe $p.XrayProbeLog }
        catch { $script:TunnelTraceLast='xray-core: ' + $_.Exception.Message }
        if(-not $xproc){ return $fail }
    }
    $parts=Get-ProfileParts $Prof -Probe
    $cfg=[ordered]@{
        log=[ordered]@{ level='info' }
        dns=[ordered]@{ servers=@([ordered]@{ type='local'; tag='local' }) }
        inbounds=@([ordered]@{ type='mixed'; tag='mixed-in'; listen='127.0.0.1'; listen_port=$script:TunnelProbePort })
        outbounds=@($parts.Outbounds)+@([ordered]@{ type='direct'; tag='direct' })
        route=[ordered]@{ final='tunnel'; auto_detect_interface=$true; default_domain_resolver='local' }
    }
    if($parts.Endpoints.Count){ $cfg.endpoints=@($parts.Endpoints) }
    Write-JsonFile $p.Probe $cfg
    $proc=Start-Process -FilePath $p.Exe -ArgumentList @('run','-c',"`"$($p.Probe)`"") -WindowStyle Hidden -PassThru `
              -RedirectStandardError $p.ProbeLog -RedirectStandardOutput "$($p.ProbeLog).out"
    try {
        if(-not (Wait-LocalPort $script:TunnelProbePort 8000 $proc)){ return $fail }
        if((Invoke-TunnelTrace $script:TunnelProbePort 6000) -lt 0){ return $fail }
        $loc=$script:TunnelExit['loc']
        $ping=Measure-TunnelPing $script:TunnelProbePort
        if($ping -lt 2){ $ping=Invoke-TunnelTrace $script:TunnelProbePort 6000 }
        if($ping -lt 0){ return [pscustomobject]@{ Ms=-1; Loc=$loc; Geo=[ordered]@{} } }
        return [pscustomobject]@{ Ms=$ping; Loc=$loc; Geo=(Get-GeoCheck $script:TunnelProbePort) }
    } finally {
        if(-not $proc.HasExited){ Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        $proc.WaitForExit(3000) | Out-Null
        if($xproc -and -not $xproc.HasExited){ Stop-Process -Id $xproc.Id -Force -ErrorAction SilentlyContinue }
    }
}

function Select-TunnelProfile {
    # Проверяет все профили и выбирает лучший: сначала тот, с которого
    # открывается больше сайтов из списка региональных ограничений, затем
    # зарубежный выход, затем наименьшая задержка. Снимает ручное закрепление.
    param([string[]]$Skip=@(),[switch]$NoAutostart)
    Initialize-TunnelDirs
    $p=Get-TunnelPaths
    $null=Merge-ListFile $p.Geo $script:SeedGeo
    $profiles=@(Get-TunnelProfiles)
    if(-not $profiles.Count){
        Set-TunnelError 'Нет ни одного профиля: импортируйте конфиг Proton VPN Free или своего сервера.'
        return $null
    }
    $wasRunning=(Get-TunnelStatus).Running
    Stop-Tunnel -Quiet
    $results=New-Object System.Collections.Generic.List[object]
    $lastFail=@()
    Write-Host '  Проверка профилей туннеля...' -ForegroundColor Yellow
    foreach($pr in $profiles){
        if($Skip -contains $pr.name){ continue }
        $shown=$pr.name; if($shown.Length -gt 40){ $shown=$shown.Substring(0,40) }
        Write-Host ("    {0,-40} " -f $shown) -NoNewline
        $r=Test-TunnelProfile $pr
        if($r.Ms -ge 0){
            $results.Add([pscustomobject]@{ name=$pr.name; ms=[int]$r.Ms; loc="$($r.Loc)"; ru=[int]("$($r.Loc)" -eq 'RU'); geo=$r.Geo; geo_ok=[int](Get-GeoScore $r.Geo) })
            $gs=Get-GeoSummary $r.Geo
            Write-Host ("{0} мс, выход: {1}{2}{3}" -f $r.Ms,$r.Loc,$(if("$($r.Loc)" -eq 'RU'){' (Россия!)'}else{''}),$(if($gs){", $gs"}else{''})) -ForegroundColor Green
        } else {
            Write-Host 'нет ответа' -ForegroundColor DarkGray
            $lastFail=@("Профиль '$($pr.name)': $($script:TunnelTraceLast)")+@(Get-FileTail $p.ProbeLog 6)
        }
    }
    # Доступ к сайтам с региональными ограничениями важнее всего, затем
    # зарубежный выход, затем скорость.
    $ranked=@($results | Sort-Object @{Expression='geo_ok';Descending=$true},@{Expression='ru'},@{Expression='ms'})
    if(-not $ranked.Count){
        Set-TunnelError 'Ни один профиль туннеля не ответил.' $lastFail
        Write-Host '  Сервер недоступен или его протокол блокируется провайдером.' -ForegroundColor Yellow
        Write-Host '  Попробуйте при запущенном zapret, другой сервер или другой протокол.' -ForegroundColor DarkGray
        return $null
    }
    $best=$ranked[0]
    Write-JsonFile $p.State ([ordered]@{ active=$best.name; pinned=$false; ranked=@($ranked); tested=(Get-Date).ToString('s') })
    Clear-TunnelError
    $gs=Get-GeoSummary $best.geo
    Write-Host ("  Лучший профиль: {0} (задержка {1} мс, выход: {2}{3})" -f $best.name,$best.ms,$best.loc,$(if($gs){", $gs"}else{''})) -ForegroundColor Green
    if(@(Get-GeoPairs $best.geo).Count -gt $best.geo_ok){
        Write-Host '  ! Ни с одного профиля не открываются все сайты из списка региональных ограничений.' -ForegroundColor Yellow
    }
    if(-not $NoAutostart){
        if($wasRunning -or ((Get-TunnelStatus).Enabled -and (Get-Status).Running)){ Start-Tunnel }
        elseif((Get-TunnelStatus).Enabled){ Write-Host '  Туннель запустится вместе с обходом (пункт [2] главного меню).' -ForegroundColor DarkGray }
        else { Write-Host '  Туннель выключен: включите его в меню туннеля, пункт [1].' -ForegroundColor DarkGray }
    }
    return $best.name
}

function Use-TunnelProfile {
    # Ручной выбор: номер или имя профиля закрепляет его (автовыбор его не
    # сменит); 'auto' снимает закрепление и выбирает лучший заново.
    param([string]$Ref)
    Ensure-Admin
    $Ref="$Ref".Trim()
    if($Ref -ieq 'auto' -or $Ref -ieq 'авто'){ return (Select-TunnelProfile) }
    $profiles=@(Get-TunnelProfiles)
    $prof=$null; $idx=0
    if([int]::TryParse($Ref,[ref]$idx) -and $idx -ge 1 -and $idx -le $profiles.Count){ $prof=$profiles[$idx-1] }
    if(-not $prof){ $prof=$profiles | Where-Object { $_.name -eq $Ref } | Select-Object -First 1 }
    if(-not $prof -and $Ref){ $prof=$profiles | Where-Object { $_.name.ToLowerInvariant().Contains($Ref.ToLowerInvariant()) } | Select-Object -First 1 }
    if(-not $prof){ throw "профиль не найден: $Ref" }
    $p=Get-TunnelPaths
    $old=Read-JsonFile $p.State
    $wasRunning=(Get-TunnelStatus).Running
    $st=[ordered]@{ active=$prof.name; pinned=$true }
    if($old -and $old.ranked){ $st.ranked=@($old.ranked); $st.tested=$old.tested }
    Write-JsonFile $p.State $st
    Write-Host "  Выбран профиль '$($prof.name)'. Он закреплён: автовыбор его не сменит." -ForegroundColor Green
    if($wasRunning -or ((Get-TunnelStatus).Enabled -and (Get-Status).Running)){ Start-Tunnel }
    elseif(-not (Get-TunnelStatus).Enabled){ Write-Host '  Туннель выключен: включите его в меню туннеля, пункт [1].' -ForegroundColor DarkGray }
    return $prof.name
}

function Test-TunnelGeo {
    # Проверка сайтов с региональными ограничениями через работающий туннель.
    Initialize-TunnelDirs
    $p=Get-TunnelPaths
    $null=Merge-ListFile $p.Geo $script:SeedGeo
    if(-not (Get-TunnelStatus).Running){ Write-Host '  Туннель не запущен.' -ForegroundColor Red; return }
    Write-Host '  Проверка региональных ограничений через активный профиль...' -ForegroundColor Yellow
    $geo=Get-GeoCheck $script:TunnelMixedPort
    foreach($pair in (Get-GeoPairs $geo)){
        $good=($pair.Status -eq 'ok' -or $pair.Status -eq 'challenge')
        Write-Host ("    {0,-28} {1}" -f $pair.Site,$script:GeoLabel[$pair.Status]) -ForegroundColor $(if($good){'Green'}else{'Red'})
    }
    Write-Host "  Список сайтов: $($p.Geo) (можно править вручную)." -ForegroundColor DarkGray
}

# --- запуск и остановка --------------------------------------------------------

function Get-TunnelStarterProcess {
    # Фоновый запуск туннеля, если он ещё идёт.
    # PID мог быть переиспят другой программой после перезагрузки -
    # стартёр обязательно powershell/pwsh, иначе файл устарел.
    $p=Get-TunnelPaths
    if(-not (Test-Path $p.StarterPid)){ return $null }
    try {
        $pr=Get-Process -Id ([int](Get-Content $p.StarterPid -Raw)) -ErrorAction Stop
        if($pr.ProcessName -notin @('powershell','pwsh')){ return $null }
        return $pr
    } catch { return $null }
}

function Get-TunnelStatus {
    $p=Get-TunnelPaths
    $proc=@(Get-ProcessByExe 'sing-box' $p.Exe)
    $st=Read-JsonFile $p.State
    $ex=Read-JsonFile $p.ExitInfo
    [pscustomobject]@{
        Enabled=(Test-Path $p.Enabled)
        Installed=(Test-Path $p.Exe) -or (Test-Path $p.Profiles)
        Running=[bool]$proc.Count
        Starting=[bool](Get-TunnelStarterProcess)
        Active=$(if($st){$st.active}else{$null})
        Pinned=[bool]($st -and $st.pinned)
        Loc=$(if($ex){$ex.loc}else{$null})
        Profiles=@(Get-TunnelProfiles).Count
        Domains=(Get-TunnelSitesSummary)
    }
}

function Find-TunnelProfile {
    param([string]$Name)
    foreach($pr in (Get-TunnelProfiles)){ if($pr.name -eq $Name){ return $pr } }
    return $null
}

function Start-TunnelProcess {
    <#
      Возвращает 'ok', 'crash' (sing-box завершился: ошибка конфига, TUN,
      прав) или 'notunnel' (sing-box работает, но трафик через сервер не идёт).
    #>
    param($Prof)
    $ErrorActionPreference='Continue'
    $p=Get-TunnelPaths
    Write-TunnelConfig $Prof
    $LASTEXITCODE=0
    $chk=& $p.Exe check -c $p.Config 2>&1
    if($LASTEXITCODE -ne 0){
        # Чистим ANSI-цвета sing-box: они не читаются в last-error.txt.
        Set-TunnelError 'Конфиг sing-box не прошёл проверку.' @($chk | ForEach-Object { "$_" -replace "$([char]27)\[[0-9;]*m",'' })
        return 'crash'
    }
    foreach($f in @($p.Log,$p.ErrLog)){ Remove-Item $f -Force -ErrorAction SilentlyContinue }
    if($Prof.engine -eq 'xray'){
        $xproc=$null
        try { $xproc=Start-XrayProcess $Prof $script:XrayPort $p.XrayConfig $p.XrayLog }
        catch { $script:TunnelTraceLast='xray-core: ' + $_.Exception.Message }
        if(-not $xproc){
            Set-TunnelError 'xray-core не запустился.' @($script:TunnelTraceLast)
            return 'crash'
        }
    }
    $proc=Start-Process -FilePath $p.Exe -ArgumentList @('run','-c',"`"$($p.Config)`"") -WorkingDirectory $p.Dir -WindowStyle Hidden -PassThru `
              -RedirectStandardError $p.ErrLog -RedirectStandardOutput "$($p.ErrLog).out"
    $null=$proc.Handle   # без этого ExitCode после завершения бывает пустым
    [IO.File]::WriteAllText($p.Pid,[string]$proc.Id,[Text.Encoding]::ASCII)
    # При первом запуске Windows создаёт адаптер Wintun - это бывает дольше
    # 10 секунд. Ждём, пока процесс жив, до 30 секунд.
    if(-not (Wait-LocalPort $script:TunnelMixedPort 30000 $proc)){
        $why=@(Get-FileTail $p.ErrLog 10) + @(Get-FileTail $p.Log 10)
        if($proc.HasExited){ Set-TunnelError ("sing-box завершился с кодом $($proc.ExitCode).") $why }
        else {
            Set-TunnelError 'sing-box не открыл локальный порт за 30 секунд.' $why
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
        return 'crash'
    }
    foreach($i in 1..3){
        if($proc.HasExited){ break }
        if((Invoke-TunnelTrace $script:TunnelMixedPort 6000) -ge 0){ Clear-TunnelError; return 'ok' }
        Start-Sleep -Seconds 1
    }
    if($proc.HasExited){
        Set-TunnelError ("sing-box завершился с кодом $($proc.ExitCode).") (@(Get-FileTail $p.ErrLog 10) + @(Get-FileTail $p.Log 10))
        return 'crash'
    }
    Set-TunnelError "Через профиль '$($Prof.name)' не идёт трафик." (@("Проверка туннеля: $($script:TunnelTraceLast)") + @(Get-FileTail $p.Log 8))
    return 'notunnel'
}

function Start-Tunnel {
    Ensure-Admin
    Initialize-TunnelDirs
    Remove-LegacyWarp
    $p=Get-TunnelPaths
    if(-not @(Get-TunnelProfiles).Count){
        Set-TunnelError 'Нет ни одного профиля: импортируйте конфиг Proton VPN Free или своего сервера.'
        return
    }
    try { if(-not (Test-Path $p.Exe)){ Install-SingBox } }
    catch {
        Set-TunnelError ($_.Exception.Message -split "`n")[0] @(($_.Exception.Message -split "`n") | Select-Object -Skip 1)
        return
    }
    Stop-Tunnel -Quiet
    Sync-GeoList      # список старше суток обновляется; задача на месте
    $st=Read-JsonFile $p.State
    $prof=$null
    if($st -and $st.active){ $prof=Find-TunnelProfile $st.active }
    if(-not $prof){
        $name=Select-TunnelProfile -NoAutostart
        if($name){ $prof=Find-TunnelProfile $name }
    }
    if(-not $prof){ return }
    Write-Host "  Запуск туннеля (профиль '$($prof.name)')..." -ForegroundColor Yellow
    $r=Start-TunnelProcess $prof
    if($r -eq 'notunnel' -and $st -and $st.pinned){
        Write-Host '  Профиль выбран вручную, поэтому на другой не переключаюсь. Автовыбор: меню туннеля, пункт [5].' -ForegroundColor Yellow
    } elseif($r -eq 'notunnel' -and @(Get-TunnelProfiles).Count -gt 1){
        Write-Host '  Профиль не отвечает, проверяю остальные...' -ForegroundColor Yellow
        Stop-Tunnel -Quiet
        $name=Select-TunnelProfile -Skip @($prof.name) -NoAutostart
        $prof=$(if($name){ Find-TunnelProfile $name } else { $null })
        $r=$(if($prof){ Start-TunnelProcess $prof } else { 'crash' })
    }
    if($r -ne 'ok'){
        Stop-Tunnel -Quiet
        Write-Host '  Туннель не запущен. Причина выше; она же в меню туннеля и в журналах:' -ForegroundColor Red
        Write-Host "    $($p.Log)" -ForegroundColor DarkGray
        Write-Host "    $($p.ErrLog)" -ForegroundColor DarkGray
        return
    }
    Set-TunnelDns
    Write-Host "  Туннель работает: '$($prof.name)'. Сайтов в туннеле: $(Get-TunnelSitesSummary)" -ForegroundColor Green
    if($script:TunnelExit['loc']){
        Write-JsonFile $p.ExitInfo ([ordered]@{ loc=$script:TunnelExit['loc']; ip=$script:TunnelExit['ip'] })
        Write-Host "  Выход в интернет: страна $($script:TunnelExit['loc']), адрес $($script:TunnelExit['ip'])" -ForegroundColor DarkGray
        if($script:TunnelExit['loc'] -eq 'RU'){
            Write-Host '  ! Выход - в России: сервисы, которые сами не пускают из России, через туннель не откроются.' -ForegroundColor Yellow
        }
    }
    Test-TunnelDns
}

function Start-TunnelBackground {
    <#
      Туннель запускается следом за zapret, не задерживая сам обход: проверка
      идёт в отдельном скрытом процессе PowerShell. Ход запуска - в
      logs\tunnel-start.log.
    #>
    $p=Get-TunnelPaths
    if(Get-TunnelStarterProcess){ Write-Host '  Туннель уже запускается в фоне.' -ForegroundColor DarkGray; return }
    $l=Get-SelfLaunch @('-Action','TunnelStart')
    $proc=Start-Process -FilePath $l.File -ArgumentList $l.Args -WindowStyle Hidden -PassThru `
              -RedirectStandardOutput $p.StartLog -RedirectStandardError "$($p.StartLog).err"
    [IO.File]::WriteAllText($p.StarterPid,[string]$proc.Id,[Text.Encoding]::ASCII)
    Write-Host '  Туннель запускается в фоне - статус в меню [11].' -ForegroundColor DarkGray
}

function Invoke-TunnelStartAction {
    # Действие TunnelStart: запуск туннеля, если он включён (так его запускает обход).
    try { if((Get-TunnelStatus).Enabled){ Start-Tunnel } else { Write-Host 'Туннель выключен.' } }
    finally { Remove-Item (Get-TunnelPaths).StarterPid -Force -ErrorAction SilentlyContinue }
}

function Stop-Tunnel {
    param([switch]$Quiet)
    $p=Get-TunnelPaths
    # Остановка во время фонового запуска: прерываем и запуск. Себя не трогаем.
    $starter=Get-TunnelStarterProcess
    if($starter -and $starter.Id -ne $PID){
        Stop-Process -Id $starter.Id -Force -ErrorAction SilentlyContinue
        Remove-Item $p.StarterPid -Force -ErrorAction SilentlyContinue
    }
    for($i=0;$i -lt 10;$i++){
        $procs=@(Get-ProcessByExe 'sing-box' $p.Exe) + @(Get-ProcessByExe 'xray' $p.Xray)
        if(-not $procs.Count){ break }
        $procs | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 300
    }
    Remove-Item $p.Pid -Force -ErrorAction SilentlyContinue
    Remove-TunnelDns
    if(-not $Quiet){ Write-Host '  Туннель остановлен.' -ForegroundColor Yellow }
}

function Enable-Tunnel {
    Ensure-Admin
    Initialize-TunnelDirs
    Remove-LegacyWarp
    $p=Get-TunnelPaths
    if(-not (Test-Path $p.List)){ $null=Merge-ListFile $p.List $script:SeedTunnel }
    $null=Merge-ListFile $p.Geo $script:SeedGeo
    if(-not @(Get-TunnelProfiles).Count){
        Write-Host '  Сначала добавьте профиль: Proton VPN Free (пункт [2]) или свой сервер (пункт [3]).' -ForegroundColor Red
        return
    }
    [IO.File]::WriteAllText($p.Enabled,'1',[Text.Encoding]::ASCII)
    Sync-GeoList
    Start-Tunnel
    if((Get-TunnelStatus).Running){
        $a='y'
        if($Action -eq 'Menu'){ $a=Read-Host '  Проверить сайты из списков и трансляции Discord и перенести в туннель то, что не работает через zapret? (Y/n)' }
        if($a -notmatch '^\s*[nNнН]'){ Update-TunnelRoutes }
    }
}

function Disable-Tunnel {
    $p=Get-TunnelPaths
    Remove-Item $p.Enabled -Force -ErrorAction SilentlyContinue
    Stop-Tunnel
    Remove-GeoListTask
    & ipconfig.exe /flushdns | Out-Null
}

# --- распределение сайтов ------------------------------------------------------

function Test-HttpsBatch {
    <#
      Параллельная проверка https://<домен>/ . Успех - получен HTTP-ответ и
      прочитано 64 КБ тела (или оно кончилось раньше): так ловится и обрыв
      "16 КБ", а не только недоступность. Код ответа не важен.
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
    # перекроет DNS sing-box и домен не попадёт в туннель.
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

function Add-TunnelDomains {
    param([string[]]$Domains)
    Initialize-TunnelDirs
    $p=Get-TunnelPaths
    $null=Merge-ListFile $p.List $Domains
    Write-TunnelRules
    Remove-HostsDomains $Domains
    & ipconfig.exe /flushdns | Out-Null
}

function Test-DiscordProbeOne {
    <#
      Проверка медиасервера Discord так, как его видит трансляция: пакет
      определения IP (на него сервер отвечает без входа в аккаунт), затем ~3 с
      потока по 1000 байт, затем снова пакет определения IP.
      'ok' - ответ есть и в начале, и после потока; 'blocked' - ответ только в
      начале (соединение обрезается, как у трансляций); $null - сервер не ответил.
    #>
    param([string]$Ip,[int]$Port)
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    $disc=New-Object byte[] 74
    $disc[1]=1; $disc[3]=70
    $ssrc=New-Object byte[] 4; $rng.GetBytes($ssrc); [Array]::Copy($ssrc,0,$disc,4,4)
    $u=New-Object Net.Sockets.UdpClient
    try {
        $u.Client.ReceiveTimeout=1500
        $u.Connect($Ip,$Port)
        $ask={
            param($tries)
            for($i=0;$i -lt $tries;$i++){
                try {
                    [void]$u.Send($disc,$disc.Length)
                    $ep=New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
                    [void]$u.Receive([ref]$ep)
                    return $true
                } catch {}
            }
            return $false
        }
        if(-not (& $ask 2)){ return $null }
        $buf=New-Object byte[] 1000
        for($i=0;$i -lt 300;$i++){
            $rng.GetBytes($buf)
            try { [void]$u.Send($buf,$buf.Length) } catch {}
            Start-Sleep -Milliseconds 10
        }
        if(& $ask 3){ return 'ok' }
        return 'blocked'
    } catch { return $null }
    finally { $u.Close() }
}

function Test-DiscordStreamProbe {
    <#
      Может ли zapret обеспечить трансляции Discord: 'ok', 'blocked' или $null
      (проверить не удалось). Проверка идёт напрямую, мимо туннеля: если адреса
      Discord уже направлены в туннель, на время проверки для сервера проверки
      ставится маршрут /32 через основной шлюз (он точнее маршрута туннеля).
    #>
    $p=Get-TunnelPaths
    $gw=$null
    if((Test-Path -LiteralPath $p.DiscordMedia) -and (Get-TunnelStatus).Running){
        $gw=Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -ne $script:TunnelIf } |
            Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric } | Select-Object -First 1
    }
    $results=@()
    foreach($srv in $script:DiscordProbeServers){
        $ip=$srv[0]; $added=$false
        if($gw){
            try {
                New-NetRoute -DestinationPrefix "$ip/32" -InterfaceIndex $gw.ifIndex -NextHop $gw.NextHop -RouteMetric 0 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
                $added=$true
            } catch {}
        }
        try { $results+=,(Test-DiscordProbeOne -Ip $ip -Port $srv[1]) }
        finally {
            if($added){ Remove-NetRoute -DestinationPrefix "$ip/32" -InterfaceIndex $gw.ifIndex -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue }
        }
    }
    if($results -contains 'blocked'){ return 'blocked' }
    if($results -contains 'ok'){ return 'ok' }
    return $null
}

function Test-DiscordStreams {
    # Итог проверки трансляций Discord; при необходимости - UDP Discord в туннель.
    $p=Get-TunnelPaths
    Write-Host '  Проверка трансляций Discord через zapret...' -ForegroundColor Yellow
    if(-not (Get-Status).Running){
        Write-Host '  Трансляции Discord: не проверено - zapret не запущен.' -ForegroundColor Yellow
        return
    }
    $r=Test-DiscordStreamProbe
    if(-not $r){
        Write-Host '  Трансляции Discord: проверить не удалось - серверы проверки не ответили.' -ForegroundColor Yellow
        return
    }
    $on=Test-Path -LiteralPath $p.DiscordMedia
    if($r -eq 'ok'){
        if($on){
            Write-Host '  Трансляции Discord: zapret справляется. UDP к медиасерверам Discord по-прежнему идёт через туннель' -ForegroundColor Green
            Write-Host "  (вернуть напрямую: удалить $($p.DiscordMedia) и перезапустить туннель)." -ForegroundColor DarkGray
        } else {
            Write-Host '  Трансляции Discord: работают через zapret.' -ForegroundColor Green
        }
        return
    }
    if($on){
        Write-Host '  Трансляции Discord: zapret не справляется (сервер перестаёт отвечать через ~1 с);' -ForegroundColor DarkGray
        Write-Host '  UDP к медиасерверам Discord уже идёт через туннель.' -ForegroundColor DarkGray
        return
    }
    [IO.File]::WriteAllText($p.DiscordMedia,'auto',[Text.Encoding]::ASCII)
    Write-Host '  Трансляции Discord: zapret не справляется (сервер перестаёт отвечать через ~1 с).' -ForegroundColor Yellow
    Write-Host ("  Направляю UDP к медиасерверам Discord ({0}) в туннель; голос и сайты на этих адресах идут как раньше. Перезапуск туннеля..." -f ($script:DiscordMediaCidr4 -join ', ')) -ForegroundColor DarkGray
    Start-Tunnel
    Write-Host '  Начните трансляцию заново: уже идущая останется на прежнем пути.' -ForegroundColor DarkGray
}

function Update-TunnelRoutes {
    # "Туннель там, где не справляется zapret": сайты и трансляции Discord.
    Ensure-Admin
    if(-not (Get-TunnelStatus).Running){ Write-Host '  Туннель не запущен.' -ForegroundColor Red; return }
    Update-TunnelSites
    Write-Host ''
    Test-DiscordStreams
}

function Update-TunnelSites {
    <#
      Проверяем домены из списков zapret напрямую; не открывшиеся проверяем
      через туннель и, если там они работают, переносим в lists\tunnel.txt.
    #>
    $p=Get-TunnelPaths
    if(-not (Get-Status).Running){
        Write-Host '  Внимание: zapret не запущен - в туннель попадут и сайты, которые zapret открыл бы сам.' -ForegroundColor Yellow
    }
    $lists=Join-Path $script:TrustedRuntime 'lists'
    $inTunnel=@(Get-TunnelDomains)
    $excl=@(Get-ListEntries (Join-Path $lists 'exclude.txt'))
    $cands=@(@(Get-ListEntries (Join-Path $lists 'blocked.txt')) + @(Get-ListEntries (Join-Path $lists 'autohostlist.txt')) |
             Select-Object -Unique | Where-Object { $inTunnel -notcontains $_ -and $excl -notcontains $_ })
    if(-not $cands.Count){ Write-Host '  Нечего проверять.' -ForegroundColor DarkGray; return }
    Write-Host ("  Проверка {0} сайтов через zapret..." -f $cands.Count) -ForegroundColor Yellow
    $direct=Test-HttpsBatch -Domains $cands
    $failed=@($cands | Where-Object { -not $direct[$_] })
    if($failed.Count){
        # Вторая попытка: случайный сбой не должен навсегда увести сайт в туннель
        # (домены из списка туннеля zapret больше не обрабатывает).
        $again=Test-HttpsBatch -Domains $failed
        $failed=@($failed | Where-Object { -not $again[$_] })
    }
    Write-Host ("  Открываются через zapret: {0}, не открываются: {1}" -f ($cands.Count-$failed.Count),$failed.Count) -ForegroundColor DarkGray
    if(-not $failed.Count){ Write-Host '  Туннель не нужен ни одному сайту из списков.' -ForegroundColor Green; return }
    Write-Host '  Проверка неоткрывшихся через туннель...' -ForegroundColor Yellow
    $via=Test-HttpsBatch -Domains $failed -Proxy "http://127.0.0.1:$($script:TunnelMixedPort)"
    $move=@($failed | Where-Object { $via[$_] })
    $dead=@($failed | Where-Object { -not $via[$_] })
    if($move.Count){
        Add-TunnelDomains $move
        Write-Host ("  Перенесено в туннель: {0}" -f ($move -join ', ')) -ForegroundColor Green
        Start-Sleep -Seconds 1
        Test-TunnelDns
        Write-Host '  Перезапустите браузер: он помнит старые адреса сайтов. Если в браузере включён' -ForegroundColor DarkGray
        Write-Host '  "Безопасный DNS" (DNS через HTTPS), отключите его - иначе он обходит туннель.' -ForegroundColor DarkGray
    }
    if($dead.Count){
        Write-Host ("  Не открываются и через туннель (нет сайта на корне домена или сбой): {0}" -f ($dead -join ', ')) -ForegroundColor DarkGray
    }
    Write-Host "  Список туннеля: $($p.List) (можно править вручную)." -ForegroundColor DarkGray
}

function Test-TunnelSites {
    # Проверка сайтов из списка туннеля так, как их видит браузер (через DNS и TUN).
    param([string[]]$Domains=@())
    $p=Get-TunnelPaths
    if(-not (Get-TunnelStatus).Running){ Write-Host '  Туннель не запущен.' -ForegroundColor Red; return }
    # Внешний список большой - проверяем свой, а из внешнего берём несколько для примера.
    if(-not $Domains.Count){ $Domains=@(Get-ListEntries $p.List) + @(Get-GeoListEntries | Select-Object -First 5) }
    if(-not $Domains.Count){ Write-Host '  Список туннеля пуст.' -ForegroundColor DarkGray; return }
    Write-Host '  Проверка сайтов из списка туннеля (как в браузере)...' -ForegroundColor Yellow
    $res=Test-HttpsBatch -Domains $Domains
    foreach($d in $Domains){
        $ips=@()
        try { $ips=@(Resolve-DnsName -Name $d -Type A -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }) } catch {}
        $via=$(if(@($ips | Where-Object { $_.StartsWith($script:TunnelFake4Prefix) }).Count){'в туннель'}else{'МИМО туннеля'})
        if($res[$d]){ Write-Host ("    {0,-28} DNS {1,-13} открывается" -f $d,$via) -ForegroundColor Green }
        else { Write-Host ("    {0,-28} DNS {1,-13} НЕ открывается" -f $d,$via) -ForegroundColor Red }
    }
    $ex=Read-JsonFile $p.ExitInfo
    if($ex){ Write-Host "  Выход туннеля: страна $($ex.loc), адрес $($ex.ip)" -ForegroundColor DarkGray }
}

# --- меню -----------------------------------------------------------------------

function Show-TunnelProfiles {
    $profiles=@(Get-TunnelProfiles)
    if(-not $profiles.Count){ Write-Host '  Профилей нет.' -ForegroundColor DarkGray; return $profiles }
    $w=Get-TunnelStatus
    $st=Read-JsonFile (Get-TunnelPaths).State
    $i=0
    foreach($pr in $profiles){
        $i++
        $s=Get-ProfileServer $pr
        $src=$(if($pr.source -eq 'proton'){'Proton'}else{'свой'})
        $mark=''
        if($pr.name -eq $w.Active){ $mark=' <- активный' + $(if($w.Pinned){', выбран вручную'}else{''}) }
        $res=''
        if($st -and $st.ranked){
            $r=@($st.ranked) | Where-Object { $_.name -eq $pr.name } | Select-Object -First 1
            if($r){ $gs=Get-GeoSummary $r.geo; $res="  $($r.ms) мс, выход $($r.loc)" + $(if($gs){", $gs"}else{''}) }
            else { $res='  при проверке не ответил' }
        }
        Write-Host ("    [{0}] {1}  [{2}, {3}]  {4}:{5}{6}{7}" -f $i,$pr.name,$pr.type,$src,$s.Host,$s.Port,$res,$mark)
    }
    return $profiles
}

function Show-TunnelMenu {
    while($true){
        $w=Get-TunnelStatus
        Write-Host ''
        Write-Host ('  Туннель: ' + $(if($w.Enabled){'включён'}else{'выключен'}) + ' | ' +
                    $(if($w.Running){"работает, профиль '$($w.Active)'" + $(if($w.Pinned){' (выбран вручную)'}else{''})}elseif($w.Starting){'запускается...'}else{'не запущен'}) +
                    ' | профилей: ' + $w.Profiles + ' | сайтов: ' + $w.Domains +
                    $(if($w.Running -and $w.Loc){" | выход: $($w.Loc)"}else{''})) -ForegroundColor Cyan
        if($w.Enabled -and -not $w.Running -and -not $w.Starting){
            $le=Get-FileTail (Get-TunnelPaths).LastError 40
            if($le.Count){
                Write-Host '  Последняя ошибка:' -ForegroundColor Red
                $le | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            }
        }
        Write-Host ('  [1] ' + $(if($w.Enabled){'Выключить туннель'}else{'Включить туннель'}))
        Write-Host '  [2] Proton VPN Free: импортировать конфиг WireGuard'
        Write-Host '  [3] Свой сервер: импортировать конфиг, ссылку или подписку'
        Write-Host '  [4] Выбрать профиль вручную'
        Write-Host '  [5] Проверить профили и выбрать лучший автоматически'
        Write-Host '  [6] Проверить сайты и трансляции Discord; что не работает через zapret - в туннель'
        Write-Host '  [7] Добавить домен в туннель вручную'
        Write-Host '  [8] Проверить сайты из списка туннеля (как в браузере)'
        Write-Host '  [9] Профили: показать / удалить'
        Write-Host '  [10] Региональные ограничения: проверить сайты через активный профиль'
        Write-Host "  [11] Внешний список сайтов с региональными ограничениями: обновить сейчас ($(Get-GeoListStatus))"
        Write-Host ('  [12] Внешний список: ' + $(if(Test-GeoListEnabled){'выключить'}else{'включить'}))
        Write-Host '  [0] Назад'
        $choice=Read-Host '  Выбор'
        if($choice -eq '0'){ return }
        try {
        switch($choice){
            '1' { if($w.Enabled){ Disable-Tunnel } else { Enable-Tunnel } }
            '2' {
                Write-Host ''
                Write-Host '  Proton VPN Free - бесплатный тариф без ограничения трафика.' -ForegroundColor DarkGray
                Write-Host '    1. Зарегистрируйтесь на https://account.protonvpn.com (нужна почта).' -ForegroundColor DarkGray
                Write-Host '    2. Раздел "Downloads" -> "WireGuard configuration".' -ForegroundColor DarkGray
                Write-Host '    3. Платформа: Windows (или Router). Protocol: WireGuard.' -ForegroundColor DarkGray
                Write-Host '    4. Выберите бесплатный сервер (Free). Для Дальнего Востока ближе Япония (JP).' -ForegroundColor DarkGray
                Write-Host '    5. Нажмите "Create" и скачайте файл .conf.' -ForegroundColor DarkGray
                Write-Host '  Можно импортировать несколько файлов (разные страны) - скрипт выберет лучший.' -ForegroundColor DarkGray
                $v=Read-Host '  Путь к файлу .conf'
                if($v){ Import-TunnelProfiles -Text (Read-UserInput $v) -Source 'proton'; [void](Select-TunnelProfile) }
            }
            '3' {
                Write-Host ''
                Write-Host '  Свой сервер (VPS). Вставьте ссылку, путь к файлу или адрес подписки.' -ForegroundColor DarkGray
                Write-Host "  Поддерживается: $($script:SupportedFormats)." -ForegroundColor DarkGray
                $v=Read-Host '  Ссылка, путь к файлу или адрес подписки'
                if($v){ Import-TunnelProfiles -Text (Read-UserInput $v) -Source 'custom'; [void](Select-TunnelProfile) }
            }
            '4' {
                if(@(Show-TunnelProfiles).Count){
                    $n=(Read-Host '  Номер профиля (a - выбрать автоматически, Enter - отмена)').Trim()
                    if($n){ [void](Use-TunnelProfile $(if($n -ieq 'a' -or $n -ieq 'а'){'auto'}else{$n})) }
                }
            }
            '5' { [void](Select-TunnelProfile) }
            '6' { Update-TunnelRoutes }
            '10' { Test-TunnelGeo }
            '11' {
                Ensure-Admin
                if(Test-GeoListEnabled){ [void](Update-GeoList -Force) }
                else { Write-Host '  Внешний список выключен (пункт [12]).' -ForegroundColor DarkGray }
            }
            '12' { Switch-GeoList }
            '7' {
                $d=(Read-Host '  Домен (например, example.com)').Trim().ToLowerInvariant()
                if($d -match '^[a-z0-9.-]+\.[a-z0-9-]+$'){
                    Add-TunnelDomains @($d)
                    Write-Host "  $d добавлен в туннель." -ForegroundColor Green
                    if((Get-TunnelStatus).Running){ Start-Sleep -Seconds 1; Test-TunnelSites @($d) }
                } else { Write-Host '  Некорректный домен.' -ForegroundColor Red }
            }
            '8' { Test-TunnelSites }
            '9' {
                $profiles=@(Show-TunnelProfiles)
                if($profiles.Count){
                    $n=Read-Host '  Номер профиля для удаления (Enter - ничего не удалять)'
                    $idx=0
                    if([int]::TryParse($n,[ref]$idx) -and $idx -ge 1 -and $idx -le $profiles.Count){
                        $gone=$profiles[$idx-1]
                        $rest=@($profiles | Where-Object { $_.name -ne $gone.name })
                        Save-TunnelProfiles $rest
                        if((Get-TunnelStatus).Active -eq $gone.name){
                            Stop-Tunnel -Quiet
                            Remove-Item (Get-TunnelPaths).State -Force -ErrorAction SilentlyContinue
                        }
                        Write-LaunchConfig
                        Write-Host "  Профиль '$($gone.name)' удалён." -ForegroundColor Green
                    }
                }
            }
        }
        } catch {
            Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red
        }
    }
}

function Show-Menu {
    # Почти все пункты требуют прав администратора: запрашиваем их сразу, а
    # не на первом выбранном пункте (иначе выбор терялся бы при перезапуске).
    Ensure-Admin
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
        $w=Get-TunnelStatus
        if($w.Enabled -or $w.Installed){
            Write-Host ('  Туннель: ' + $(if($w.Running){"работает (профиль '$($w.Active)')"}elseif($w.Starting){'запускается...'}else{'не запущен'}) + ' | профилей: ' + $w.Profiles + ' | сайтов в туннеле: ' + $w.Domains)
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
        Write-Host '  [11] Туннель для сайтов, которые не открывает zapret (Proton VPN Free / свой сервер)'
        Write-Host ('  [12] Быстрый подбор стратегий (обрыв зависших соединений): ' + $(if(Test-CircularReset){'выключить'}else{'включить'}))
        Write-Host '  [0] Выход'
        $choice=Read-Host '  Выбор'
        try {
            switch($choice){
                '1' {Install-Runtime; Read-Host '  Нажмите Enter'}
                '2' {Toggle-Run; Read-Host '  Нажмите Enter'}
                '3' {Toggle-Autostart; Read-Host '  Нажмите Enter'}
                '4' {Diagnose; Read-Host '  Нажмите Enter'}
                '5' {Show-Check; Read-Host '  Нажмите Enter'}
                '6' {[void](Install-Dependencies -IncludeOptional); Read-Host '  Нажмите Enter'}
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
                '10' {Remove-All; Read-Host '  Нажмите Enter'}
                '11' {Show-TunnelMenu}
                '12' {Toggle-CircularReset; Read-Host '  Нажмите Enter'}
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

# Кэш ответов Resolve-DohName на время работы процесса: www.X -> X и
# повторные вызовы одного имени бьют в сеть один раз, а не на каждый домен.
$script:DohCache=@{}

function Resolve-DohName {
    <#
      Собирает A-записи домена со ВСЕХ DoH-провайдеров, а не с первого
      ответившего. Это принципиально: разные провайдеры и разные edge-узлы
      CDN отдают разные адреса, и среди них бывает мёртвый (типично для
      Meta/Instagram: 31.13.72.174 не работает, 57.145.12.34 работает).
      Если вернуть только первый ответ, рабочий адрес потеряется.

      Провайдеры опрашиваются ПАРАЛЛЕЛЬНО (HttpClient): последовательные
      Invoke-RestMethod с таймаутом 6 с каждый могли держать пользователя
      десятки секунд на один недоступный провайдер. Результат кэшируется.
    #>
    param([string]$Name,[int]$TimeoutSec=6,[switch]$FirstProviderOnly)
    $key=$Name.ToLowerInvariant()
    if($script:DohCache.ContainsKey($key)){ return @($script:DohCache[$key]) }

    Add-Type -AssemblyName System.Net.Http
    $proto=[Net.SecurityProtocolType]::Tls12
    try { $proto=$proto -bor [Net.SecurityProtocolType]'Tls13' } catch {}
    [Net.ServicePointManager]::SecurityProtocol=$proto

    $h=New-Object System.Net.Http.HttpClientHandler
    $h.UseProxy=$false
    $c=New-Object System.Net.Http.HttpClient($h)
    $c.Timeout=[TimeSpan]::FromSeconds([Math]::Max(2,$TimeoutSec))
    [void]$c.DefaultRequestHeaders.TryAddWithoutValidation('accept','application/dns-json')
    $tasks=@()
    foreach($p in $script:DohProviders){
        try {
            $sep=if($p -match '\?'){'&'}else{'?'}
            $tasks+=$c.GetStringAsync("$p${sep}name=$Name&type=A")
        } catch {}
    }
    $all=New-Object System.Collections.Generic.List[string]
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks,
            ([int]($TimeoutSec*1000)+500)) } catch {}
    foreach($t in $tasks){
        if($t.Status -ne 'RanToCompletion'){ continue }
        try {
            $r=$t.Result | ConvertFrom-Json
            foreach($ip in @($r.Answer | Where-Object { $_.type -eq 1 } |
                              ForEach-Object { $_.data } |
                              Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })){
                if(-not $all.Contains($ip)){ $all.Add($ip) }
            }
            if($FirstProviderOnly -and $all.Count){ break }
        } catch {}
    }
    $c.Dispose()
    $script:DohCache[$key]=@($all)
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
    $key="cname:" + $Name.ToLowerInvariant()
    if($script:DohCache.ContainsKey($key)){ return @($script:DohCache[$key]) }

    Add-Type -AssemblyName System.Net.Http
    $h=New-Object System.Net.Http.HttpClientHandler
    $h.UseProxy=$false
    $c=New-Object System.Net.Http.HttpClient($h)
    $c.Timeout=[TimeSpan]::FromSeconds([Math]::Max(2,$TimeoutSec))
    [void]$c.DefaultRequestHeaders.TryAddWithoutValidation('accept','application/dns-json')
    $tasks=@()
    foreach($p in $script:DohProviders){
        try {
            $sep=if($p -match '\?'){'&'}else{'?'}
            $tasks+=$c.GetStringAsync("$p${sep}name=$Name&type=CNAME")
        } catch {}
    }
    $out=@()
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks,
            ([int]($TimeoutSec*1000)+500)) } catch {}
    foreach($t in $tasks){
        if($t.Status -ne 'RanToCompletion'){ continue }
        try {
            $r=$t.Result | ConvertFrom-Json
            $cn=@($r.Answer | Where-Object { $_.type -eq 5 } |
                  ForEach-Object { $_.data -replace '\.$','' })
            if($cn.Count){ $out=$cn; break }
        } catch {}
    }
    $c.Dispose()
    $script:DohCache[$key]=@($out)
    return @($out)
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
    # IPv6: ::, ::1, link-local fe80::/10, ULA fc00::/7; многоадресные
    # 224/4 и зарезервированные 240/4, широковещательный 255.255.255.255.
    param([string]$IP)
    if($IP -match '^(0\.|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|22[3-9]\.|2[3-5]\d\.|255\.255\.255\.255)'){ return $true }
    if($IP -eq '::' -or $IP -eq '::1'){ return $true }
    if($IP -match '^fe[89ab][0-9a-f]:'){ return $true }      # fe80::/10 link-local
    if($IP -match '^f[cd][0-9a-f]{2}:'){ return $true }      # fc00::/7 ULA
    if($IP -match '^ff[0-9a-f]{2}:'){ return $true }         # ff00::/8 multicast
    return $false
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

function Test-SystemDnsBatch {
    <#
      То же, что Test-SystemDnsOk, но для всего списка сразу: адреса берутся
      у системного DNS по очереди (это быстро), а TLS-соединения с проверкой
      сертификата идут одновременно. Проверка ~170 имён занимает секунды, а
      не минуты. Возвращает множество доменов, которым пиннинг не нужен.
    #>
    param([string[]]$Domains,[int]$TimeoutMs=3000)
    $good=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $jobs=New-Object System.Collections.Generic.List[object]
    $proto=[Security.Authentication.SslProtocols]::Tls12
    try { $proto=$proto -bor [Security.Authentication.SslProtocols]'Tls13' } catch {}
    foreach($d in $Domains){
        $ips=@()
        try {
            $ips=@(Resolve-DnsName -Name $d -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop |
                   Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
        } catch { continue }
        if(-not $ips.Count){ continue }
        if(@($ips | Where-Object { Test-BogonIP $_ }).Count){ continue }
        foreach($ip in @($ips | Select-Object -First 2)){
            try {
                $tcp=[Net.Sockets.TcpClient]::new()
                $jobs.Add([pscustomobject]@{ Domain=$d; Tcp=$tcp; Ar=$tcp.BeginConnect($ip,443,$null,$null); Ssl=$null; Ar2=$null })
            } catch {}
        }
    }
    # 1) ждём TCP-соединения
    $sw=[Diagnostics.Stopwatch]::StartNew()
    while($sw.ElapsedMilliseconds -lt $TimeoutMs){
        if(-not @($jobs | Where-Object { -not $_.Ar.IsCompleted }).Count){ break }
        Start-Sleep -Milliseconds 50
    }
    # 2) начинаем TLS-рукопожатия на установленных соединениях
    foreach($j in $jobs){
        if(-not $j.Ar.IsCompleted){ continue }
        try {
            $j.Tcp.EndConnect($j.Ar)
            $j.Ssl=[Net.Security.SslStream]::new($j.Tcp.GetStream(),$false)
            $j.Ar2=$j.Ssl.BeginAuthenticateAsClient($j.Domain,$null,$proto,$false,$null,$null)
        } catch { $j.Ar2=$null }
    }
    $sw.Restart()
    while($sw.ElapsedMilliseconds -lt $TimeoutMs){
        if(-not @($jobs | Where-Object { $_.Ar2 -and -not $_.Ar2.IsCompleted }).Count){ break }
        Start-Sleep -Milliseconds 50
    }
    # 3) сертификат выдан на это имя - системный DNS отдаёт рабочий адрес
    foreach($j in $jobs){
        try {
            if($j.Ar2 -and $j.Ar2.IsCompleted){
                $j.Ssl.EndAuthenticateAsClient($j.Ar2)
                if($j.Ssl.IsAuthenticated){ [void]$good.Add($j.Domain) }
            }
        } catch {}
        try { if($j.Ssl){ $j.Ssl.Dispose() } } catch {}
        try { $j.Tcp.Dispose() } catch {}
    }
    return ,$good
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
    # Домены туннеля разрешает DNS sing-box; запись в hosts увела бы их мимо туннеля.
    $inWarp=@(Get-TunnelDomains)
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
    # Все домены разом: кому системный DNS уже отдаёт рабочий адрес.
    $sysGood=New-Object 'System.Collections.Generic.HashSet[string]'
    if($haveResolveDns){ $sysGood=Test-SystemDnsBatch -Domains $domains }
    $i=0
    foreach($d in $domains){
        $i++
        if(-not $Quiet){Write-Host ("    [{0}/{1}] {2,-34} " -f $i,$domains.Count,$d) -NoNewline}
        # Системный DNS честный и адрес рабочий - в hosts не пишем.
        if($sysGood.Contains($d)){
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
    [IO.File]::WriteAllLines($hf,$lines,(Get-HostsEncoding $lines))
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
function Get-HostsEncoding {
    <#
      Кодировка записи hosts: UTF-8 без BOM, если в строках есть что-то вне
      ASCII (пользовательские комментарии кириллицей), иначе ASCII. hosts
      целиком перезаписывается - неверная кодировка молча портит файл.
    #>
    param([System.Collections.Generic.List[string]]$Lines)
    foreach($l in $Lines){ if($l -match '[^\x00-\x7F]'){ return [Text.UTF8Encoding]::new($false) } }
    return [Text.Encoding]::ASCII
}
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
    [IO.File]::WriteAllLines($hf,$out,(Get-HostsEncoding $out))
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
    Write-Host '    - процессы winws2 и sing-box (туннель), если запущены' -ForegroundColor DarkGray
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
    Write-Host '  [1/5] Остановка winws2 и туннеля...' -ForegroundColor Yellow
    Stop-Zapret -Quiet

    # 2) задача автозапуска
    Write-Host '  [2/5] Удаление задач планировщика...' -ForegroundColor Yellow
    Remove-Autostart
    Remove-GeoListTask

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
    $tunDir=Join-Path $script:TrustedRuntime 'tunnel'
    $tunProc=@(Get-CimInstance Win32_Process -Filter "Name='sing-box.exe' OR Name='xray.exe'" -ErrorAction SilentlyContinue |
               Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($tunDir,[StringComparison]::OrdinalIgnoreCase) }).Count
    $nrpt=0
    try { $nrpt=@(Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Comment -eq $script:TunnelNrptComment }).Count } catch {}
    $task=[bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) -or
          [bool](Get-ScheduledTask -TaskName $script:GeoListTask -ErrorAction SilentlyContinue)
    $drv=[bool](Get-CimInstance Win32_SystemDriver -Filter "Name='WinDivert'" -ErrorAction SilentlyContinue)
    $dir=Test-Path (Join-Path $env:SystemRoot 'System32\Zapret2Windows')
    $hostsLeft=Remove-HostsEntries -CountOnly
    Write-Host ("    процесс winws2:        {0}" -f $(if($proc -eq 0){'удалён'}else{'ОСТАЛСЯ'})) -ForegroundColor $(if($proc -eq 0){'Green'}else{'Red'})
    Write-Host ("    процессы туннеля:      {0}" -f $(if($tunProc -eq 0){'удалены'}else{'ОСТАЛИСЬ'})) -ForegroundColor $(if($tunProc -eq 0){'Green'}else{'Red'})
    Write-Host ("    правила DNS туннеля:   {0}" -f $(if($nrpt -eq 0){'удалены'}else{'ОСТАЛИСЬ'})) -ForegroundColor $(if($nrpt -eq 0){'Green'}else{'Red'})
    Write-Host ("    задачи планировщика:   {0}" -f $(if(-not $task){'удалены'}else{'ОСТАЛИСЬ'})) -ForegroundColor $(if(-not $task){'Green'}else{'Red'})
    Write-Host ("    служба WinDivert:      {0}" -f $(if(-not $drv){'удалена'}else{'ОСТАЛАСЬ'})) -ForegroundColor $(if(-not $drv){'Green'}else{'Red'})
    Write-Host ("    каталог в System32:    {0}" -f $(if(-not $dir){'удалён'}else{'ОСТАЛСЯ'})) -ForegroundColor $(if(-not $dir){'Green'}else{'Red'})
    Write-Host ("    записи hosts:          {0}" -f $(if($hostsLeft -eq 0){'очищены'}else{"осталось $hostsLeft"})) -ForegroundColor $(if($hostsLeft -eq 0){'Green'}else{'Yellow'})
    Write-Host ''
    if($proc -eq 0 -and $tunProc -eq 0 -and $nrpt -eq 0 -and -not $task -and -not $drv -and -not $dir -and $hostsLeft -eq 0){
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
    'Deps' {[void](Install-Dependencies -IncludeOptional -Yes:$Force)}
    'DohHosts' {Update-DohHosts}
    'Update' {Update-Self -Force:$Force}
    'Uninstall' {Remove-All -KeepLogs:$KeepLogs -Force:$Force}
    'Purge' {Remove-All -KeepLogs:$KeepLogs -IncludeProject:$IncludeProject -Force:$Force}
    'TunnelOn' {Enable-Tunnel}
    'TunnelOff' {Disable-Tunnel}
    'TunnelImport' {
        Ensure-Admin
        $src=$TunnelConfig; if(-not $src){ $src=$TunnelLink }
        if(-not $src){ throw 'Укажите -TunnelConfig <файл> или -TunnelLink <ссылка>.' }
        Import-TunnelProfiles -Text (Read-UserInput $src) -Source $(if($Proton){'proton'}else{'custom'})
        [void](Select-TunnelProfile)
    }
    'TunnelSelect' {Ensure-Admin; [void](Select-TunnelProfile)}
    'TunnelUse' {
        if($TunnelProfile){ [void](Use-TunnelProfile $TunnelProfile) }
        else { [void](Show-TunnelProfiles); Write-Host '  Укажите -TunnelProfile <номер | имя | auto>.' -ForegroundColor DarkGray }
    }
    'TunnelGeo' {Test-TunnelGeo}
    'TunnelGeoList' {Ensure-Admin; [void](Update-GeoList -Force)}
    'TunnelGeoListAuto' {Ensure-Admin; [void](Update-GeoList)}
    'TunnelRoutes' {Update-TunnelRoutes}
    'TunnelTest' {Test-TunnelSites}
    'TunnelList' {[void](Show-TunnelProfiles)}
    'TunnelStart' {Ensure-Admin; Invoke-TunnelStartAction}
    'Menu' {Show-Menu}
}
# Действие выполнялось в отдельном окне с правами администратора: не даём
# ему закрыться, пока результат не прочитан.
if($Elevated -and $Action -ne 'Menu' -and $Action -ne 'TunnelStart' -and $Action -ne 'TunnelGeoListAuto' -and [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost'){
    Write-Host ''
    [void](Read-Host '  Нажмите Enter для выхода')
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
    # Фоновый запуск туннеля и задача автозапуска идут в скрытом окне: там
    # ждать Enter некому, процесс повис бы навсегда.
    if($Host.Name -eq 'ConsoleHost' -and [Environment]::UserInteractive -and $Action -ne 'TunnelStart' -and $Action -ne 'TunnelGeoListAuto' -and -not $NoAutostart){
        [void](Read-Host '  Нажмите Enter для выхода')
    }
    # Код 2 - ошибка уже показана и прочитана (лаунчер .cmd не ждёт Enter повторно).
    exit 2
}
