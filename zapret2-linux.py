#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Zapret2 Windows-style controller for Linux.

Системная DPI-десинхронизация через zapret2 (nfqws2 + nftables/iptables).
Перехват работает для всех приложений, а не только для браузера.

Это средство обхода DPI, а не VPN. Оно не создаёт маршрут в обход
IP/маршрутизационных блокировок: для них нужен внешний туннель/VPN.

Использование:
    sudo python3 zapret2-linux.py              # меню
    sudo python3 zapret2-linux.py --action install
    python3 zapret2-linux.py --help

Зависимости: Python 3.8+, curl или urllib (stdlib), nftables/iptables,
systemd (для автозапуска). Внешних Python-пакетов не требуется.
"""

import argparse
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from datetime import datetime

VERSION = "1.1.0"
UPDATE_REPO = "HikariRisser/Zapret2WinScrpt"
UPDATE_FILE = "zapret2-linux.py"
UPDATE_BRANCH = "main"

ZAPRET_VERSION = "v1.0.6"
ZAPRET_TARGET = "/opt/zapret2"
SERVICE_NAME = "zapret2win"
UNIT_PATH = f"/etc/systemd/system/{SERVICE_NAME}.service"
HOSTS_PATH = "/etc/hosts"
HOSTS_BACKUP = "/etc/hosts.zapret2win-backup"
MARK_BEGIN = "# --- Zapret2Win DoH begin ---"
MARK_END = "# --- Zapret2Win DoH end ---"

DOH_PROVIDERS = [
    "https://cloudflare-dns.com/dns-query",
    "https://dns.google/resolve",
    "https://dns.quad9.net/dns-query",
]

# Домены для DPI-обхода. Соответствует списку Windows-версии.
SEED_DOMAINS = [
    "discord.com", "discord.gg", "discordapp.com", "discordapp.net",
    "discord.media", "discordcdn.com",
    "rutracker.org", "youtube.com", "youtu.be", "googlevideo.com", "ytimg.com",
    "instagram.com", "facebook.com", "fbcdn.net", "fbsbx.com", "threads.net",
    "x.com", "twitter.com", "twimg.com", "t.me", "telegram.org", "telegram.me",
    "reddit.com", "redditstatic.com", "redd.it", "tiktok.com", "tiktokcdn.com",
    "github.com", "githubusercontent.com", "githubassets.com",
    "cloudflare.com", "cloudflare-dns.com",
    "medium.com", "soundcloud.com", "spotify.com", "twitch.tv", "ttvnw.net",
]

# ----------------------------------------------------------------------------
#  Цвета и вывод
# ----------------------------------------------------------------------------

class C:
    RESET = "\033[0m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    CYAN = "\033[36m"
    GRAY = "\033[90m"
    BOLD = "\033[1m"

    enabled = sys.stdout.isatty()


def _c(code, text):
    return f"{code}{text}{C.RESET}" if C.enabled else str(text)


def ok(msg):
    print(_c(C.GREEN, "  ✔ " + msg))


def warn(msg):
    print(_c(C.YELLOW, "  ! " + msg))


def err(msg):
    print(_c(C.RED, "  ✘ " + msg))


def info(msg):
    print(_c(C.GRAY, "    " + msg))


def head(msg):
    print(_c(C.CYAN, "  " + msg))


# ----------------------------------------------------------------------------
#  Запуск внешних команд
# ----------------------------------------------------------------------------

def run(cmd, check=False, capture=True, timeout=120):
    """Запускает команду списком (без shell). Возвращает (rc, out, err)."""
    try:
        p = subprocess.run(
            cmd,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            text=True,
            timeout=timeout,
        )
        out = (p.stdout or "").strip() if capture else ""
        errout = (p.stderr or "").strip() if capture else ""
        if check and p.returncode != 0:
            raise RuntimeError(
                f"команда завершилась с кодом {p.returncode}: {' '.join(cmd)}\n{errout}"
            )
        return p.returncode, out, errout
    except FileNotFoundError:
        if check:
            raise RuntimeError(f"команда не найдена: {cmd[0]}")
        return 127, "", f"not found: {cmd[0]}"
    except subprocess.TimeoutExpired:
        if check:
            raise RuntimeError(f"таймаут команды: {' '.join(cmd)}")
        return 124, "", "timeout"


def which(name):
    return shutil.which(name)


# ----------------------------------------------------------------------------
#  Права root
# ----------------------------------------------------------------------------

def is_root():
    return os.geteuid() == 0


def ensure_root(argv):
    """Перезапускает скрипт через sudo, если прав нет."""
    if is_root():
        return
    if not which("sudo"):
        print(_c(C.RED, "  Нужны права root, а sudo не найден."))
        print("  Запустите от root: sudo -i, затем повторите.")
        sys.exit(1)
    print(_c(C.YELLOW, "  Требуются права root — запрашиваю sudo..."))
    try:
        os.execvp("sudo", ["sudo", sys.executable] + argv)
    except OSError as e:
        print(_c(C.RED, f"  Не удалось запустить sudo: {e}"))
        sys.exit(1)


# ----------------------------------------------------------------------------
#  Архитектура и пути
# ----------------------------------------------------------------------------

ARCH_MAP = {
    "x86_64": "linux-x86_64",
    "amd64": "linux-x86_64",
    "aarch64": "linux-arm64",
    "arm64": "linux-arm64",
    "armv7l": "linux-arm",
    "armv6l": "linux-arm",
    "i686": "linux-x86",
    "i386": "linux-x86",
    "mips": "linux-mips",
    "mipsel": "linux-mipsel",
    "mips64": "linux-mips64",
    "ppc": "linux-ppc",
    "riscv64": "linux-riscv64",
}


def zapret_arch():
    machine = platform.machine().lower()
    return ARCH_MAP.get(machine)


def lua_dir():
    return os.path.join(ZAPRET_TARGET, "lua")


def ipset_dir():
    return os.path.join(ZAPRET_TARGET, "ipset")


def init_script():
    return os.path.join(ZAPRET_TARGET, "init.d", "sysv", "zapret2")


def config_path():
    return os.path.join(ZAPRET_TARGET, "config")


def nfqws2_path():
    return os.path.join(ZAPRET_TARGET, "nfq2", "nfqws2")


# ----------------------------------------------------------------------------
#  Процесс nfqws2 и состояние
# ----------------------------------------------------------------------------

def nfqws2_running():
    rc, out, _ = run(["pgrep", "-f", nfqws2_path()])
    return rc == 0 and bool(out.strip())


def service_enabled():
    rc, out, _ = run(["systemctl", "is-enabled", SERVICE_NAME])
    return rc == 0 and out.strip() == "enabled"


def runtime_installed():
    return os.path.isfile(nfqws2_path()) and os.path.isfile(init_script())


def learned_domains():
    path = os.path.join(ipset_dir(), "zapret-hosts-auto.txt")
    if not os.path.isfile(path):
        return []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return [ln.strip() for ln in f if ln.strip() and not ln.strip().startswith("#")]
    except OSError:
        return []


# ----------------------------------------------------------------------------
#  Скачивание
# ----------------------------------------------------------------------------

def http_get(url, timeout=30):
    req = urllib.request.Request(
        url, headers={"User-Agent": f"zapret2-linux/{VERSION}", "Accept": "*/*"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def download(url, dest, timeout=300):
    data = http_get(url, timeout=timeout)
    with open(dest, "wb") as f:
        f.write(data)
    return len(data)


def get_release():
    """Скачивает официальный релиз zapret2 и распаковывает в /opt/zapret2."""
    if runtime_installed():
        return
    arch = zapret_arch()
    if not arch:
        raise RuntimeError(
            f"архитектура {platform.machine()} не поддерживается сборками zapret2"
        )

    url = (
        f"https://github.com/bol-van/zapret2/releases/download/"
        f"{ZAPRET_VERSION}/zapret2-{ZAPRET_VERSION}.zip"
    )
    head(f"Скачивание zapret2 {ZAPRET_VERSION}...")
    info(url)

    tmpdir = tempfile.mkdtemp(prefix="zapret2-")
    zpath = os.path.join(tmpdir, "release.zip")
    try:
        size = download(url, zpath)
        info(f"загружено {size // 1024} КБ")
        head("Распаковка...")
        with zipfile.ZipFile(zpath) as z:
            z.extractall(tmpdir)

        # В архиве один каталог верхнего уровня.
        root = None
        for name in os.listdir(tmpdir):
            p = os.path.join(tmpdir, name)
            if os.path.isdir(p) and os.path.isdir(os.path.join(p, "binaries")):
                root = p
                break
        if not root:
            raise RuntimeError("в архиве не найден каталог с binaries")

        if os.path.isdir(ZAPRET_TARGET):
            shutil.rmtree(ZAPRET_TARGET)
        shutil.copytree(root, ZAPRET_TARGET)
        os.chmod(ZAPRET_TARGET, 0o755)

        # Python zipfile НЕ восстанавливает права из архива, поэтому все
        # скрипты и бинарники делаем исполняемыми явно. Без этого
        # init.d/sysv/zapret2 и create_ipset.sh не запустятся.
        for base, _dirs, files in os.walk(ZAPRET_TARGET):
            for name in files:
                p = os.path.join(base, name)
                if name.endswith(".sh") or name in ("zapret2", "nfqws2", "mdig", "ip2net"):
                    try:
                        os.chmod(p, 0o755)
                    except OSError:
                        pass

        # Бинарник nfqws2 в путь, который ожидает init-скрипт
        bin_dir = os.path.join(ZAPRET_TARGET, "binaries", arch)
        if not os.path.isdir(bin_dir):
            raise RuntimeError(f"в релизе нет сборки для {arch}")
        os.makedirs(os.path.join(ZAPRET_TARGET, "nfq2"), exist_ok=True)
        src = os.path.join(bin_dir, "nfqws2")
        dst = nfqws2_path()
        shutil.copy2(src, dst)
        os.chmod(dst, 0o755)

        for tool in ("mdig", "ip2net"):
            s = os.path.join(bin_dir, tool)
            if os.path.isfile(s):
                d = os.path.join(ZAPRET_TARGET, tool, tool)
                os.makedirs(os.path.dirname(d), exist_ok=True)
                shutil.copy2(s, d)
                os.chmod(d, 0o755)

        for sh in ("install_easy.sh", "blockcheck2.sh", "init.d/sysv/zapret2"):
            p = os.path.join(ZAPRET_TARGET, sh)
            if os.path.isfile(p):
                os.chmod(p, 0o755)

        # Проверка, что движок на месте и исполняем
        if not os.access(init_script(), os.X_OK):
            raise RuntimeError(f"init-скрипт не исполняем: {init_script()}")
        if not os.access(nfqws2_path(), os.X_OK):
            raise RuntimeError(f"nfqws2 не исполняем: {nfqws2_path()}")

        ok(f"Релиз установлен в {ZAPRET_TARGET}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


# ----------------------------------------------------------------------------
#  Конфигурация zapret2
# ----------------------------------------------------------------------------

def build_config():
    """
    Генерирует /opt/zapret2/config.

    MODE_FILTER=autohostlist включает <HOSTLIST> и автообучение доменов —
    аналог autohostlist из Windows-версии.
    UDP-порты включают медиа-диапазоны Discord и STUN (3478), иначе
    голосовой трафик не попадёт в перехват.
    """
    opt = "\n".join([
        "--filter-tcp=80 --filter-l7=http <HOSTLIST> --payload=http_req "
        "--lua-desync=fake:blob=fake_default_http:tcp_md5 "
        "--lua-desync=multisplit:pos=method+2 --new",

        "--filter-tcp=443 --filter-l7=tls <HOSTLIST> --payload=tls_client_hello "
        "--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=6 "
        "--lua-desync=multidisorder:pos=1,midsld --new",

        "--filter-udp=443 --filter-l7=quic <HOSTLIST> --payload=quic_initial "
        "--lua-desync=fake:blob=fake_default_quic:repeats=6 --new",

        "--filter-l7=stun,discord,wireguard "
        "--payload=stun,discord_ip_discovery,wireguard_initiation,wireguard_cookie "
        "--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2",
    ])

    return f"""# Сгенерировано zapret2-linux {VERSION}
