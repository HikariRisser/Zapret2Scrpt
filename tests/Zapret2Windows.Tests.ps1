# Pester-тесты чистых функций Zapret2Windows.ps1.
#
# Запуск (Windows, из корня репозитория):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\run-pester.ps1
# В CI: см. .github/workflows/ci.yml, job windows, шаг "Pester".
#
# Скрипт dot-sourcится до финального try/switch (только определения и
# константы) - см. tools/run-pester.ps1.

Describe 'Compare-VersionString' {
    It 'численно сравнивает мажор/минор/патч' {
        Compare-VersionString '1.10.0' '1.9.9' | Should -Be 1
        Compare-VersionString '1.8.3' '1.8.4' | Should -Be (-1)
        Compare-VersionString '2.0' '2.0.0' | Should -Be 0
    }
    It 'не-версии сравниваются как строки (Ordinal)' {
        Compare-VersionString 'abc' 'abc' | Should -Be 0
        Compare-VersionString 'abc' 'zzz' | Should -Be (-1)
        # Нечисловая часть против численной: строковое сравнение, без исключения.
        [Math]::Abs((Compare-VersionString 'abc' '1.0')) | Should -Be 1
    }
}

Describe 'Get-ScriptVersionFromText' {
    It 'достаёт версию из маркера' {
        Get-ScriptVersionFromText "param()`r`n`$script:ScriptVersion='1.8.4'" | Should -Be '1.8.4'
    }
    It 'нет маркера - null' {
        Get-ScriptVersionFromText 'обычный текст' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AnyBase64' {
    It 'обычный base64' {
        ConvertFrom-AnyBase64 ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('user:pass'))) |
            Should -Be 'user:pass'
    }
    It 'url-safe без выравнивания' {
        ConvertFrom-AnyBase64 ('dXNlcjpwYXNz'.Replace('+','-').Replace('/','_')) |
            Should -Be 'user:pass'
    }
    It 'пробелы игнорируются' {
        ConvertFrom-AnyBase64 'dXN lcj pwY XNz' | Should -Be 'user:pass'
    }
}

Describe 'Test-BogonIP' {
    It 'публичные адреса - не bogon' {
        Test-BogonIP '142.250.185.78' | Should -BeFalse
        Test-BogonIP '2607:f8b0:4002:c00::71' | Should -BeFalse
    }
    It 'IPv4-заглушки и приватные сети' {
        Test-BogonIP '0.0.0.0' | Should -BeTrue
        Test-BogonIP '127.0.0.1' | Should -BeTrue
        Test-BogonIP '10.1.2.3' | Should -BeTrue
        Test-BogonIP '192.168.1.1' | Should -BeTrue
        Test-BogonIP '172.16.0.1' | Should -BeTrue
        Test-BogonIP '169.254.1.1' | Should -BeTrue
        Test-BogonIP '100.64.0.1' | Should -BeTrue
        Test-BogonIP '223.255.255.1' | Should -BeTrue
    }
    It 'IPv6-заглушки' {
        Test-BogonIP '::' | Should -BeTrue
        Test-BogonIP '::1' | Should -BeTrue
        Test-BogonIP 'fe80::1' | Should -BeTrue
        Test-BogonIP 'fc00::1' | Should -BeTrue
        Test-BogonIP 'ff02::1' | Should -BeTrue
    }
}

Describe 'Split-ServerLink' {
    It 'vless с параметрами' {
        $l=Split-ServerLink 'vless://uuid@host.example:443?security=reality&sni=site.example#Name'
        $l.Host | Should -Be 'host.example'
        $l.Port | Should -Be 443
        $l.User | Should -Be 'uuid'
        $l.Q['security'] | Should -Be 'reality'
        $l.Name | Should -Be 'Name'
    }
    It 'ipv6-хост в скобках' {
        $l=Split-ServerLink 'trojan://pw@[2001:db8::1]:8443?security=tls#v6'
        # [uri] канонизирует IPv6 по-разному в .NET Framework и .NET 5+:
        # 5.1 -> полная форма, pwsh -> сжатая. Сравниваем по разобранному адресу.
        ([Net.IPAddress]::Parse($l.Host)).Equals([Net.IPAddress]::Parse('2001:db8::1')) | Should -BeTrue
        $l.Port | Should -Be 8443
    }
}

