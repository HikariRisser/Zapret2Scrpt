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
        $l.Host | Should -Be '2001:db8::1'
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

Describe 'Merge-ListFile' {
    BeforeAll {
        $script:tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("z2test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'добавляет только недостающее, сохраняя порядок и комментарии' {
        $f = Join-Path $script:tmpDir 'list.txt'
        [IO.File]::WriteAllLines($f, @('# комментарий', 'a.example'))
        $added = Merge-ListFile $f @('a.example','b.example')
        $added | Should -Be 1
        $lines = Get-Content $f
        $lines.Count | Should -Be 3
        $lines[0] | Should -Be '# комментарий'
        $lines[2] | Should -Be 'b.example'
    }
    It 'создаёт файл, если его нет' {
        $f = Join-Path $script:tmpDir 'new.txt'
        $added = Merge-ListFile $f @('x.example')
        $added | Should -Be 1
        (Get-Content $f) | Should -Be 'x.example'
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