# Ручные правки будут перезаписаны при обновлении среды.

NFQWS2_ENABLE=1
NFQWS2_PORTS_TCP=80,443
NFQWS2_PORTS_UDP=443,3478,50000-50099,19294-19344

NFQWS2_OPT="
{opt}
"

# Фильтрация по спискам доменов + автообучение
MODE_FILTER=autohostlist

AUTOHOSTLIST_FAIL_THRESHOLD=3
AUTOHOSTLIST_FAIL_TIME=60
AUTOHOSTLIST_RETRANS_THRESHOLD=3
AUTOHOSTLIST_RETRANS_RESET=1
AUTOHOSTLIST_RETRANS_MAXSEQ=32768
AUTOHOSTLIST_INCOMING_MAXSEQ=32768
AUTOHOSTLIST_UDP_IN=1
AUTOHOSTLIST_UDP_OUT=4

DISABLE_IPV6=1
FLOWOFFLOAD=donttouch
INIT_APPLY_FW=1
FILTER_TTL_EXPIRED_ICMP=1
"""


def seed_lists():
    """Создаёт списки доменов, не перезаписывая существующие."""
    os.makedirs(ipset_dir(), exist_ok=True)

    user_list = os.path.join(ipset_dir(), "zapret-hosts-user.txt")
    if not os.path.isfile(user_list):
        with open(user_list, "w", encoding="utf-8") as f:
            f.write("\n".join(SEED_DOMAINS) + "\n")
        info(f"создан список: {user_list}")

    exclude = os.path.join(ipset_dir(), "zapret-hosts-user-exclude.txt")
    if not os.path.isfile(exclude):
        with open(exclude, "w", encoding="utf-8") as f:
            f.write("localhost\nlocal\n")
        info(f"создан список исключений: {exclude}")

    auto = os.path.join(ipset_dir(), "zapret-hosts-auto.txt")
    if not os.path.isfile(auto):
        open(auto, "w", encoding="utf-8").close()


def write_config():
    with open(config_path(), "w", encoding="utf-8") as f:
        f.write(build_config())
    os.chmod(config_path(), 0o644)


def install_runtime():
    ensure_root(sys.argv)
    head("Установка среды zapret2")
    get_release()
    seed_lists()
    write_config()
    ok("Конфигурация записана")
    info(config_path())
    print()
    warn("Права: каталог принадлежит root, обычные пользователи только читают.")
    return True


# ----------------------------------------------------------------------------
#  Управление сервисом
# ----------------------------------------------------------------------------

def start_bypass():
    ensure_root(sys.argv)
    if not runtime_installed():
        raise RuntimeError("среда не установлена — сначала выполните установку (пункт 1)")
    if nfqws2_running():
        warn("Обход уже запущен")
        return

    head("Запуск системного обхода...")
    rc, out, errout = run([init_script(), "start"], timeout=120)
    time.sleep(2)
    if nfqws2_running():
        ok("Обход запущен, nfqws2 работает")
    else:
        raise RuntimeError(
            "nfqws2 не запустился.\n"
            + (errout or out or "нет вывода")
            + "\nПроверьте: systemctl status, dmesg, наличие nfnetlink_queue"
        )


def stop_bypass():
    ensure_root(sys.argv)
    if not runtime_installed():
        warn("Среда не установлена")
        return
    head("Остановка обхода...")
    run([init_script(), "stop"], timeout=120)
    time.sleep(1)
    if nfqws2_running():
        # Крайний случай: добиваем процесс и чистим правила
        run(["pkill", "-f", nfqws2_path()])
        time.sleep(1)
    ok("Обход остановлен")


def status_line():
    running = nfqws2_running()
    state = _c(C.GREEN, "работает") if running else _c(C.RED, "остановлен")
    enabled = "включён" if service_enabled() else "выключен"
    learned = len(learned_domains())
    print(f"  nfqws2: {state} | автозапуск: {enabled} | доменов: {learned}")


# ----------------------------------------------------------------------------
#  Автозапуск (systemd)
# ----------------------------------------------------------------------------

def unit_content():
    return f"""[Unit]