Describe 'Get-HostsEncoding' {
    It 'ascii-строки остаются ascii' {
        $l=[System.Collections.Generic.List[string]]@('127.0.0.1 localhost','# comment')
        (Get-HostsEncoding $l) | Should -BeOfType [Text.Encoding]
        (Get-HostsEncoding $l).WebName | Should -Be 'us-ascii'
    }
    It 'кириллица переключает на utf-8' {
        $l=[System.Collections.Generic.List[string]]@('# комментарий пользователя')
        (Get-HostsEncoding $l).WebName | Should -Be 'utf-8'
    }
}

Describe 'Write-HostsFile' {
    BeforeAll {
        $script:tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("z2test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'пишет строки и возвращает $true' {
        $f = Join-Path $script:tmpDir 'hosts'
        $lines = [System.Collections.Generic.List[string]]@('127.0.0.1 localhost', '# --- Zapret2Windows DoH begin ---', '1.2.3.4 example.com', '# --- Zapret2Windows DoH end ---')
        (Write-HostsFile -Path $f -Lines $lines) | Should -BeTrue
        ((Get-Content -LiteralPath $f) -join "`n") | Should -Be ($lines -join "`n")
    }
    It 'снимает атрибут "только чтение" и перезаписывает' {
        $f = Join-Path $script:tmpDir 'hosts-ro'
        [IO.File]::WriteAllLines($f, @('old line'), [Text.Encoding]::ASCII)
        (Get-Item -LiteralPath $f).IsReadOnly = $true
        $lines = [System.Collections.Generic.List[string]]@('1.2.3.4 example.com')
        (Write-HostsFile -Path $f -Lines $lines) | Should -BeTrue
        (Get-Item -LiteralPath $f).IsReadOnly | Should -BeFalse
        ((Get-Content -LiteralPath $f) -join "`n") | Should -Be '1.2.3.4 example.com'
    }
    It 'ascii-содержимое пишется без BOM' {
        $f = Join-Path $script:tmpDir 'hosts-ascii'
        [void](Write-HostsFile -Path $f -Lines ([System.Collections.Generic.List[string]]@('1.2.3.4 example.com')))
        $bytes = [IO.File]::ReadAllBytes($f)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }
}

Describe 'Merge-ListFile' {
    BeforeAll {
        $script:tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("z2test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
        $script:utf8Bom = New-Object Text.UTF8Encoding $true
        # cp1251 нужен тестам явно: системная ANSI на UTF-8-раннере тоже UTF-8.
        $script:cp1251 = [Text.Encoding]::GetEncoding(1251)
    }
    AfterAll {
        Remove-Item $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'добавляет только недостающее, сохраняя порядок и комментарии' {
        $f = Join-Path $script:tmpDir 'list.txt'
        # Кодировка задаётся явно: WriteAllLines без неё в PS 5.1 пишет UTF-8
        # без BOM, а Get-Content без BOM читает как ANSI (cp1251).
        [IO.File]::WriteAllLines($f, @('# комментарий', 'a.example'), $script:utf8Bom)
        $added = Merge-ListFile $f @('a.example','b.example')
        $added | Should -Be 1
        $lines = @(Read-TextLinesAuto $f)
        $lines.Count | Should -Be 3
        $lines[0] | Should -Be '# комментарий'
        $lines[2] | Should -Be 'b.example'
    }
    It 'кириллица в ANSI-файле не мешает распознать дубликат' {
        # Регрессия: ReadAllLines на ANSI-файле давал мусор, и кириллический
        # комментарий ломал распознавание соседних строк.
        # FallbackAnsi задаётся явно: на windows-2025 с UTF-8-локалом
        # системная ANSI тоже UTF-8, и тест проверял бы не cp1251.
        $f = Join-Path $script:tmpDir 'ansi.txt'
        [IO.File]::WriteAllText($f, "# комментарий`r`na.example`r`n", $script:cp1251)
        $added = Merge-ListFile $f @('a.example','b.example')
        $added | Should -Be 1
        $lines = @(Read-TextLinesAuto $f -FallbackAnsi $script:cp1251)
        $lines[-1] | Should -Be 'b.example'
        # Опорные ASCII-строки не пострадали от чтения кириллицы.
        $lines | Should -Contain 'a.example'
    }
    It 'создаёт файл, если его нет' {
        $f = Join-Path $script:tmpDir 'new.txt'
        $added = Merge-ListFile $f @('x.example')
        $added | Should -Be 1
        (Read-TextLinesAuto $f) | Should -Be 'x.example'
    }
}

Describe 'Read-TextLinesAuto' {
    BeforeAll {
        $script:tmpDir2 = Join-Path ([IO.Path]::GetTempPath()) ("z2enc-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpDir2 -Force | Out-Null
        # Хелпер принимает декодер кодировки чтения: cp1251, если системная
        # ANSI не UTF-8, иначе cp1251 всё равно (это самый частый случай
        # на русской Windows и проверяется детерминированно).
        $script:cp1251 = [Text.Encoding]::GetEncoding(1251)
    }
    AfterAll {
        Remove-Item $script:tmpDir2 -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'UTF-8 с BOM' {
        $f = Join-Path $script:tmpDir2 'bom.txt'
        [IO.File]::WriteAllText($f, "# кириллица`r`nx.example`r`n", (New-Object Text.UTF8Encoding $true))
        $l = @(Read-TextLinesAuto $f)
        $l.Count | Should -Be 2
        $l[0] | Should -Be '# кириллица'
    }
    It 'UTF-8 без BOM' {
        $f = Join-Path $script:tmpDir2 'nobom.txt'
        [IO.File]::WriteAllText($f, "# кириллица`nx.example`n", (New-Object Text.UTF8Encoding $false))
        $l = @(Read-TextLinesAuto $f)
        $l[0] | Should -Be '# кириллица'
        $l.Count | Should -Be 2
    }
    It 'UTF-16 LE с BOM' {
        $f = Join-Path $script:tmpDir2 'u16.txt'
        [IO.File]::WriteAllText($f, "# кириллица`r`nx.example`r`n", [Text.Encoding]::Unicode)
        $l = @(Read-TextLinesAuto $f)
        $l[0] | Should -Be '# кириллица'
    }
    It 'ANSI cp1251 (не-UTF-8 байты)' {
        # Файл в cp1251 - невалидный UTF-8, значит должен уйти в ANSI-ветку.
        # FallbackAnsi задаётся явно: системная ANSI на UTF-8-раннере тоже UTF-8.
        $f = Join-Path $script:tmpDir2 'ansi.txt'
        [IO.File]::WriteAllText($f, "# кириллица`r`nx.example`r`n", $script:cp1251)
        $l = @(Read-TextLinesAuto $f -FallbackAnsi $script:cp1251)
        $l[0] | Should -Be '# кириллица'
    }
    It 'пустой файл - пустой массив' {
        $f = Join-Path $script:tmpDir2 'empty.txt'
        [IO.File]::WriteAllText($f, '', (New-Object Text.UTF8Encoding $false))
        @(Read-TextLinesAuto $f).Count | Should -Be 0
    }
}

Describe 'ACL: учётки задаются SID-ами, а не локализованными именами' {
    BeforeAll {
        $text = [IO.File]::ReadAllText($env:Z2_PS1_PATH)
        $m = [regex]::Match($text, '(?s)function Protect-Directory\s*\{.*?\n\}')
        $script:pdpBody = if ($m.Success) { $m.Value } else { '' }
    }
    It 'функция Protect-Directory найдена' {
        $script:pdpBody | Should -Not -BeNullOrEmpty
    }
    It 'grant-ы заданы через SID (*S-1-5-...)' {
        # Регрессия: icacls с именами 'Administrators'/'Users' падает на
        # русской/украинской Windows: "No mapping between account names and
        # security IDs was done" (имена встроенных групп локализованы).
        $script:pdpBody | Should -Match '\*S-1-5-18'
        $script:pdpBody | Should -Match '\*S-1-5-32-544'
        $script:pdpBody | Should -Match '\*S-1-5-32-545'
    }
    It 'в grant-ах нет английских имён групп' {
        # Ловим именно аргументы icacls вида 'Administrators:...' /
        # 'Users:...' - не упоминания в комментариях и не пути.
        $script:pdpBody | Should -Not -Match "'(SYSTEM|Administrators|Users):\(OI\)"
        $script:pdpBody | Should -Not -Match '"(SYSTEM|Administrators|Users):\(OI\)'
    }
}

Describe 'ACL: у ранее существовавших файлов не пустой DACL' {
    # Регрессия 1.8.7: icacls молча игнорирует grant с флагами наследования
    # (OI)(CI) на ФАЙЛЕ (код 0, ACE не добавляется), а /inheritance:r с /T
    # срезал унаследованные ACE. Результат: все файлы, существовавшие до
    # вызова Protect-Directory, оставались с ПУСТЫМ DACL - не могли читать
    # и писать даже администраторы ("Access to the path is denied").
    # Поведенческий тест: реально запускает icacls на временном каталоге.
    # Владелец временного каталога может выдавать любые ACE без прав
    # администратора (проверено), поэтому тест работает и в CI.
    BeforeAll {
        $script:aclDir = Join-Path ([IO.Path]::GetTempPath()) ("z2acl-" + [guid]::NewGuid().ToString('N'))
        $script:aclFile = Join-Path $script:aclDir 'lists\autohostlist.txt'
        New-Item -ItemType Directory -Path (Split-Path $script:aclFile) -Force | Out-Null
        [IO.File]::WriteAllText($script:aclFile, 'seed', (New-Object Text.UTF8Encoding $false))
        Protect-Directory $script:aclDir
    }
    AfterAll {
        Remove-Item $script:aclDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'у дочернего файла есть ACE-ы (не пустой DACL)' {
        @(Get-Acl $script:aclFile).Access.Count | Should -BeGreaterThan 0
    }
    It 'файл можно прочитать и перезаписать' {
        (Get-Content $script:aclFile -Raw).Trim() | Should -Be 'seed'
        [IO.File]::WriteAllText($script:aclFile, 'updated', (New-Object Text.UTF8Encoding $false))
        (Get-Content $script:aclFile -Raw).Trim() | Should -Be 'updated'
    }
    It 'у каталога нет унаследованных от родителя ACE-ов' {
        # /inheritance:r на каталоге: все его ACE должны быть собственными.
        @(Get-Acl $script:aclDir).Access | Where-Object { $_.IsInherited } | Should -BeNullOrEmpty
    }
    It 'файл наследует права от каталога (не от System32/родителя)' {
        @(Get-Acl $script:aclFile).Access | Where-Object { -not $_.IsInherited } | Should -BeNullOrEmpty
    }
}

Describe 'Закреплённые версии и SHA-256 (из файла скрипта)' {
    BeforeAll {
        # Переменные $script: области Pester не видны - читаем сам артефакт.
        $text = [IO.File]::ReadAllText($env:Z2_PS1_PATH)
        $m = [regex]::Match($text, "\`$script:XrayVersion\s*=\s*'([^']+)'")
        $script:z2Xray = if ($m.Success) { $m.Groups[1].Value } else { $null }
        $script:z2Hashes = @{}
        foreach ($hm in [regex]::Matches($text, "'([A-Za-z0-9._-]+\.zip)'\s*=\s*'([0-9a-f]{64})'")) {
            $script:z2Hashes[$hm.Groups[1].Value] = $hm.Groups[2].Value
        }
    }
    It 'версия xray закреплена' {
        $script:z2Xray | Should -Match '^v\d'
    }
    It 'хэши всех закреплённых артефактов - 64 hex-символа' {
        foreach($k in @('zapret2-v1.0.6.zip',
                        'sing-box-1.14.4-windows-amd64.zip',
                        'sing-box-1.14.4-windows-arm64.zip',
                        'sing-box-1.14.4-windows-386.zip',
                        'Xray-windows-64.zip',
                        'Xray-windows-32.zip',
                        'Xray-windows-arm64-v8a.zip')){
            $script:z2Hashes.ContainsKey($k) | Should -BeTrue -Because "нет хэша для $k"
            $script:z2Hashes[$k] | Should -Match '^[0-9a-f]{64}$'
        }
    }
}

Describe 'catch: имена типов резолвятся (регрессия 1.8.9)' {
    # 1.8.9 падала при любом запуске: catch [UnauthorizedAccessException],
    # [IOException] - короткое имя IOException не резолвится (его нет в
    # наборе автоматически доступных имён типов), и скрипт не запускался
    # вообще с "unable to find type [IOException]". Проверяем статически,
    # что каждый тип в catch-списке приводится к [type] без ошибок.
    BeforeAll {
        $text = [IO.File]::ReadAllText($env:Z2_PS1_PATH)
    }
    It 'все типы в catch [...] резолвятся' {
        # catch [T1],[T2] { - ловим список целиком, затем каждый тип в
        # скобках. Резолвим тем же приведением [type], каким пользуется
        # PowerShell: оно учитывает акселераторы и известные пространства
        # имён (Net.WebException, UnauthorizedAccessException), а
        # несуществующее имя (IOException) даёт ошибку. Регрессия 1.8.9:
        # неразрешимое имя в catch делает скрипт невыполнимым целиком.
        $bad = @()
        $clauses = [regex]::Matches($text, 'catch\s*((?:\[[^\]]+\]\s*)(?:,\s*\[[^\]]+\]\s*)*)')
        foreach ($m in $clauses) {
            foreach ($t in [regex]::Matches($m.Groups[1].Value, '\[([^\]]+)\]')) {
                $name = $t.Groups[1].Value.Trim()
                if (-not $name) { continue }
                try { $null = [type]$name } catch { $bad += $name }
            }
        }
        ($clauses.Count) | Should -BeGreaterThan 0 -Because 'в скрипте есть catch-блоки'
        $bad | Should -BeNullOrEmpty -Because ("не резолвятся типы в catch: " + ($bad -join ', '))
    }
    It 'короткое имя IOException само по себе не резолвится (фиксируем причину)' {
        { [type]'IOException' } | Should -Throw
    }
}

Describe 'Test-LaunchArgSafe (валидация параметров до UAC-перезапуска)' {
    It 'обычные пути проходят - включая кириллицу и буквы r/n' {
        # Регрессия: прежняя проверка '["`r`n]' в одинарных кавычках давала
        # класс из литеральных букв r и n, и пути C:\Users\...,
        # ...\zapret2-v1.0.6, D:\Проги\Запрет\... отвергались как опасные.
        Test-LaunchArgSafe 'C:\Users\hikari\Downloads\Zapret2Windows' | Should -BeTrue
        Test-LaunchArgSafe 'D:\Проги\Запрет\zapret2-v1.0.6' | Should -BeTrue
        Test-LaunchArgSafe 'E:\z2' | Should -BeTrue
        Test-LaunchArgSafe 'C:\Program Files\Zapret2Windows' | Should -BeTrue
    }
    It 'кириллица и пробелы в пути не мешают' {
        Test-LaunchArgSafe 'D:\Новая папка (2)\Запрет' | Should -BeTrue
    }
    It 'кавычка отклоняется' {
        Test-LaunchArgSafe 'C:"evil' | Should -BeFalse
        Test-LaunchArgSafe '"quoted path"' | Should -BeFalse
    }
    It 'переводы строк отклоняются' {
        Test-LaunchArgSafe "a`rb" | Should -BeFalse
        Test-LaunchArgSafe "a`nb" | Should -BeFalse
        Test-LaunchArgSafe "a`r`nb" | Should -BeFalse
    }
}

Describe 'Discord-медиа: паритет Linux и Windows' {
    BeforeAll {
        $ps1 = $env:Z2_PS1_PATH
        $sh  = Join-Path (Split-Path -Parent $ps1) 'zapret2-linux.sh'
        $script:winText = [IO.File]::ReadAllText($ps1)
        $script:shText  = [IO.File]::ReadAllText($sh)
        $mw = [regex]::Match($script:winText, '(?s)\$script:DiscordMediaCidr4=@\((.*?)\)')
        $ml = [regex]::Match($script:shText,  '(?s)DISCORD_MEDIA_CIDR4 = \[(.*?)\]')
        $script:winCidr = @([regex]::Matches($mw.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $script:linCidr = @([regex]::Matches($ml.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    }
    It 'списки подсетей совпадают (порядок не важен)' {
        $script:winCidr.Count | Should -BeGreaterThan 10
        (@($script:winCidr | Sort-Object) -join ',') | Should -Be (@($script:linCidr | Sort-Object) -join ',')
    }
    It 'подсети - корректный CIDR' {
        foreach ($c in $script:winCidr) { $c | Should -Match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' }
    }
    It 'диапазон портов медиа одинаков (sing-box port_range: a:b)' {
        $script:winText | Should -Match "'19294:19344','50000:50099'"
        $script:shText  | Should -Match 'DISCORD_MEDIA_PORTS = \[\(19294, 19344\), \(50000, 50099\)\]'
    }
}

Describe 'Автообучение туннеля: отбор доменов и перенос' {
    It 'перенос: не открылся напрямую дважды, но открылся через туннель' {
        $move = Select-LearnMove -Failed @('b.test','c.test','d.test') `
            -Via @{ 'b.test'=$true; 'c.test'=$false; 'd.test'=$true } `
            -Again @{ 'b.test'=$false; 'c.test'=$false; 'd.test'=$true }
        $move | Should -Be @('b.test')
    }
    It 'авто: домены, проверенные недавно, пропускаются' {
        $now = 1000000.0
        $checked = @{ 'old.test' = ($now - 100) }
        $c = Select-LearnCandidates -Candidates @('a.test','old.test') -Checked $checked -Now $now -RecheckSec 86400 -Max 60 -Auto
        $c | Should -Be @('a.test')
    }
    It 'авто: проверенные давно снова попадают в проверку' {
        $now = 1000000.0
        $checked = @{ 'old.test' = ($now - 90000) }
        $c = Select-LearnCandidates -Candidates @('old.test') -Checked $checked -Now $now -RecheckSec 86400 -Max 60 -Auto
        $c | Should -Be @('old.test')
    }
    It 'авто: не больше Max за запуск' {
        $c = Select-LearnCandidates -Candidates @('a','b','c','d') -Now 1000000.0 -RecheckSec 86400 -Max 2 -Auto
        @($c).Count | Should -Be 2
    }
    It 'ручной режим: все кандидаты, без учёта истории' {
        $checked = @{ 'a.test' = 999999.0 }
        $c = Select-LearnCandidates -Candidates @('a.test','b.test') -Checked $checked -Now 1000000.0 -RecheckSec 86400
        $c | Should -Be @('a.test','b.test')
    }
    It 'ожидание DNS: домен, не перешедший в туннель, возвращается по таймауту' {
        $left = Wait-TunnelDns -Domains @('nonexistent-zapret-test.invalid') -TimeoutSec 1
        $left | Should -Be @('nonexistent-zapret-test.invalid')
    }
}