Description=Zapret2 Windows-style DPI desync ({SERVICE_NAME})
Documentation=https://github.com/bol-van/zapret2
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
Restart=no
TimeoutSec=30
IgnoreSIGPIPE=no
GuessMainPID=no
RemainAfterExit=no
ExecStart={init_script()} start
ExecStop={init_script()} stop

[Install]
WantedBy=multi-user.target
"""


def toggle_autostart():
    ensure_root(sys.argv)
    if not runtime_installed():
        raise RuntimeError("среда не установлена — сначала выполните установку (пункт 1)")

    if service_enabled():
        head("Выключение автозапуска...")
        run(["systemctl", "disable", SERVICE_NAME], timeout=60)
        ok("Автозапуск выключен")
        return

    head("Включение автозапуска...")
    with open(UNIT_PATH, "w", encoding="utf-8") as f:
        f.write(unit_content())
    os.chmod(UNIT_PATH, 0o644)
    rc, _, errout = run(["systemctl", "daemon-reload"], timeout=60)
    if rc != 0:
        raise RuntimeError(f"systemctl daemon-reload: {errout}")
    rc, _, errout = run(["systemctl", "enable", SERVICE_NAME], timeout=60)
    if rc != 0:
        raise RuntimeError(f"systemctl enable: {errout}")
    ok("Автозапуск включён")
    info(f"юнит: {UNIT_PATH}")


# ----------------------------------------------------------------------------
#  Требования и зависимости
# ----------------------------------------------------------------------------

def kernel_module_loaded(name):
    try:
        with open("/proc/modules", encoding="utf-8", errors="replace") as f:
            return any(ln.startswith(name + " ") for ln in f)
    except OSError:
        return False


def firewall_kind():
    if which("nft"):
        return "nftables"
    if which("iptables"):
        return "iptables"
    return None


def package_manager():
    for name, install in (
        ("apt-get", ["apt-get", "install", "-y"]),
        ("dnf", ["dnf", "install", "-y"]),
        ("yum", ["yum", "install", "-y"]),
        ("pacman", ["pacman", "-S", "--noconfirm"]),
        ("zypper", ["zypper", "install", "-y"]),
        ("apk", ["apk", "add"]),
    ):
        if which(name):
            return name, install
    return None, None


def requirements():
    """
    Возвращает список словарей:
      name, status (OK/WARN/FAIL), detail, required, fixable
    """
    res = []

    def add(name, status, detail, required=True, fixable=False):
        res.append({
            "name": name, "status": status, "detail": detail,
            "required": required, "fixable": fixable,
        })

    # Ядро Linux
    add("Linux", "OK", platform.release())

    # Архитектура
    arch = zapret_arch()
    if arch:
        add("Архитектура", "OK", f"{platform.machine()} → {arch}")
    else:
        add("Архитектура", "FAIL", f"{platform.machine()} не поддерживается сборками")

    # Python
    pv = platform.python_version()
    if sys.version_info >= (3, 8):
        add("Python", "OK", pv)
    else:
        add("Python", "FAIL", f"{pv} — нужен 3.8+")

    # root
    if is_root():
        add("Права root", "OK", "есть")
    else:
        add("Права root", "WARN", "нет — скрипт запросит sudo")

    # firewall
    fw = firewall_kind()
    if fw:
        add("Файрвол", "OK", fw)
    else:
        add("Файрвол", "FAIL", "нет nft/iptables — перехват невозможен", fixable=True)

    # модуль ядра
    if kernel_module_loaded("nfnetlink_queue"):
        add("Модуль nfnetlink_queue", "OK", "загружен")
    else:
        add("Модуль nfnetlink_queue", "WARN", "не загружен — загрузится при старте", fixable=True)

    # systemd
    if which("systemctl"):
        rc, out, _ = run(["systemctl", "--version"])
        ver = out.splitlines()[0] if out else "systemd"
        add("systemd", "OK", ver)
    else:
        add("systemd", "WARN", "нет — автозапуск недоступен", required=False)

    # среда zapret2
    if runtime_installed():
        add("Среда zapret2", "OK", ZAPRET_TARGET)
    else:
        add("Среда zapret2", "FAIL", "не установлена", fixable=True)

    # сеть для установки
    try:
        socket.create_connection(("api.github.com", 443), timeout=6).close()
        add("GitHub доступен", "OK", "api.github.com:443")
    except OSError as e:
        add("GitHub доступен", "WARN", f"нет связи ({e.__class__.__name__})")

    # место
    try:
        st = os.statvfs("/")
        free_mb = st.f_bavail * st.f_frsize // (1024 * 1024)
        if free_mb >= 100:
            add("Свободное место", "OK", f"{free_mb} МБ")
        else:
            add("Свободное место", "WARN", f"{free_mb} МБ — мало")
    except OSError:
        pass

    return res


def check_requirements():
    print()
    head("Проверка требований Zapret2 Linux")
    print()
    n_ok = n_warn = n_fail = 0
    for r in requirements():
        if r["status"] == "OK":
            n_ok += 1
            ok(f"{r['name']:<26} {r['detail']}")
        elif r["status"] == "WARN":
            n_warn += 1
            warn(f"{r['name']:<26} {r['detail']}")
        else:
            n_fail += 1
            suffix = " [можно установить автоматически]" if r["fixable"] else " [нужен ручной шаг]"
            err(f"{r['name']:<26} {r['detail']}{suffix}")

    print()
    total = f"успешно {n_ok}, предупреждений {n_warn}, ошибок {n_fail}"
    if n_fail:
        print(_c(C.RED, "  Итог: " + total))
        print(_c(C.YELLOW, "  Часть проблем исправляется пунктом [6]."))
    elif n_warn:
        print(_c(C.YELLOW, "  Итог: " + total))
    else:
        print(_c(C.GREEN, "  Итог: " + total + " — всё готово."))
    print()


def install_dependencies(assume_yes=False):
    ensure_root(sys.argv)
    print()
    head("Установка зависимостей")
    print()

    todo = []
    if not firewall_kind():
        todo.append("firewall")
    if not kernel_module_loaded("nfnetlink_queue"):
        todo.append("module")
    if not runtime_installed():
        todo.append("runtime")

    if not todo:
        ok("Все зависимости уже на месте.")
        print()
        return True

    for t in todo:
        info({"firewall": "нет nftables/iptables",
              "module": "не загружен модуль nfnetlink_queue",
              "runtime": "среда zapret2 не установлена"}[t])
    print()

    if not assume_yes:
        try:
            ans = input("  Установить автоматически? (y/N) ").strip().lower()
        except EOFError:
            ans = ""
        if ans not in ("y", "yes", "д", "да"):
            warn("Отменено")
            print()
            return False

    success = True

    if "firewall" in todo:
        pm_name, pm_cmd = package_manager()
        if not pm_cmd:
            err("Не найден менеджер пакетов — установите nftables вручную")
            success = False
        else:
            head(f"Установка nftables через {pm_name}...")
            rc, out, errout = run(pm_cmd + ["nftables"], timeout=600)
            if rc != 0:
                # На Debian пакет называется nftables, на некоторых — nft
                rc, out, errout = run(pm_cmd + ["nft"], timeout=600)
            if firewall_kind():
                ok("Файрвол установлен")
            else:
                err(f"Не удалось установить: {errout[:300]}")
                success = False

    if "module" in todo:
        head("Загрузка модуля nfnetlink_queue...")
        rc, _, _ = run(["modprobe", "nfnetlink_queue"])
        if rc == 0 and kernel_module_loaded("nfnetlink_queue"):
            ok("Модуль загружен")
        else:
            warn("modprobe не сработал — обычно загружается при первом обращении к NFQUEUE")

    if "runtime" in todo:
        try:
            install_runtime()
        except Exception as e:
            err(str(e))
            success = False

    print()
    return success


# ----------------------------------------------------------------------------
#  DoH: разрешение имён с проверкой рабочего IP
# ----------------------------------------------------------------------------

def doh_query(name, rtype="A", timeout=6):
    """Запрашивает все DoH-провайдеры и объединяет ответы."""
    found = []
    for provider in DOH_PROVIDERS:
        sep = "&" if "?" in provider else "?"
        url = f"{provider}{sep}name={name}&type={rtype}"
        try:
            raw = http_get(url, timeout=timeout)
            data = json.loads(raw.decode("utf-8", errors="replace"))
        except Exception:
            continue
        for ans in data.get("Answer", []) or []:
            if ans.get("type") != (1 if rtype == "A" else 5):
                continue
            val = str(ans.get("data", "")).strip()
            if rtype == "A":
                if re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", val) and val not in found:
                    found.append(val)
            else:
                val = val.rstrip(".")
                if val and val not in found:
                    found.append(val)
    return found


def tcp_ok(ip, port=443, timeout=1.5):
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


def working_ip(domain, max_candidates=8):
    """
    Возвращает первый РАБОЧИЙ IP домена или None.

    DoH часто отдаёт мёртвый edge-адрес (типично для Meta/Instagram),
    поэтому кандидаты проверяются реальным TCP-соединением на 443.
    """
    cands = []

    def add_all(items):
        for it in items:
            if it and it not in cands:
                cands.append(it)

    add_all(doh_query(domain, "A"))

    for cname in doh_query(domain, "CNAME"):
        add_all(doh_query(cname, "A"))

    if domain.startswith("www."):
        add_all(doh_query(domain[4:], "A"))

    for ip in cands[:max_candidates]:
        if tcp_ok(ip):
            return ip
    return None


def flush_dns():
    for cmd in (
        ["resolvectl", "flush-caches"],
        ["systemd-resolve", "--flush-caches"],
        ["nscd", "-i", "hosts"],
    ):
        if which(cmd[0]):
            rc, _, _ = run(cmd, timeout=15)
            if rc == 0:
                info(f"кэш DNS сброшен ({cmd[0]})")
                return


def read_hosts():
    try:
        with open(HOSTS_PATH, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except OSError as e:
        raise RuntimeError(f"не удалось прочитать {HOSTS_PATH}: {e}")


def strip_marked_block(lines):
    """Удаляет только размеченные блоки (наш и прежней версии проекта)."""
    out = []
    skip = False
    removed = 0
    begin_re = re.compile(r"^\s*#\s*-+\s*Zapret2(?:Windows|Win)?\s*(?:TUI)?\s*DoH\s*begin\s*-+", re.I)
    end_re = re.compile(r"^\s*#\s*-+\s*Zapret2(?:Windows|Win)?\s*(?:TUI)?\s*DoH\s*end\s*-+", re.I)
    for ln in lines:
        if begin_re.match(ln):
            skip = True
            removed += 1
            continue
        if end_re.match(ln):
            skip = False
            removed += 1
            continue
        if skip:
            removed += 1
            continue
        out.append(ln)
    return out, removed


def write_hosts(lines):
    if os.path.isfile(HOSTS_PATH) and not os.path.isfile(HOSTS_BACKUP):
        shutil.copy2(HOSTS_PATH, HOSTS_BACKUP)
        info(f"резервная копия: {HOSTS_BACKUP}")
    with open(HOSTS_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def count_marked():
    lines, removed = strip_marked_block(read_hosts())
    return removed


def doh_update():
    ensure_root(sys.argv)
    print()
    head("Обновление DNS через DoH")
    print()

    user_list = os.path.join(ipset_dir(), "zapret-hosts-user.txt")
    if not os.path.isfile(user_list):
        err("Списки не установлены — сначала выполните установку (пункт 1).")
        print()
        return

    with open(user_list, encoding="utf-8", errors="replace") as f:
        domains = [ln.strip() for ln in f
                   if ln.strip() and not ln.strip().startswith("#")]

    # hosts сопоставляет точное имя: www-варианты нужны отдельно
    targets = []
    for d in domains:
        if d not in targets:
            targets.append(d)
        if not d.startswith("www."):
            w = "www." + d
            if w not in targets:
                targets.append(w)

    head(f"Разрешение {len(targets)} имён с проверкой рабочего IP...")
    resolved = []
    failed = []
    for i, d in enumerate(targets, 1):
        sys.stdout.write(f"    [{i}/{len(targets)}] {d:<38} ")
        sys.stdout.flush()
        ip = working_ip(d)
        if ip:
            resolved.append((ip, d))
            print(_c(C.GREEN, ip))
        else:
            failed.append(d)
            print(_c(C.GRAY, "нет рабочего IP"))

    lines, _ = strip_marked_block(read_hosts())
    while lines and not lines[-1].strip():
        lines.pop()
    lines.append("")
    lines.append(MARK_BEGIN)
    lines.append("# Разрешено через DoH. Удаляется: --action uninstall")
    for ip, d in resolved:
        lines.append(f"{ip}\t{d}")
    lines.append(MARK_END)

    write_hosts(lines)
    flush_dns()

    print()
    ok(f"Записано в hosts: {len(resolved)}, без рабочего IP: {len(failed)}")
    if failed:
        info("Не пиннингуются (системный DNS остаётся): " + ", ".join(failed[:10])
             + (" ..." if len(failed) > 10 else ""))
    info("Откат: --action uninstall (блок удаляется полностью)")
    print()


# ----------------------------------------------------------------------------
#  Диагностика доступа
# ----------------------------------------------------------------------------

PROBE_DOMAINS = ["discord.com", "rutracker.org", "www.youtube.com", "telegram.org"]


def http_code(url, timeout=12):
    """HTTP-код через urllib; 000 при ошибке."""
    req = urllib.request.Request(
        url, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64)"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def diagnose():
    print()
    head("Диагностика ресурсов")
    print()
    running = nfqws2_running()
    print(f"  nfqws2: {'работает' if running else 'остановлен'}")
    print(f"  среда:  {'установлена' if runtime_installed() else 'не установлена'}")
    print()

    for d in PROBE_DOMAINS:
        try:
            ip = socket.gethostbyname(d)
            tcp = tcp_ok(ip)
        except OSError:
            ip, tcp = None, False
        code = http_code(f"https://{d}/")
        if not tcp:
            note = _c(C.RED, "TCP недоступен: нужен внешний маршрут")
        elif code == 200:
            note = _c(C.GREEN, "HTTP 200")
        elif running:
            note = _c(C.YELLOW, "сбой DPI/протокола — смотрите журнал")
        else:
            note = _c(C.GRAY, "не проверялось с обходом")
        print(f"  {d:<22} IP={str(ip or '-'):<16} TCP={'да' if tcp else 'нет':<4} HTTP={code:<4} {note}")

    print()
    warn("Код 200 подтверждает только эти запросы, а не все протоколы и приложения.")
    print()


# ----------------------------------------------------------------------------
#  Обновление скрипта
# ----------------------------------------------------------------------------

def script_version_from_text(text):
    m = re.search(r"^VERSION\s*=\s*[\"']([\w.\-]+)[\"']", text, re.M)
    return m.group(1) if m else None


def cmp_version(a, b):
    def parts(v):
        return re.split(r"[.\-+]", v)

    pa, pb = parts(a), parts(b)
    for i in range(max(len(pa), len(pb))):
        x = pa[i] if i < len(pa) else "0"
        y = pb[i] if i < len(pb) else "0"
        if x.isdigit() and y.isdigit():
            if int(x) != int(y):
                return 1 if int(x) > int(y) else -1
        else:
            if x != y:
                return 1 if x > y else -1
    return 0


def fetch_remote_script():
    last = ""
    for branch in dict.fromkeys([UPDATE_BRANCH, "main", "master"]):
        url = f"https://raw.githubusercontent.com/{UPDATE_REPO}/{branch}/{UPDATE_FILE}"
        try:
            raw = http_get(url, timeout=30).decode("utf-8", errors="replace")
        except Exception as e:
            last = str(e)
            continue
        if "def main(" not in raw or "zapret2" not in raw.lower():
            last = f"по адресу {url} вернулся не скрипт"
            continue
        return raw, url
    raise RuntimeError(
        f"Не удалось скачать обновление из https://github.com/{UPDATE_REPO}\n  {last}"
    )


def script_update(assume_yes=False):
    self_path = os.path.abspath(__file__)
    print()
    head("Обновление скрипта")
    info(f"источник: https://github.com/{UPDATE_REPO}")
    info(f"текущая версия: {VERSION}")
    print()

    info("Проверка обновлений...")
    try:
        remote, url = fetch_remote_script()
    except Exception as e:
        err(str(e))
        print()
        return

    remote_ver = script_version_from_text(remote)
    try:
        with open(self_path, encoding="utf-8", errors="replace") as f:
            local = f.read()
    except OSError as e:
        err(f"не удалось прочитать {self_path}: {e}")
        return

    norm = lambda s: s.replace("\r\n", "\n").strip()
    if norm(local) == norm(remote):
        ok("Уже установлена последняя версия.")
        if remote_ver:
            info(f"версия в репозитории: {remote_ver}")
        print()
        return

    if remote_ver:
        c = cmp_version(remote_ver, VERSION)
        if c > 0:
            ok(f"Доступна версия: {remote_ver}")
            verdict = "update"
        elif c == 0:
            warn(f"Версия совпадает ({remote_ver}), но содержимое отличается.")
            verdict = "same"
        else:
            warn(f"В репозитории версия {remote_ver}, у вас {VERSION}.")
            err("Это ОТКАТ на более старую версию.")
            verdict = "downgrade"
    else:
        warn("В репозитории файл без маркера версии.")
        err("Скорее всего это старая копия: замена может откатить скрипт.")
        verdict = "unversioned"

    if not assume_yes:
        prompt = ("    Установить обновление? (y/N) " if verdict == "update"
                  else "    Всё равно заменить локальный файл? (y/N) ")
        try:
            ans = input(prompt).strip().lower()
        except EOFError:
            ans = ""
        if ans not in ("y", "yes", "д", "да"):
            warn("Отменено")
            print()
            return

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = f"{self_path}.{stamp}.bak"
    shutil.copy2(self_path, backup)
    info(f"резервная копия: {os.path.basename(backup)}")

    try:
        with open(self_path, "w", encoding="utf-8") as f:
            f.write(remote)
        os.chmod(self_path, 0o755)
    except OSError as e:
        shutil.copy2(backup, self_path)
        err(f"не удалось записать обновление, копия восстановлена: {e}")
        return

    # Проверка синтаксиса нового файла
    rc, _, errout = run([sys.executable, "-m", "py_compile", self_path], timeout=60)
    if rc != 0:
        shutil.copy2(backup, self_path)
        err("Скачанный скрипт содержит синтаксические ошибки, копия восстановлена.")
        info(errout[:400])
        return

    print()
    ok("Скрипт обновлён.")
    info(f"было {VERSION} → стало {remote_ver or 'обновлённая версия'}")
    info(f"резервная копия: {backup}")
    print()
    warn("Текущий процесс работает со старой версией в памяти.")
    print()


# ----------------------------------------------------------------------------
#  Удаление из системы
# ----------------------------------------------------------------------------

def uninstall(assume_yes=False):
    ensure_root(sys.argv)
    print()
    head("Удаление Zapret2 Linux из системы")
    print()
    print("  Будет удалено:")
    print("    - процесс nfqws2 и правила файрвола")
    print("    - служба systemd (автозапуск)")
    print(f"    - каталог {ZAPRET_TARGET}")
    n_marked = count_marked()
    if n_marked:
        print(f"    - {n_marked} строк в {HOSTS_PATH} (блок DoH)")
    print("  Не затрагивается:")
    print("    - прочие записи hosts, системные пакеты, настройки сети")
    print()

    if not assume_yes:
        try:
            ans = input("  Продолжить? (y/N) ").strip().lower()
        except EOFError:
            ans = ""
        if ans not in ("y", "yes", "д", "да"):
            warn("Отменено")
            print()
            return

    print()
    head("[1/4] Остановка обхода...")
    if runtime_installed():
        run([init_script(), "stop"], timeout=120)
    run(["pkill", "-f", nfqws2_path()])
    time.sleep(1)

    head("[2/4] Удаление службы...")
    run(["systemctl", "disable", SERVICE_NAME], timeout=60)
    run(["systemctl", "stop", SERVICE_NAME], timeout=60)
    if os.path.isfile(UNIT_PATH):
        try:
            os.remove(UNIT_PATH)
        except OSError:
            pass
    run(["systemctl", "daemon-reload"], timeout=60)

    head("[3/4] Удаление среды...")
    if os.path.isdir(ZAPRET_TARGET):
        shutil.rmtree(ZAPRET_TARGET, ignore_errors=True)

    head("[4/4] Откат правок hosts...")
    lines, removed = strip_marked_block(read_hosts())
    if removed:
        write_hosts(lines)
        flush_dns()

    print()
    head("Проверка результата:")
    checks = [
        ("процесс nfqws2", not nfqws2_running()),
        ("служба systemd", not service_enabled() and not os.path.isfile(UNIT_PATH)),
        ("каталог среды", not os.path.isdir(ZAPRET_TARGET)),
        ("записи hosts", count_marked() == 0),
    ]
    all_ok = True
    for name, good in checks:
        if good:
            ok(f"{name:<20} удалено")
        else:
            err(f"{name:<20} ОСТАЛОСЬ")
            all_ok = False

    print()
    if all_ok:
        ok("Удаление завершено полностью.")
    else:
        warn("Часть компонентов осталась — повторите удаление.")
    print()


# ----------------------------------------------------------------------------
#  Меню
# ----------------------------------------------------------------------------

def show_status_block():
    print(f"  Zapret2 Linux — системная DPI-десинхронизация")
    print(_c(C.GRAY, f"  Версия {VERSION} | zapret2 {ZAPRET_VERSION} | nfqws2 + nftables"))
    status_line()


def menu():
    first_run = True
    while True:
        if first_run:
            first_run = False
            reqs = requirements()
            missing = [r for r in reqs if r["status"] == "FAIL" and r["fixable"]]
            hard = [r for r in reqs if r["status"] == "FAIL" and not r["fixable"]]
            if missing or hard:
                os.system("clear" if os.environ.get("TERM") else "")
                print()
                warn("Обнаружены отсутствующие зависимости")
                print()
                for m in missing:
                    info(f"- {m['name']}: {m['detail']}")
                for m in hard:
                    info(f"- {m['name']}: {m['detail']} (ручной шаг)")
                print()
                if missing:
                    try:
                        ans = input("  Установить автоматически сейчас? (y/N) ").strip().lower()
                    except EOFError:
                        ans = ""
                    if ans in ("y", "yes", "д", "да"):
                        try:
                            install_dependencies(assume_yes=True)
                        except Exception as e:
                            err(str(e))
                print()
                try:
                    input("  Нажмите Enter для продолжения...")
                except EOFError:
                    pass

        os.system("clear" if os.environ.get("TERM") else "")
        show_status_block()
        running = nfqws2_running()
        installed = runtime_installed()
        enabled = service_enabled()
        print()
        print(f"  [1] {'Обновить' if installed else 'Установить'} среду zapret2")
        print(f"  [2] {'Остановить' if running else 'Запустить'} обход")
        print(f"  [3] Автозапуск при входе: {'выключить' if enabled else 'включить'}")
        print("  [4] Диагностика ресурсов")
        print("  [5] Проверить требования")
        print("  [6] Установить отсутствующие зависимости")
        print("  [7] Обновить DNS через DoH")
        print("  [8] Выученные домены и журналы")
        print(f"  [9] Обновить скрипт (у вас {VERSION})")
        print(_c(C.YELLOW, "  [10] Удалить из системы"))
        print("  [0] Выход")

        try:
            choice = input("\n  Выбор: ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return

        try:
            if choice == "1":
                install_runtime()
                pause()
            elif choice == "2":
                if running:
                    stop_bypass()
                else:
                    start_bypass()
                pause()
            elif choice == "3":
                toggle_autostart()
                pause()
            elif choice == "4":
                diagnose()
                pause()
            elif choice == "5":
                check_requirements()
                pause()
            elif choice == "6":
                install_dependencies()
                pause()
            elif choice == "7":
                doh_update()
                pause()
            elif choice == "8":
                show_domains_and_logs()
                pause()
            elif choice == "9":
                script_update()
                pause()
            elif choice == "10":
                uninstall()
                pause()
            elif choice == "0":
                return
        except KeyboardInterrupt:
            print()
            warn("Прервано")
        except Exception as e:
            print()
            err(str(e))


def show_domains_and_logs():
    print()
    head("Выученные домены")
    print()
    doms = learned_domains()
    if doms:
        print(f"  Всего: {len(doms)}")
        for d in doms[:30]:
            info(d)
        if len(doms) > 30:
            info(f"... и ещё {len(doms) - 30}")
    else:
        warn("Список пуст (обход ещё не обучился)")
    print()

    log = os.path.join(ipset_dir(), "zapret-hosts-auto-debug.log")
    print(_c(C.GRAY, f"  Журналы: {ipset_dir()}"))
    if os.path.isfile(log):
        print(_c(C.GRAY, f"  Отладочный лог автолиста: {log}"))
    print()


def pause():
    try:
        input("  Нажмите Enter...")
    except EOFError:
        pass


# ----------------------------------------------------------------------------
#  Точка входа
# ----------------------------------------------------------------------------

ACTIONS = {
    "menu": None,
    "install": install_runtime,
    "start": start_bypass,
    "stop": stop_bypass,
    "status": None,
    "check": check_requirements,
    "deps": install_dependencies,
    "doh": doh_update,
    "diagnose": diagnose,
    "update": script_update,
    "uninstall": uninstall,
}


def main():
    if sys.platform != "linux":
        print(_c(C.RED, f"  Этот скрипт предназначен для Linux (текущая платформа: {sys.platform})."))
        print("  Для Windows используйте Zapret2Windows.ps1")
        return 2

    parser = argparse.ArgumentParser(
        description="Zapret2 Linux — системная DPI-десинхронизация",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Действия:
  menu       интерактивное меню (по умолчанию)
  install    установить или обновить среду zapret2
  start      запустить обход
  stop       остановить обход
  status     показать состояние
  check      проверить требования
  deps       установить отсутствующие зависимости
  doh        обновить DNS через DoH (hosts)
  diagnose   диагностика ресурсов
  update     обновить сам скрипт из GitHub
  uninstall  удалить из системы

Примеры:
  sudo python3 zapret2-linux.py
  sudo python3 zapret2-linux.py --action install
  python3 zapret2-linux.py --action check
""",
    )
    parser.add_argument(
        "--action", "-a", default="menu", choices=sorted(ACTIONS.keys()),
        help="действие (по умолчанию: menu)",
    )
    parser.add_argument("--yes", "-y", action="store_true",
                        help="не задавать вопросов подтверждения")
    parser.add_argument("--version", "-V", action="version",
                        version=f"zapret2-linux {VERSION}")
    args = parser.parse_args()

    action = args.action

    if action == "menu":
        ensure_root(sys.argv)
        try:
            menu()
        except KeyboardInterrupt:
            print()
        return 0

    if action == "status":
        show_status_block()
        print()
        return 0

    func = ACTIONS[action]
    try:
        if action in ("update", "uninstall", "deps"):
            func(assume_yes=args.yes)
        else:
            func()
    except Exception as e:
        print()
        err(str(e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
