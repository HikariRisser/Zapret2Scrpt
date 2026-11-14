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
import shlex
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from datetime import datetime

VERSION = "1.4.7"
UPDATE_REPO = "HikariRisser/Zapret2Scrpt"
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
# При установке/обновлении недостающие домены ДОПИСЫВАЮТСЯ в существующий
# список, ручные правки пользователя сохраняются.
SEED_DOMAINS = [
    "archive.org", "cdn-telegram.org", "cdninstagram.com", "cloudflare-dns.com",
    "cloudflare-ech.com", "cloudflare.com", "dis.gd", "discord-attachments-uploads-prd.storage.googleapis.com",
    "discord.co", "discord.com", "discord.dev", "discord.gg",
    "discord.gift", "discord.media", "discord.new", "discordapp.com",
    "discordapp.net", "discordcdn.com", "discordstatus.com", "facebook.com",
    "facebook.net", "fb.com", "fb.me", "fbcdn.net",
    "fbsbx.com", "ggpht.com", "github.com", "githubassets.com",
    "githubusercontent.com", "googlevideo.com", "instagram.com", "jnn-pa.googleapis.com",
    "jtvnw.net", "licdn.com", "linkedin.com", "live-video.net",
    "medium.com", "messenger.com", "nnmclub.to", "patreon.com",
    "proton.me", "protonmail.com", "rbxcdn.com", "redd.it",
    "reddit.com", "redditmedia.com", "redditstatic.com", "roblox.com",
    "rutor.info", "rutor.is", "rutracker.cc", "rutracker.org",
    "signal.org", "sndcdn.com", "soundcloud.com", "spotify.com",
    "t-ru.org", "t.co", "t.me", "telegra.ph",
    "telegram.me", "telegram.org", "telesco.pe", "threads.com",
    "threads.net", "tiktok.com", "tiktokcdn.com", "tiktokv.com",
    "ttvnw.net", "ttwstatic.com", "twimg.com", "twitch.tv",
    "twitter.com", "viber.com", "wa.me", "whatsapp.com",
    "whatsapp.net", "x.com", "youtu.be", "youtube-nocookie.com",
    "youtube.com", "youtubei.googleapis.com", "youtubekids.com", "yt.be",
    "yt3.googleusercontent.com", "ytimg.com",
]

SEED_EXCLUDE = ["localhost", "local", "example.com"]

# "Белый" SNI для фейковых ClientHello. ТСПУ пропускает соединения к
# хостингам (Cloudflare, Hetzner, OVH, AWS...) только для доменов из своего
# белого списка, остальные обрывает после ~16 КБ. Фейк с белым SNI
# заставляет DPI отнести поток к разрешённому домену.
WHITE_SNI = "www.google.com"

# Подсети хостингов, которые ТСПУ режет "по 16 КБ". Для них работает
# отдельный профиль с белым SNI. Файл можно дополнять своими подсетями.
HOSTING_IPSET_FILE = "zapret2win-ip-hosting.txt"
SEED_HOSTING_IPSET = [
    "# Cloudflare (https://www.cloudflare.com/ips/)",
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
    "2400:cb00::/32",
    "2606:4700::/32",
    "2803:f800::/32",
    "2405:b500::/32",
    "2405:8100::/32",
    "2a06:98c0::/29",
    "2c0f:f248::/32",
    "# Amazon CloudFront",
    "13.32.0.0/15",
    "13.35.0.0/16",
    "13.224.0.0/14",
    "18.64.0.0/14",
    "18.154.0.0/15",
    "18.160.0.0/15",
    "18.164.0.0/15",
    "18.172.0.0/15",
    "52.84.0.0/15",
    "54.182.0.0/16",
    "54.192.0.0/16",
    "54.230.0.0/16",
    "54.239.128.0/18",
    "99.84.0.0/16",
    "99.86.0.0/16",
    "108.138.0.0/15",
    "108.156.0.0/14",
    "143.204.0.0/16",
    "205.251.192.0/19",
    "# Hetzner",
    "5.9.0.0/16",
    "5.75.128.0/17",
    "23.88.0.0/17",
    "37.27.0.0/16",
    "46.4.0.0/16",
    "49.12.0.0/15",
    "65.21.0.0/16",
    "65.108.0.0/15",
    "78.46.0.0/15",
    "88.99.0.0/16",
    "88.198.0.0/16",
    "91.107.128.0/17",
    "95.216.0.0/15",
    "116.202.0.0/15",
    "128.140.0.0/17",
    "135.181.0.0/16",
    "136.243.0.0/16",
    "138.201.0.0/16",
    "144.76.0.0/16",
    "148.251.0.0/16",
    "157.90.0.0/16",
    "159.69.0.0/16",
    "162.55.0.0/16",
    "167.235.0.0/16",
    "168.119.0.0/16",
    "176.9.0.0/16",
    "178.63.0.0/16",
    "188.40.0.0/16",
    "195.201.0.0/16",
    "213.133.96.0/19",
    "213.239.192.0/18",
    "# OVH",
    "5.39.0.0/17",
    "5.135.0.0/16",
    "5.196.0.0/16",
    "37.59.0.0/16",
    "37.187.0.0/16",
    "46.105.0.0/16",
    "51.38.0.0/16",
    "51.68.0.0/16",
    "51.75.0.0/16",
    "51.77.0.0/16",
    "51.89.0.0/16",
    "51.91.0.0/16",
    "51.195.0.0/16",
    "54.36.0.0/14",
    "87.98.128.0/17",
    "91.121.0.0/16",
    "92.222.0.0/16",
    "94.23.0.0/16",
    "137.74.0.0/16",
    "141.94.0.0/15",
    "145.239.0.0/16",
    "147.135.0.0/16",
    "149.202.0.0/16",
    "151.80.0.0/16",
    "164.132.0.0/16",
    "176.31.0.0/16",
    "178.32.0.0/15",
    "188.165.0.0/16",
    "193.70.0.0/17",
    "213.186.32.0/19",
    "213.251.128.0/18",
    "217.182.0.0/16",
    "# DigitalOcean",
    "46.101.0.0/16",
    "64.225.0.0/16",
    "64.227.0.0/16",
    "68.183.0.0/16",
    "104.131.0.0/16",
    "104.236.0.0/16",
    "107.170.0.0/16",
    "128.199.0.0/16",
    "134.122.0.0/16",
    "134.209.0.0/16",
    "137.184.0.0/16",
    "138.68.0.0/16",
    "138.197.0.0/16",
    "139.59.0.0/16",
    "142.93.0.0/16",
    "143.198.0.0/16",
    "146.190.0.0/16",
    "157.230.0.0/16",
    "157.245.0.0/16",
    "159.65.0.0/16",
    "159.89.0.0/16",
    "159.203.0.0/16",
    "161.35.0.0/16",
    "164.90.0.0/16",
    "164.92.0.0/16",
    "165.22.0.0/16",
    "165.227.0.0/16",
    "167.71.0.0/16",
    "167.99.0.0/16",
    "167.172.0.0/16",
    "170.64.0.0/16",
    "174.138.0.0/17",
    "178.62.0.0/16",
    "178.128.0.0/16",
    "188.166.0.0/16",
    "206.189.0.0/16",
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

def run_init(action, timeout=120):
    """
    Запуск init-скрипта zapret2. Вывод — в файл, а не в PIPE: init запускает
    nfqws2 в фоне («nfqws2 ... >/dev/null &»), и тот наследует stderr.
    С PIPE subprocess ждал бы закрытия потока — то есть до тайм-аута.
    """
    log = os.path.join(ZAPRET_TARGET, "init.log")
    try:
        with open(log, "w", encoding="utf-8") as f:
            p = subprocess.run([init_script(), action], stdin=subprocess.DEVNULL,
                               stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        rc = 124
    except OSError as e:
        return 127, str(e)
    try:
        with open(log, encoding="utf-8", errors="replace") as f:
            return rc, f.read().strip()
    except OSError:
        return rc, ""


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
    ipd = ipset_dir()
    user_list = os.path.join(ipd, "zapret-hosts-user.txt")
    auto_list = os.path.join(ipd, "zapret-hosts-auto.txt")
    excl_list = os.path.join(ipd, "zapret-hosts-user-exclude.txt")
    hosting = os.path.join(ipd, HOSTING_IPSET_FILE)
    sni = WHITE_SNI
    # Домены, переведённые в WARP, zapret не трогает: их трафик идёт в туннель.
    wx = f"--hostlist-exclude={os.path.join(ipd, WARP_LIST_FILE)}"

    profiles = [
        # [1] HTTP
        f"--filter-tcp=80 --filter-l7=http <HOSTLIST> {wx} --payload=http_req "
        "--lua-desync=fake:blob=fake_default_http:tcp_md5 "
        "--lua-desync=multisplit:pos=method+2",
    ]
    if hosting_ipset_nonempty():
        # [2] Хостинги ("16 КБ"): сайты на Cloudflare/Hetzner/OVH/AWS/DO,
        # которых НЕТ в списках доменов. Должен стоять до [3]: профиль с
        # autohostlist забирает любой поток с известным именем.
        profiles.append(
            f"--filter-tcp=443 --filter-l7=tls --ipset={hosting} "
            f"--hostlist-exclude={excl_list} --hostlist-exclude={user_list} "
            f"--hostlist-exclude={auto_list} {wx} --payload=tls_client_hello "
            f"--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:"
            f"tls_mod=rnd,dupsid,sni={sni}:repeats=6 "
            "--lua-desync=multidisorder:pos=1,midsld")
    profiles += [
        # [3] TLS для доменов из списков: автоперебор стратегий (circular)
        # отдельно для каждого домена 2-го уровня. Стратегия 1 — прежняя.
        f"--filter-tcp=443 --filter-l7=tls <HOSTLIST> {wx} "
        "--in-range=-s5556 --lua-desync=circular:fails=2:retrans=2:nld=2 "
        "--in-range=x --payload=tls_client_hello "
        "--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=6:strategy=1 "
        "--lua-desync=multidisorder:pos=1,midsld:strategy=1 "
        f"--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:"
        f"tls_mod=rnd,dupsid,sni={sni}:repeats=6:strategy=2 "
        "--lua-desync=multisplit:pos=1,sniext+1:strategy=2 "
        "--lua-desync=hostfakesplit:host=google.com:tcp_md5:strategy=3 "
        "--lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=fake_default_tls:strategy=4",

        # [4] QUIC: без автообучения (как в официальном config.default),
        # выученные TCP-домены применяются и здесь.
        f"--filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO> {wx} --payload=quic_initial "
        "--lua-desync=fake:blob=fake_default_quic:repeats=6",

        # [5] Голос/медиа Discord, STUN, WireGuard
        "--filter-l7=stun,discord,wireguard "
        "--payload=stun,discord_ip_discovery,wireguard_initiation,wireguard_cookie "
        "--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2",
    ]
    opt = " --new\n".join(profiles)

    return f"""# Сгенерировано zapret2-linux {VERSION}
# Ручные правки будут перезаписаны при обновлении среды.

NFQWS2_ENABLE=1
NFQWS2_PORTS_TCP=80,443
# 2408,500,1701,4500 — порты WARP: zapret маскирует рукопожатие WireGuard
NFQWS2_PORTS_UDP=443,3478,50000-50099,19294-19344,2408,500,1701,4500

# Сколько первых пакетов соединения отдавать nfqws2 (connbytes).
# Без этих переменных init-скрипт zapret2 НЕ создаёт правила перехвата
# вообще. Остальной трафик идёт мимо nfqws2 — это и даёт скорость.
NFQWS2_TCP_PKT_OUT=20
NFQWS2_TCP_PKT_IN=10
NFQWS2_UDP_PKT_OUT=5
NFQWS2_UDP_PKT_IN=3

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
AUTOHOSTLIST_INCOMING_MAXSEQ=4096
AUTOHOSTLIST_UDP_IN=1
AUTOHOSTLIST_UDP_OUT=4

# IPv6 тоже перехватываем: иначе при наличии IPv6 браузер уходит на
# AAAA-адрес мимо обхода.
DISABLE_IPV6=0
FLOWOFFLOAD=donttouch
INIT_APPLY_FW=1
FILTER_TTL_EXPIRED_ICMP=1

# Обязательно задавать в config: common/nft.sh подставляет DESYNC_MARK при
# загрузке, раньше, чем init-скрипт назначает значение по умолчанию. Без
# этих строк правила nftables получаются с синтаксической ошибкой и
# перехват не создаётся (nfqws2 запущен, но не получает ни одного пакета).
DESYNC_MARK=0x40000000
DESYNC_MARK_POSTNAT=0x20000000
"""


def hosting_ipset_nonempty():
    path = os.path.join(ipset_dir(), HOSTING_IPSET_FILE)
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return any(ln.strip() and not ln.strip().startswith("#") for ln in f)
    except OSError:
        return False


def merge_list_file(path, seed):
    """
    Дописывает в файл недостающие строки из seed, ничего не удаляя:
    ручные правки и комментарии пользователя сохраняются.
    Возвращает число добавленных строк.
    """
    lines = []
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    have = {ln.strip().lower() for ln in lines}
    added = 0
    for item in seed:
        if item and item.strip().lower() not in have:
            have.add(item.strip().lower())
            lines.append(item)
            added += 1
    if added or not os.path.isfile(path):
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        os.chmod(path, 0o644)
    return added


def seed_lists():
    """Создаёт списки и дописывает в них недостающие записи."""
    os.makedirs(ipset_dir(), exist_ok=True)

    n = merge_list_file(os.path.join(ipset_dir(), "zapret-hosts-user.txt"), SEED_DOMAINS)
    if n:
        info(f"добавлено доменов в список обхода: {n}")
    merge_list_file(os.path.join(ipset_dir(), "zapret-hosts-user-exclude.txt"), SEED_EXCLUDE)
    n = merge_list_file(os.path.join(ipset_dir(), HOSTING_IPSET_FILE), SEED_HOSTING_IPSET)
    if n:
        info(f"добавлено подсетей хостингов: {n}")

    merge_list_file(os.path.join(ipset_dir(), WARP_LIST_FILE), SEED_WARP)

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

    # Конфиг от другой версии скрипта переписываем сами: после обновления
    # скрипта не нужно помнить про пункт [1], а старый конфиг мог быть
    # нерабочим (до 1.3.4 правила перехвата на nftables не создавались).
    try:
        with open(config_path(), encoding="utf-8") as f:
            first = f.readline()
    except OSError:
        first = ""
    if f"zapret2-linux {VERSION}" not in first:
        seed_lists()
        write_config()
        info(f"Конфигурация обновлена до версии {VERSION}")

    head("Запуск системного обхода...")
    run_init("stop")  # убрать остатки правил от прошлого неудачного запуска
    rc, out = run_init("start")
    for _ in range(20):
        if nfqws2_running():
            break
        time.sleep(0.25)
    if nfqws2_running() and re.search(r"(?m)^Error:|syntax error", out or ""):
        errs = [ln for ln in out.splitlines() if ln.startswith("Error:")][:3]
        run_init("stop")
        raise RuntimeError(
            "nfqws2 запущен, но правила перехвата не создались — обход не работал бы.\n"
            + "\n".join(errs) + f"\nПолный журнал: {os.path.join(ZAPRET_TARGET, 'init.log')}")
    if nfqws2_running():
        ok("Обход запущен, nfqws2 работает")
        if warp_enabled():
            start_warp_background()
    else:
        raise RuntimeError(
            "nfqws2 не запустился.\n"
            + (out or "нет вывода")
            + "\nПроверьте: systemctl status, dmesg, наличие nfnetlink_queue"
        )


def stop_bypass():
    ensure_root(sys.argv)
    if not runtime_installed():
        warn("Среда не установлена")
        return
    head("Остановка обхода...")
    stop_warp(quiet=True)
    run_init("stop")
    time.sleep(1)
    if nfqws2_running():
        # Крайний случай: добиваем процесс и чистим правила
        run(["pkill", "-f", nfqws2_path()])
        time.sleep(1)
    ok("Обход остановлен")


def status_line():
    if os.path.isdir(warp_dir()):
        warp_status_line()
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


BOGON_RE = re.compile(
    r"^(0\.|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\."
    r"|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)")


def tls_cert_ok(ip, hostname, timeout=2.5):
    """
    TLS-рукопожатие с ip и проверка, что сертификат выдан на hostname.
    Заглушка провайдера или чужой узел такой сертификат не предъявят.
    """
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((ip, 443), timeout=timeout) as raw:
            raw.settimeout(timeout)
            with ctx.wrap_socket(raw, server_hostname=hostname):
                return True
    except (OSError, ssl.SSLError, ValueError):
        return False


def system_dns_ok(domain):
    """
    Нужен ли домену пиннинг в hosts вообще? Если системный DNS отдаёт
    рабочий адрес с правильным сертификатом — нет: CDN выбирает ближайший
    узел, а адрес из чужого DoH-ответа бывает дальним и устаревает.
    Вызывать, когда наш блок уже убран из hosts.
    """
    try:
        infos = socket.getaddrinfo(domain, 443, socket.AF_INET, socket.SOCK_STREAM)
    except (OSError, UnicodeError):
        return False
    ips = []
    for inf in infos:
        ip = inf[4][0]
        if ip not in ips:
            ips.append(ip)
    if not ips or any(BOGON_RE.match(ip) for ip in ips):
        return False
    return any(tls_cert_ok(ip, domain) for ip in ips[:2])


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

    # Сначала адрес с правильным сертификатом. Если DPI рвёт рукопожатие
    # (обход не запущен), берём, как раньше, первый отвечающий по TCP.
    for ip in cands[:max_candidates]:
        if tls_cert_ok(ip, domain, timeout=2.0):
            return ip
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
    # Домены WARP разрешает DNS sing-box; запись в hosts увела бы их мимо туннеля.
    in_warp = set(list_entries(warp_list_path()))
    domains = [d for d in domains if d.lower() not in in_warp]

    # hosts сопоставляет точное имя: www-варианты нужны отдельно
    targets = []
    for d in domains:
        if d not in targets:
            targets.append(d)
        # www-вариант имеет смысл только для доменов 2-го уровня
        if not d.startswith("www.") and d.count(".") == 1:
            w = "www." + d
            if w not in targets:
                targets.append(w)

    # Убираем прежний блок, чтобы системный резолвер отвечал без него.
    old_lines = read_hosts()
    stripped, removed = strip_marked_block(old_lines)
    if removed:
        write_hosts(stripped)
        flush_dns()

    head(f"Разрешение {len(targets)} имён с проверкой рабочего IP...")
    resolved = []
    failed = []
    sys_ok = []
    for i, d in enumerate(targets, 1):
        sys.stdout.write(f"    [{i}/{len(targets)}] {d:<38} ")
        sys.stdout.flush()
        if system_dns_ok(d):
            sys_ok.append(d)
            print(_c(C.GRAY, "системный DNS в порядке"))
            continue
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
    ok(f"Записано в hosts: {len(resolved)}, системный DNS в порядке: {len(sys_ok)}, "
       f"без рабочего IP: {len(failed)}")
    if resolved and not nfqws2_running():
        info("Совет: повторите при ЗАПУЩЕННОМ обходе — тогда в hosts попадут "
             "только домены с подменой DNS.")
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
    if sys.stdin.isatty():
        try:
            ans = input("  Собрать подробный отчёт для поиска неисправности? (y/N) ").strip().lower()
        except EOFError:
            ans = ""
        if ans in ("y", "yes", "д", "да"):
            collect_report()


# ----------------------------------------------------------------------------
#  Подробный отчёт для поиска неисправностей
# ----------------------------------------------------------------------------

REPORT_TARGETS = ["www.youtube.com", "youtube.com", "i.ytimg.com",
                  "rr1---sn-4g5e6nz7.googlevideo.com", "discord.com",
                  "gateway.discord.gg", "cdn.discordapp.com"]


def _probe_tls(host, family, timeout=6.0, ip=None):
    """
    Одна попытка: DNS -> TCP -> TLS (SNI=host) -> GET / и чтение до 64 КБ.
    Возвращает строку с этапом, на котором всё оборвалось, и временем.
    """
    fam = socket.AF_INET if family == 4 else socket.AF_INET6
    t0 = time.monotonic()
    if not ip:
        try:
            ips = sorted({i[4][0] for i in socket.getaddrinfo(host, 443, fam, socket.SOCK_STREAM)})
        except (OSError, UnicodeError) as e:
            return f"DNS: нет адреса ({e.__class__.__name__})"
        ip = ips[0]
    stage = "TCP"
    try:
        raw = socket.create_connection((ip, 443), timeout=timeout)
        stage = "TLS"
        ctx = ssl.create_default_context()
        with ctx.wrap_socket(raw, server_hostname=host) as s:
            s.settimeout(timeout)
            t_tls = time.monotonic()
            stage = "HTTP"
            s.sendall(f"GET / HTTP/1.1\r\nHost: {host}\r\nUser-Agent: {BROWSER_UA}\r\n"
                      f"Connection: close\r\n\r\n".encode())
            total = 0
            first = b""
            while total < 65536:
                chunk = s.recv(16384)
                if not chunk:
                    break
                if not first:
                    first = chunk[:40]
                total += len(chunk)
        status = first.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        return (f"OK {ip} TLS {int((t_tls - t0) * 1000)} мс, "
                f"получено {total} Б, «{status}»")
    except ssl.SSLCertVerificationError as e:
        return f"СБОЙ на {stage} {ip}: неверный сертификат ({e.verify_message}) — подмена DNS/заглушка"
    except (socket.timeout, TimeoutError):
        return f"СБОЙ на {stage} {ip}: тайм-аут {int(time.monotonic() - t0)} с"
    except OSError as e:
        return f"СБОЙ на {stage} {ip}: {e.__class__.__name__} {e}"


def collect_report():
    """Собирает отчёт в файл: конфигурация, правила, процессы, проверки сайтов."""
    ensure_root(sys.argv)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = f"/tmp/zapret2-report-{stamp}.txt"
    lines = []

    def sec(title):
        lines.append("")
        lines.append("=" * 72)
        lines.append(title)
        lines.append("=" * 72)

    def cmd(c, timeout=20):
        rc, out, errout = run(c, timeout=timeout)
        lines.append(f"$ {' '.join(c)}  (rc={rc})")
        lines.extend((out + ("\n" + errout if errout else "")).splitlines() or ["<пусто>"])

    def file(p, grep=None, limit=400):
        lines.append(f"--- {p}")
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                content = f.read().splitlines()
            if grep:
                content = [ln for ln in content if re.search(grep, ln)]
            lines.extend(content[:limit] or ["<пусто>"])
        except OSError as e:
            lines.append(f"<нет: {e.strerror}>")

    head("Сбор отчёта...")
    sec("Система")
    lines.append(f"zapret2-linux {VERSION}, zapret2 {ZAPRET_VERSION}, python {sys.version.split()[0]}")
    cmd(["uname", "-a"])
    file("/etc/os-release", grep=r"^(PRETTY_NAME|VERSION_ID)=")
    cmd(["sh", "-c", "lsmod | grep -E 'nfnetlink_queue|nft_queue|xt_NFQUEUE|connbytes|nft_ct|nf_tables' || true"])
    cmd(["sh", "-c", "sysctl net.netfilter.nf_conntrack_tcp_be_liberal net.ipv6.conf.all.disable_ipv6 2>&1"])
    cmd(["ip", "-4", "route", "show", "default"])
    cmd(["ip", "-6", "route", "show", "default"])

    sec("nfqws2")
    cmd(["sh", "-c", "ps -eo pid,user,args | grep '[n]fqws2' || echo 'nfqws2 не запущен'"])
    cmd([nfqws2_path(), "--version"])
    file(os.path.join(ZAPRET_TARGET, "init.log"))
    file(os.path.join(ZAPRET_TARGET, "config"))

    sec("Правила перехвата")
    if which("nft"):
        cmd(["sh", "-c", "nft list ruleset 2>&1 | grep -iE 'table|chain|queue|zapret' | head -80"])
    if which("iptables-save"):
        cmd(["sh", "-c", "iptables-save 2>/dev/null | grep -iE 'NFQUEUE|zapret' | head -40"])
        cmd(["sh", "-c", "ip6tables-save 2>/dev/null | grep -iE 'NFQUEUE|zapret' | head -40"])

    sec("DNS и hosts")
    file("/etc/resolv.conf", grep=r"^\s*(nameserver|search|options)")
    file(HOSTS_PATH, grep=r"youtube|googlevideo|ytimg|discord|DoH")
    if which("resolvectl"):
        cmd(["sh", "-c", "resolvectl status 2>&1 | grep -E 'DNS Servers|Current DNS|DNSSEC|DNSOverTLS' | head -20"])

    sec("Списки")
    for name in ("zapret-hosts-user.txt", "zapret-hosts-auto.txt", "zapret-hosts-user-exclude.txt",
                 WARP_LIST_FILE):
        p = os.path.join(ipset_dir(), name)
        doms = list_entries(p)
        hit = [d for d in doms if re.search(r"youtube|googlevideo|ytimg|ggpht|discord", d)]
        lines.append(f"{name}: {len(doms)} записей; YouTube/Discord: {', '.join(hit) or '—'}")
    lines.append(f"WARP: {'включён' if warp_enabled() else 'выключен'}, "
                 f"{'работает' if warp_running() else 'не запущен'}")
    file(warp_path("last-error.txt"))

    sec("Другие туннели")
    cmd(["sh", "-c", "ip -br link 2>&1 | grep -iE 'tun|wg|tap|warp|throne|nekoray|hiddify|sing' || echo 'нет'"])
    cmd(["sh", "-c", "ps -eo pid,args | grep -iE '[s]ing-box|[x]ray|[t]hrone|[n]ekoray|[h]iddify|[c]lash|[m]ihomo' | cut -c1-160 || true"])

    sec("WARP: журналы")
    st = read_json(warp_path("state.json")) or {}
    lines.append(f"state: best={st.get('best')} tested={st.get('tested')} ranked={st.get('ranked')}")
    lines.append(f"usque: {'есть' if os.path.isfile(usque_path()) else 'нет'}, "
                 f"регистрация MASQUE: {'есть' if os.path.isfile(usque_config()) else 'нет'}, "
                 f"регистрация WireGuard: {'есть' if os.path.isfile(warp_path('account.json')) else 'нет'}")
    uc = read_json(usque_config()) or {}
    lines.append("usque endpoints: " + ", ".join(
        f"{k}={uc.get(k)}" for k in ("endpoint_v4", "endpoint_v6", "endpoint_h2_v4", "endpoint_h2_v6")))
    if os.path.isfile(usque_path()):
        cmd([usque_path(), "version"])
    for name in ("probe-usque.log", "probe.log", "start.log"):
        lines.append(f"--- {name}")
        lines.extend(file_tail(warp_path(name), 60) or ["<пусто>"])
    cmd(["sh", "-c", f"resolvectl status {WARP_TUN} 2>&1 | head -12"])
    cmd(["sh", "-c", f"ip rule 2>&1 | head -12; ip route get {WARP_FAKE4_PREFIX}0.1 2>&1"])
    for d in list_entries(warp_list_path())[:3]:
        cmd(["sh", "-c", f"resolvectl query {shlex.quote(d)} 2>&1 | head -4"])
        lines.append(f"через TUN {d}: {_probe_tls(d, 4)}")
    for svc in (USQUE_SERVICE, WARP_SERVICE):
        cmd(["journalctl", "-u", svc, "-n", "40", "--no-pager", "-o", "cat"])

    # Проверка сайтов с отладочным журналом nfqws2: перезапускаем nfqws2 с
    # теми же параметрами + --debug, правила перехвата остаются на месте.
    debug_log = "/tmp/zapret2-nfqws2-debug.log"
    rc, pids, _ = run(["pgrep", "-f", nfqws2_path()])
    pid = pids.split()[0] if rc == 0 and pids.strip() else None
    args = None
    if pid:
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                args = [a.decode() for a in f.read().split(b"\0") if a]
        except OSError:
            args = None
    dbg_proc = None
    if args:
        info("nfqws2 перезапускается с отладочным журналом на время проверок...")
        run(["kill", pid])
        time.sleep(1)
        try:
            os.remove(debug_log)
        except OSError:
            pass
        dbg_args = [a for a in args if a != "--daemon"] + [f"--debug=@{debug_log}"]
        dbg_proc = subprocess.Popen(dbg_args, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    start_new_session=True)
        time.sleep(1.5)

    sec("Проверка сайтов (" + ("через nfqws2 с отладкой" if dbg_proc else "nfqws2 НЕ запущен") + ")")
    for host in REPORT_TARGETS:
        for fam in (4, 6):
            res = _probe_tls(host, fam)
            lines.append(f"IPv{fam} {host:<38} {res}")
        # Тот же сайт по адресу из DoH: отделяет подмену DNS от проблемы DPI.
        doh_ips = doh_query(host, "A", timeout=5)
        if doh_ips:
            lines.append(f"DoH  {host:<38} {_probe_tls(host, 4, ip=doh_ips[0])}")
        else:
            lines.append(f"DoH  {host:<38} DoH не ответил")
            sys.stdout.write(".")
            sys.stdout.flush()
    print()

    if dbg_proc:
        dbg_proc.terminate()
        try:
            dbg_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            dbg_proc.kill()
        info("Возврат nfqws2 в обычный режим...")
        run_init("stop")
        run_init("start")
        sec("Отладочный журнал nfqws2 (последние 600 строк)")
        lines.extend(file_tail(debug_log, 600) or ["<пусто>"])

    sec("Отладочный журнал: сводка")
    tail = file_tail(debug_log, 100000) if dbg_proc else []
    for pat in ("desync profile", "hostname", "lua_desync", "rawsend", "ERROR", "error"):
        lines.append(f"{pat}: {sum(1 for ln in tail if pat in ln)}")

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(path, 0o644)
    ok(f"Отчёт сохранён: {path}")
    info("Пришлите этот файл — по нему видно, на каком этапе ломается доступ.")
    info("Личных данных в нём нет: только конфигурация, правила и результаты проверок.")
    return path


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
    print("    - службы systemd (автозапуск, WARP)")
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
        run_init("stop")
    run(["pkill", "-f", nfqws2_path()])
    time.sleep(1)

    stop_warp(quiet=True)

    head("[2/4] Удаление службы...")
    for svc, unit in ((WARP_SERVICE, WARP_UNIT_PATH), (USQUE_SERVICE, USQUE_UNIT_PATH)):
        run(["systemctl", "disable", svc], timeout=60)
        if os.path.isfile(unit):
            try:
                os.remove(unit)
            except OSError:
                pass
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
#  WARP через sing-box: запасной маршрут для сайтов, с которыми не
#  справляется zapret (блокировка по IP, обрыв «16 КБ», недоступность).
#
#  В TUN sing-box маршрутизируется ТОЛЬКО диапазон FakeIP (198.18.0.0/15):
#  домены из списка WARP получают FakeIP от DNS sing-box и уходят в туннель
#  WireGuard к Cloudflare, весь остальной трафик идёт мимо sing-box, через
#  zapret. Узел Cloudflare подбирается автоматически по задержке.
# ----------------------------------------------------------------------------

SING_BOX_VERSION = "1.14.4"
WARP_SERVICE = "zapret2win-warp"
WARP_UNIT_PATH = f"/etc/systemd/system/{WARP_SERVICE}.service"
WARP_MIXED_PORT = 40480
WARP_PROBE_PORT = 40481
WARP_PREFIXES = ["162.159.192", "162.159.193", "162.159.195",
                 "188.114.96", "188.114.97", "188.114.98", "188.114.99"]
WARP_PORTS = [2408, 500, 1701, 4500]
WARP_API = "https://api.cloudflareclient.com/v0a5641/reg"
WARP_HEADERS = {
    "User-Agent": "1.1.1.1/6.38.9-5641 (Android 16.0.0)",
    "CF-Client-Version": "a-6.38.9-5641",
}
WARP_LIST_FILE = "zapret2win-hosts-warp.txt"
SEED_WARP = [
    "# Сайты, которые открываются через WARP (sing-box), а не через zapret.",
    "# Пополняется автоматически (меню WARP -> [3]) или вручную, по домену в строке.",
]
BROWSER_UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/130.0 Safari/537.36")


def warp_dir():
    return os.path.join(ZAPRET_TARGET, "warp")


def warp_path(name):
    return os.path.join(warp_dir(), name)


def warp_list_path():
    return os.path.join(ipset_dir(), WARP_LIST_FILE)


def singbox_path():
    return warp_path("sing-box")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, obj, mode=0o600):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    os.chmod(path, mode)


def list_entries(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            out = []
            for ln in f:
                d = ln.strip().lower()
                if d and not d.startswith("#") and d not in out:
                    out.append(d)
            return out
    except OSError:
        return []


def singbox_arch():
    m = platform.machine().lower()
    return {
        "x86_64": "amd64", "amd64": "amd64",
        "aarch64": "arm64", "arm64": "arm64",
        "armv7l": "armv7", "armv7": "armv7",
        "i386": "386", "i686": "386",
        "riscv64": "riscv64",
    }.get(m)


def install_singbox():
    """Скачивает официальную сборку sing-box с GitHub (один раз)."""
    os.makedirs(warp_dir(), exist_ok=True)
    exe = singbox_path()
    if os.access(exe, os.X_OK):
        rc, out, _ = run([exe, "version"], timeout=15)
        if rc == 0 and SING_BOX_VERSION in out:
            return
    arch = singbox_arch()
    if not arch:
        raise RuntimeError(f"нет сборки sing-box для архитектуры {platform.machine()}")
    name = f"sing-box-{SING_BOX_VERSION}-linux-{arch}"
    url = (f"https://github.com/SagerNet/sing-box/releases/download/"
           f"v{SING_BOX_VERSION}/{name}.tar.gz")
    head(f"Скачивание sing-box {SING_BOX_VERSION}...")
    info(url)
    import tarfile
    tmpdir = tempfile.mkdtemp(prefix="sing-box-")
    try:
        tpath = os.path.join(tmpdir, "sb.tar.gz")
        download(url, tpath)
        with tarfile.open(tpath, "r:gz") as tf:
            member = tf.getmember(f"{name}/sing-box")
            src = tf.extractfile(member)
            stop_warp(quiet=True)
            with open(exe + ".new", "wb") as dst:
                shutil.copyfileobj(src, dst)
        os.chmod(exe + ".new", 0o755)
        os.replace(exe + ".new", exe)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    ok(f"sing-box установлен: {exe}")


def warp_register():
    """Регистрирует бесплатное устройство WARP (как приложение 1.1.1.1)."""
    rc, out, errout = run([singbox_path(), "generate", "wg-keypair"], timeout=15)
    priv = pub = None
    for ln in out.splitlines():
        if ln.startswith("PrivateKey:"):
            priv = ln.split(":", 1)[1].strip()
        elif ln.startswith("PublicKey:"):
            pub = ln.split(":", 1)[1].strip()
    if not priv or not pub:
        raise RuntimeError(f"sing-box не сгенерировал ключи WireGuard: {errout}")

    body = json.dumps({
        "fcm_token": "", "install_id": "", "key": pub, "locale": "en_US",
        "model": "PC", "tos": datetime.now().astimezone().isoformat(timespec="milliseconds"),
        "serial_number": "", "os_version": "16.0.0",
        "key_type": "curve25519", "tunnel_type": "wireguard",
    }).encode()
    head("Регистрация устройства WARP...")
    headers = dict(WARP_HEADERS)
    headers["Content-Type"] = "application/json; charset=UTF-8"
    try:
        req = urllib.request.Request(WARP_API, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        cfg = data.get("config")
        if not cfg and data.get("id") and data.get("token"):
            h2 = dict(WARP_HEADERS)
            h2["Authorization"] = f"Bearer {data['token']}"
            req = urllib.request.Request(f"{WARP_API}/{data['id']}", headers=h2)
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            cfg = data.get("config")
    except Exception as e:
        raise RuntimeError(
            f"не удалось зарегистрировать WARP: {e}\n"
            "Можно импортировать готовый WireGuard-конфиг WARP (wgcf, WarpGen): "
            "--action warp-import --warp-config <файл>")
    if not cfg or not cfg.get("peers"):
        raise RuntimeError("ответ WARP не содержит конфигурации туннеля")
    reserved = [0, 0, 0]
    try:
        import base64
        reserved = list(base64.b64decode(cfg.get("client_id", "")))[:3] or [0, 0, 0]
    except Exception:
        pass
    addrs = cfg.get("interface", {}).get("addresses", {})
    write_json(warp_path("account.json"), {
        "private_key": priv,
        "peer_public_key": cfg["peers"][0]["public_key"],
        "address_v4": addrs.get("v4"),
        "address_v6": addrs.get("v6"),
        "reserved": reserved,
        "device_id": data.get("id"),
        "token": data.get("token"),
        "source": "register",
    })
    ok("Устройство WARP зарегистрировано")


def warp_import(path):
    """Импорт WireGuard-конфига WARP (wgcf-profile.conf, WarpGen и т.п.)."""
    if not path or not os.path.isfile(path):
        raise RuntimeError(f"файл конфига не найден: {path}")
    kv = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for ln in f:
            m = re.match(r"^\s*([A-Za-z]+)\s*=\s*(.+?)\s*$", ln)
            if m:
                kv[m.group(1).lower()] = m.group(2)
    if not kv.get("privatekey") or not kv.get("publickey"):
        raise RuntimeError("в конфиге нет PrivateKey/PublicKey")
    v4 = v6 = None
    for a in kv.get("address", "").split(","):
        a = re.sub(r"/\d+$", "", a.strip())
        if ":" in a:
            v6 = a
        elif a:
            v4 = a
    reserved = [0, 0, 0]
    parts = [int(x) for x in re.split(r"[,\s]+", kv.get("reserved", "")) if x.isdigit()]
    if len(parts) == 3:
        reserved = parts
    os.makedirs(warp_dir(), exist_ok=True)
    write_json(warp_path("account.json"), {
        "private_key": kv["privatekey"], "peer_public_key": kv["publickey"],
        "address_v4": v4, "address_v6": v6, "reserved": reserved, "source": "import",
    })
    try:
        os.remove(warp_path("state.json"))
    except OSError:
        pass
    ok("Конфиг WARP импортирован, узел будет подобран заново")


def warp_endpoint_json(acc, endpoint):
    ip, port = endpoint.rsplit(":", 1)
    addr = []
    if acc.get("address_v4"):
        addr.append(f"{acc['address_v4']}/32")
    if acc.get("address_v6"):
        addr.append(f"{acc['address_v6']}/128")
    return {
        "type": "wireguard", "tag": "warp", "mtu": 1280,
        "address": addr,
        "private_key": acc["private_key"],
        "peers": [{
            "address": ip, "port": int(port),
            "public_key": acc["peer_public_key"],
            "allowed_ips": ["0.0.0.0/0", "::/0"],
            "persistent_keepalive_interval": 25,
            "reserved": [int(x) for x in acc.get("reserved", [0, 0, 0])],
        }],
    }


def write_warp_rules():
    """rule-set для sing-box из списка WARP; sing-box перечитывает его сам."""
    doms = list_entries(warp_list_path()) or ["warp.invalid"]
    write_json(warp_path("rules-warp.json"),
               {"version": 2, "rules": [{"domain_suffix": doms}]}, mode=0o644)
    write_warp_dns_script()
    if warp_tun_exists():
        apply_warp_dns()


WARP_TUN = "zapret2warp"
# Свои адреса, диапазон FakeIP и номера таблицы/правил маршрутизации —
# намеренно НЕ значения sing-box по умолчанию (172.19.0.1/30, 198.18.0.0/15,
# таблица 2022, правила с 9000). Их же используют другие клиенты на
# sing-box в режиме TUN (Throne, Hiddify, NekoBox...): при одновременной
# работе адреса и таблицы совпадали, и трафик/DNS уходил не в тот туннель.
WARP_TUN_ADDR4 = "172.31.251.1/30"
WARP_TUN_DNS4 = "172.31.251.2"
WARP_TUN_ADDR6 = "fd7a:7a70:7761::1/126"
WARP_FAKE4 = "10.249.0.0/16"
WARP_FAKE4_PREFIX = "10.249."
WARP_FAKE6 = "fd7a:7a70:fa4e::/64"
WARP_RT_TABLE = 2649
WARP_RT_RULE = 8640


def warp_dns_script_path():
    return warp_path("dns-setup.sh")


def write_warp_dns_script():
    """
    Скрипт, который направляет DNS-запросы доменов из списка WARP в sing-box.

    Системный резолвер (systemd-resolved) сам в TUN не ходит: он шлёт запросы
    DNS-серверу сетевой карты, и домены WARP получали обычные адреса вместо
    FakeIP — в туннель ничего не попадало, сайты не открывались. Здесь для
    интерфейса TUN задаются DNS-сервер sing-box и «маршрутные домены»
    (~домен): запросы только этих доменов и их поддоменов идут в sing-box,
    остальной DNS не меняется. Выполняется и службой (ExecStartPost), чтобы
    настройка переживала перезагрузку.
    """
    script = f"""#!/bin/sh
# Сгенерировано zapret2-linux: DNS доменов WARP -> sing-box (FakeIP)
IF={WARP_TUN}
LIST='{warp_list_path()}'
command -v resolvectl >/dev/null 2>&1 || exit 0
i=0
while [ $i -lt 30 ] && ! ip link show "$IF" >/dev/null 2>&1; do sleep 0.5; i=$((i+1)); done
ip link show "$IF" >/dev/null 2>&1 || exit 0
DOMS=$(grep -v '^[[:space:]]*#' "$LIST" 2>/dev/null | tr -d ' \\t\\r' | grep . | sed 's/^/~/' | tr '\\n' ' ')
resolvectl dns "$IF" {WARP_TUN_DNS4} || exit 0
if [ -n "$DOMS" ]; then resolvectl domain "$IF" $DOMS; else resolvectl domain "$IF" ""; fi
resolvectl default-route "$IF" false 2>/dev/null
resolvectl flush-caches 2>/dev/null
exit 0
"""
    os.makedirs(warp_dir(), exist_ok=True)
    with open(warp_dns_script_path(), "w", encoding="utf-8") as f:
        f.write(script)
    os.chmod(warp_dns_script_path(), 0o755)


def warp_tun_exists():
    return os.path.isdir(f"/sys/class/net/{WARP_TUN}")


def apply_warp_dns():
    if which("resolvectl"):
        run(["/bin/sh", warp_dns_script_path()], timeout=40)


def check_warp_dns():
    """Проверяет, что домен из списка WARP действительно получает FakeIP."""
    doms = list_entries(warp_list_path())
    if not doms:
        return
    try:
        ips = {i[4][0] for i in socket.getaddrinfo(doms[0], 443, socket.AF_INET, socket.SOCK_STREAM)}
    except OSError as e:
        ips = set()
        warn(f"DNS: {doms[0]} не разрешается ({e})")
    if any(ip.startswith(WARP_FAKE4_PREFIX) for ip in ips):
        ok(f"DNS доменов WARP идёт в туннель ({doms[0]} -> {sorted(ips)[0]})")
        return
    warn(f"DNS: {doms[0]} получает обычный адрес ({', '.join(sorted(ips)) or 'нет'}), "
         f"а не адрес туннеля {WARP_FAKE4_PREFIX}x.x — сайт пойдёт мимо WARP.")
    if not which("resolvectl"):
        info("В системе нет systemd-resolved: автоматическая настройка DNS для WARP не поддерживается.")
    else:
        info(f"Проверьте: resolvectl status {WARP_TUN}; запись домена в /etc/hosts.")


# --- WARP через MASQUE (usque) ---------------------------------------------
# Запасной транспорт, когда WireGuard к Cloudflare не проходит. usque —
# открытая реализация MASQUE-режима клиента WARP: туннель через HTTP/3
# (QUIC, UDP) или HTTP/2 (обычный TCP 443). usque отдаёт туннель как
# локальный SOCKS5, sing-box направляет в него домены из списка WARP.
# «Узел» такого транспорта записывается как masque:<h3|h2>:<порт>.

USQUE_VERSION = "4.2.1"
USQUE_SERVICE = "zapret2win-warp-masque"
USQUE_UNIT_PATH = f"/etc/systemd/system/{USQUE_SERVICE}.service"
USQUE_PORT = 40482
USQUE_PROBE_PORT = 40483
MASQUE_VARIANTS = ["masque:h3:443", "masque:h3:4500", "masque:h3:500",
                   "masque:h3:1701", "masque:h2:443"]


def is_masque(endpoint):
    return str(endpoint).startswith("masque:")


def usque_path():
    return warp_path("usque")


def usque_config():
    return warp_path("usque.json")


def usque_arch():
    return {"amd64": "amd64", "arm64": "arm64", "armv7": "armv7", "386": "386"}.get(singbox_arch() or "")


def install_usque():
    """Скачивает официальную сборку usque с GitHub (один раз)."""
    exe = usque_path()
    if os.access(exe, os.X_OK):
        rc, out, errout = run([exe, "version"], timeout=15)
        if rc == 0 and USQUE_VERSION in (out + errout):
            return
    arch = usque_arch()
    if not arch:
        raise RuntimeError(f"нет сборки usque для архитектуры {platform.machine()}")
    url = (f"https://github.com/Diniboy1123/usque/releases/download/"
           f"v{USQUE_VERSION}/usque_{USQUE_VERSION}_linux_{arch}.zip")
    head(f"Скачивание usque {USQUE_VERSION} (WARP через MASQUE)...")
    info(url)
    import zipfile
    os.makedirs(warp_dir(), exist_ok=True)
    tmpdir = tempfile.mkdtemp(prefix="usque-")
    try:
        zpath = os.path.join(tmpdir, "usque.zip")
        download(url, zpath)
        with zipfile.ZipFile(zpath) as zf, zf.open("usque") as src, open(exe + ".new", "wb") as dst:
            shutil.copyfileobj(src, dst)
        os.chmod(exe + ".new", 0o755)
        os.replace(exe + ".new", exe)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    ok(f"usque установлен: {exe}")


def usque_register():
    """Регистрация устройства WARP для MASQUE (отдельная от WireGuard)."""
    if os.path.isfile(usque_config()):
        return
    head("Регистрация устройства WARP (MASQUE)...")
    rc, out, errout = run([usque_path(), "-c", usque_config(), "register", "-a", "-n", "zapret2"],
                          timeout=90)
    if rc != 0 or not os.path.isfile(usque_config()):
        try:
            os.remove(usque_config())
        except OSError:
            pass
        raise RuntimeError("не удалось зарегистрировать WARP (MASQUE):\n"
                           + "\n".join((errout or out).splitlines()[-4:]))
    os.chmod(usque_config(), 0o600)
    ok("Устройство WARP (MASQUE) зарегистрировано")


def usque_args(endpoint, port):
    _, proto, cport = endpoint.split(":")
    args = [usque_path(), "-c", usque_config(), "socks", "-b", "127.0.0.1",
            "-p", str(port), "-P", cport]
    if proto == "h2":
        args.append("--http2")
    return args


def masque_outbound(port):
    return {"type": "socks", "tag": "warp", "server": "127.0.0.1",
            "server_port": port, "version": "5"}


def ensure_masque():
    """usque установлен и зарегистрирован; False (с сохранённой ошибкой), если нет."""
    try:
        install_usque()
        usque_register()
        return True
    except Exception as e:
        lines = str(e).splitlines() or ["ошибка"]
        set_warp_error("WARP через MASQUE не подготовлен: " + lines[0], lines[1:])
        return False


def ipv6_available():
    return os.path.isfile("/proc/net/if_inet6")


def build_warp_config(endpoint):
    masque = is_masque(endpoint)
    acc = None if masque else read_json(warp_path("account.json"))
    write_warp_rules()
    # Без IPv6 в системе sing-box не сможет назначить TUN v6-адрес и упадёт.
    v6 = ipv6_available()
    fake = {"type": "fakeip", "tag": "fakeip", "inet4_range": WARP_FAKE4}
    if v6:
        fake["inet6_range"] = WARP_FAKE6
    return {
        "log": {"level": "warn", "timestamp": True},
        "dns": {
            "servers": [
                {"type": "local", "tag": "local"},
                fake,
                # Через SOCKS usque DNS надёжнее по TCP.
                {"type": "tcp" if masque else "udp", "tag": "warp-dns",
                 "server": "1.1.1.1", "detour": "warp"},
            ],
            "rules": [{"inbound": ["tun-in"], "rule_set": ["warp-domains"],
                       "query_type": ["A", "AAAA"], "server": "fakeip"}],
            "final": "local",
        },
        "endpoints": [] if masque else [warp_endpoint_json(acc, endpoint)],
        "inbounds": [
            {
                "type": "tun", "tag": "tun-in", "interface_name": "zapret2warp",
                "address": [WARP_TUN_ADDR4] + ([WARP_TUN_ADDR6] if v6 else []),
                "mtu": 1400,
                "auto_route": True,
                # В TUN идут только FakeIP: остальной трафик мимо sing-box.
                "route_address": [WARP_FAKE4] + ([WARP_FAKE6] if v6 else []),
                "iproute2_table_index": WARP_RT_TABLE,
                "iproute2_rule_index": WARP_RT_RULE,
            },
            {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1",
             "listen_port": WARP_MIXED_PORT},
        ],
        "outbounds": [{"type": "direct", "tag": "direct"}]
                     + ([masque_outbound(USQUE_PORT)] if masque else []),
        "route": {
            "rule_set": [{"type": "local", "tag": "warp-domains", "format": "source",
                          "path": warp_path("rules-warp.json")}],
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"inbound": ["tun-in", "mixed-in"], "action": "resolve", "server": "warp-dns"},
            ] + ([
                # usque не принимает UDP от sing-box по SOCKS («udp address is not
                # associated with tcp»). Отклоняем UDP сразу: браузер мгновенно
                # переходит с QUIC на обычный TCP вместо ожидания тайм-аута.
                {"inbound": ["tun-in", "mixed-in"], "network": "udp", "action": "reject"},
            ] if masque else []) + [
                {"inbound": ["tun-in", "mixed-in"], "outbound": "warp"},
            ],
            "final": "direct",
            "auto_detect_interface": True,
            "default_domain_resolver": "local",
        },
        "experimental": {"cache_file": {"enabled": True, "path": warp_path("cache.db"),
                                        "store_fakeip": True}},
    }


WARP_TRACE_LAST = ""   # чем закончилась последняя проверка туннеля
WARP_EXIT = {}         # откуда WARP выходит в интернет: loc (страна), colo (узел), ip


def warp_trace(port, timeout=5.0):
    """
    Запрос cdn-cgi/trace к 1.1.1.1 через прокси sing-box: мс или -1.
    Ответ «warp=on» подтверждает, что трафик идёт через WARP.

    Прокси задан и для http, и для https: 1.1.1.1 на 80-м порту может
    ответить перенаправлением на https, и без https-прокси urllib пошёл бы
    по нему НАПРЯМУЮ, мимо туннеля (ответ «warp=off» при рабочем туннеле).
    """
    global WARP_TRACE_LAST
    proxy = f"http://127.0.0.1:{port}"
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": proxy, "https": proxy}),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    for url in ("https://1.1.1.1/cdn-cgi/trace", "http://1.1.1.1/cdn-cgi/trace"):
        t0 = time.monotonic()
        try:
            with opener.open(url, timeout=timeout) as r:
                text = r.read(4096).decode("utf-8", "replace")
            m = re.search(r"warp=(\w+)", text)
            if m and m.group(1) in ("on", "plus"):
                WARP_TRACE_LAST = f"{url}: warp={m.group(1)}"
                for key in ("loc", "colo", "ip"):
                    mm = re.search(rf"(?m)^{key}=(\S+)", text)
                    if mm:
                        WARP_EXIT[key] = mm.group(1)
                return int((time.monotonic() - t0) * 1000)
            WARP_TRACE_LAST = (f"{url}: ответ получен, но " +
                               (f"warp={m.group(1)}" if m else "без поля warp")
                               + " — трафик идёт не через WARP")
        except Exception as e:
            WARP_TRACE_LAST = f"{url}: {e.__class__.__name__}: {e}"
            if isinstance(e, (socket.timeout, TimeoutError)) or "timed out" in str(e):
                break   # туннель не отвечает — второй адрес не поможет
    return -1


def warp_ping(port, tries=3, timeout=3.0):
    """
    Задержка через туннель: время установки TCP-соединения с 1.1.1.1:443
    через прокси sing-box (CONNECT), лучший из нескольких замеров, мс.
    Это примерно один круговой пробег пакета (RTT). Время полного
    HTTPS-запроса из warp_trace в 3–4 раза больше и для сравнения узлов
    не годится.
    """
    best = -1
    for _ in range(tries):
        try:
            t0 = time.monotonic()
            with socket.create_connection(("127.0.0.1", port), timeout=timeout) as s:
                s.settimeout(timeout)
                s.sendall(b"CONNECT 1.1.1.1:443 HTTP/1.1\r\nHost: 1.1.1.1:443\r\n\r\n")
                reply = s.recv(256)
            ms = int((time.monotonic() - t0) * 1000)
            if reply.split(b" ", 2)[1:2] == [b"200"] and (best < 0 or ms < best):
                best = ms
        except (OSError, IndexError):
            pass
    return best


def wait_local_port(port, timeout=4.0, proc=None, alive=None):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if proc is not None and proc.poll() is not None:
            return False
        if alive is not None and not alive():
            return False
        if tcp_ok("127.0.0.1", port, timeout=0.3):
            return True
        time.sleep(0.15)
    return False


def test_warp_endpoint(endpoint):
    """Пробный туннель: 3 запроса, задержка — лучший из 2-го и 3-го."""
    masque = is_masque(endpoint)
    probe = warp_path("probe.json")
    cfg = {
        "log": {"level": "info"},
        "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1",
                      "listen_port": WARP_PROBE_PORT}],
        "route": {"final": "warp", "auto_detect_interface": True},
    }
    if masque:
        cfg["outbounds"] = [masque_outbound(USQUE_PROBE_PORT)]
    else:
        cfg["endpoints"] = [warp_endpoint_json(read_json(warp_path("account.json")), endpoint)]
    write_json(probe, cfg)
    uproc = ulog = None
    if masque:
        ulog = open(warp_path("probe-usque.log"), "w")
        uproc = subprocess.Popen(usque_args(endpoint, USQUE_PROBE_PORT),
                                 stdout=ulog, stderr=subprocess.STDOUT)
    logf = open(warp_path("probe.log"), "w")
    proc = subprocess.Popen([singbox_path(), "run", "-c", probe],
                            stdout=logf, stderr=subprocess.STDOUT)
    try:
        if uproc and not wait_local_port(USQUE_PROBE_PORT, 8.0, uproc):
            return -1
        if not wait_local_port(WARP_PROBE_PORT, 8.0, proc):
            return -1
        if masque:
            # MASQUE-туннель устанавливается дольше WireGuard: даём до 12 с.
            for _ in range(3):
                if warp_trace(WARP_PROBE_PORT, 4.0) >= 0:
                    break
            else:
                return -1
        elif warp_trace(WARP_PROBE_PORT, 4.0) < 0:
            return -1
        # Туннель подтверждён (warp=on). Для сравнения узлов меряем задержку.
        ping = warp_ping(WARP_PROBE_PORT)
        if ping >= 2:   # 0–1 мс значило бы, что замер не дошёл до туннеля
            return ping
        times = [t for t in (warp_trace(WARP_PROBE_PORT, 3.0) for _ in range(2)) if t >= 0]
        return min(times) if times else -1
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
        logf.close()
        if uproc:
            uproc.terminate()
            try:
                uproc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                uproc.kill()
            ulog.close()


def find_warp_endpoint(skip=()):
    """Автоподбор узла Cloudflare: подсети WARP x официальные порты."""
    import random
    was_running = warp_running()
    stop_warp(quiet=True)
    have_wg = os.path.isfile(warp_path("account.json"))
    cands = (["162.159.192.1:2408"] + [f"{p}.{random.randint(1, 254)}:2408" for p in WARP_PREFIXES]
             if have_wg else [])
    results = []
    head("Подбор узла Cloudflare WARP...")

    def check(ep):
        if ep in skip:
            return
        sys.stdout.write(f"    {ep:<22} ")
        sys.stdout.flush()
        ms = test_warp_endpoint(ep)
        if ms >= 0:
            results.append({"endpoint": ep, "ms": ms})
            print(_c(C.GREEN, f"{ms} мс"))
        else:
            print(_c(C.GRAY, "нет ответа"))

    for c in cands:
        check(c)
    if have_wg and len(results) < 2:
        for port in WARP_PORTS[1:]:
            for p in WARP_PREFIXES:
                check(f"{p}.{random.randint(1, 254)}:{port}")
                if len(results) >= 3:
                    break
            if len(results) >= 3:
                break
    if not results:
        # WireGuard не проходит — пробуем WARP через MASQUE (HTTP/3, затем HTTP/2).
        warn("WireGuard к Cloudflare не проходит — пробую WARP через MASQUE...")
        wg_log = file_tail(warp_path("probe.log"), 3)
        for stale in ("probe-usque.log", "probe.log"):
            try:
                os.remove(warp_path(stale))
            except OSError:
                pass
        if not ensure_masque():
            # usque не скачался или не зарегистрировался: это и есть причина.
            # Оставляем её в «Последней ошибке», не затирая общим сообщением.
            warn("MASQUE недоступен: причина выше.")
            return None
        # Проверяем все варианты и берём самый быстрый, а не первый рабочий.
        for v in MASQUE_VARIANTS:
            check(v)
        if not results:
            set_warp_error(
                "Ни один узел WARP не ответил (ни WireGuard, ни MASQUE).",
                ["usque (MASQUE), последняя проба:"]
                + (file_tail(warp_path("probe-usque.log"), 8) or ["<usque ничего не вывел>"])
                + ["sing-box, последняя проба MASQUE:"] + file_tail(warp_path("probe.log"), 4)
                + ["WireGuard, последняя проба:"] + wg_log)
            warn("Похоже, провайдер блокирует WARP целиком.")
            info("Попробуйте при запущенном zapret; иначе нужен другой выход (свой VPS).")
            return None
    results.sort(key=lambda r: r["ms"])
    if not results:
        set_warp_error("Ни один узел WARP не ответил.",
                       ["Журнал последней пробы sing-box:"] + file_tail(warp_path("probe.log"), 6))
        warn("Похоже, провайдер блокирует WARP целиком.")
        info("Попробуйте при запущенном zapret; иначе нужен другой выход (свой VPS).")
        return None
    write_json(warp_path("state.json"), {"best": results[0]["endpoint"], "ranked": results,
                                         "tested": datetime.now().isoformat(timespec="seconds")})
    ok(f"Лучший узел: {results[0]['endpoint']} (задержка {results[0]['ms']} мс)")
    if len(results) > 1:
        info("Остальные: " + ", ".join(f"{r['endpoint']} {r['ms']} мс" for r in results[1:4]))
    if was_running:
        start_warp()
    return results[0]["endpoint"]


def warp_running():
    rc, _, _ = run(["systemctl", "is-active", "--quiet", WARP_SERVICE], timeout=10)
    return rc == 0


def warp_enabled():
    return os.path.isfile(warp_path("enabled"))


def usque_unit_content(endpoint):
    return f"""[Unit]
Description=Zapret2 WARP over MASQUE (usque)
After=network-online.target {SERVICE_NAME}.service
Wants=network-online.target

[Service]
Type=simple
ExecStart={' '.join(usque_args(endpoint, USQUE_PORT))}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
"""


def usque_running():
    rc, _, _ = run(["systemctl", "is-active", "--quiet", USQUE_SERVICE], timeout=10)
    return rc == 0


def usque_journal(lines=10):
    rc, out, _ = run(["journalctl", "-u", USQUE_SERVICE, "-n", str(lines),
                      "--no-pager", "-o", "cat"], timeout=15)
    return [ln for ln in out.splitlines() if ln.strip()] if rc == 0 else []


def warp_unit_content():
    return f"""[Unit]
Description=Zapret2 WARP (sing-box) for sites zapret can't open
After=network-online.target {SERVICE_NAME}.service {USQUE_SERVICE}.service
Wants=network-online.target

[Service]
Type=simple
ExecStart={singbox_path()} run -c {warp_path('config.json')}
ExecStartPost=-/bin/sh {warp_dns_script_path()}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
"""


def file_tail(path, lines=12):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = re.sub(r"\x1b\[[0-9;]*m", "", f.read())  # цвета sing-box
            return [ln.rstrip() for ln in text.splitlines() if ln.strip()][-lines:]
    except OSError:
        return []


def set_warp_error(message, details=()):
    """Запоминает причину сбоя: её видно в меню WARP, а не только при запуске."""
    details = list(details)
    if WARP_TRACE_LAST and ("узел" in message.lower() or "трафик" in message):
        details.insert(0, f"Проверка туннеля: {WARP_TRACE_LAST}")
    err(message)
    for ln in details:
        print(_c(C.GRAY, f"    {ln}"))
    try:
        os.makedirs(warp_dir(), exist_ok=True)
        with open(warp_path("last-error.txt"), "w", encoding="utf-8") as f:
            f.write(f"{datetime.now().isoformat(timespec='seconds')} {message}\n")
            f.write("\n".join(details) + "\n")
    except OSError:
        pass


def clear_warp_error():
    try:
        os.remove(warp_path("last-error.txt"))
    except OSError:
        pass


def journal_tail(lines=15):
    rc, out, _ = run(["journalctl", "-u", WARP_SERVICE, "-n", str(lines),
                      "--no-pager", "-o", "cat"], timeout=15)
    return [ln for ln in out.splitlines() if ln.strip()] if rc == 0 else []


def start_warp_process(endpoint):
    """
    'ok', 'crash' (sing-box завершился: ошибка конфига, TUN, прав — перебор
    узлов не поможет) или 'notunnel' (sing-box работает, но трафик через
    WARP не идёт — стоит попробовать другой узел).
    """
    if is_masque(endpoint):
        if not ensure_masque():
            return "crash"
        with open(USQUE_UNIT_PATH, "w", encoding="utf-8") as f:
            f.write(usque_unit_content(endpoint))
        run(["systemctl", "daemon-reload"], timeout=60)
        run(["systemctl", "reset-failed", USQUE_SERVICE], timeout=30)
        run(["systemctl", "restart", USQUE_SERVICE], timeout=60)
        if not wait_local_port(USQUE_PORT, 15.0, alive=usque_running):
            set_warp_error("usque (MASQUE) не запустился.", usque_journal())
            return "crash"
    write_json(warp_path("config.json"), build_warp_config(endpoint))
    rc, out, errout = run([singbox_path(), "check", "-c", warp_path("config.json")], timeout=30)
    if rc != 0:
        set_warp_error("Конфиг sing-box не прошёл проверку.", (errout or out).splitlines())
        return "crash"
    with open(WARP_UNIT_PATH, "w", encoding="utf-8") as f:
        f.write(warp_unit_content())
    run(["systemctl", "daemon-reload"], timeout=60)
    run(["systemctl", "reset-failed", WARP_SERVICE], timeout=30)
    run(["systemctl", "restart", WARP_SERVICE], timeout=60)
    # Создание TUN и маршрутов может занять несколько секунд.
    if not wait_local_port(WARP_MIXED_PORT, 30.0, alive=warp_running):
        if warp_running():
            set_warp_error("sing-box не открыл локальный порт за 30 секунд.", journal_tail())
        else:
            set_warp_error("Служба sing-box завершилась при запуске.", journal_tail())
        return "crash"
    for _ in range(5 if is_masque(endpoint) else 3):
        if not warp_running():
            break
        if warp_trace(WARP_MIXED_PORT, 6.0) >= 0:
            clear_warp_error()
            return "ok"
        time.sleep(1)
    if not warp_running():
        set_warp_error("Служба sing-box завершилась.", journal_tail())
        return "crash"
    set_warp_error(f"Через узел {endpoint} не идёт трафик.",
                   (usque_journal(6) if is_masque(endpoint) else []) + journal_tail(8))
    return "notunnel"


def start_warp():
    ensure_root(sys.argv)
    if not which("systemctl"):
        set_warp_error("Для WARP нужен systemd (sing-box запускается как служба).")
        return
    try:
        if not os.access(singbox_path(), os.X_OK):
            install_singbox()
    except Exception as e:
        lines = str(e).splitlines() or ["ошибка"]
        set_warp_error(lines[0], lines[1:])
        return
    if not os.path.isfile(warp_path("account.json")) and not os.path.isfile(usque_config()):
        try:
            warp_register()
        except Exception as e:
            # Не фатально: остаётся транспорт MASQUE со своей регистрацией.
            warn(str(e).splitlines()[0])
    stop_warp(quiet=True)
    st = read_json(warp_path("state.json")) or {}
    ep = st.get("best") or find_warp_endpoint()
    if not ep:
        return
    head(f"Запуск sing-box (узел {ep})...")
    r = start_warp_process(ep)
    if r == "notunnel":
        warn(f"Узел {ep} не отвечает, подбираю другой...")
        stop_warp(quiet=True)
        ep = find_warp_endpoint(skip=(ep,))
        r = start_warp_process(ep) if ep else "crash"
    if r != "ok":
        stop_warp(quiet=True)
        err("WARP не запущен. Причина выше; она же в меню WARP и в журнале:")
        info(f"journalctl -u {WARP_SERVICE}")
        return
    if warp_enabled():
        run(["systemctl", "enable", WARP_SERVICE], timeout=60)
        if is_masque(ep):
            run(["systemctl", "enable", USQUE_SERVICE], timeout=60)
        else:
            run(["systemctl", "disable", USQUE_SERVICE], timeout=60)
    apply_warp_dns()
    flush_dns()
    ok(f"WARP работает через узел {ep}. Сайтов в списке WARP: {len(list_entries(warp_list_path()))}")
    report_warp_exit()
    check_warp_dns()


def warp_starter_pid():
    """PID фонового запуска WARP, если он ещё идёт."""
    try:
        with open(warp_path("starting.pid")) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def start_warp_background():
    """
    Запуск WARP следом за zapret, не задерживая сам обход: проверка узла
    (а при необходимости и подбор нового) идёт в отдельном процессе.
    """
    if warp_starter_pid():
        info("WARP уже запускается в фоне")
        return
    log = warp_path("start.log")
    os.makedirs(warp_dir(), exist_ok=True)
    with open(log, "w", encoding="utf-8") as f:
        p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--action", "warp-start"],
                             stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT,
                             start_new_session=True)
    with open(warp_path("starting.pid"), "w") as f:
        f.write(str(p.pid))
    info(f"WARP запускается в фоне — статус в меню [11], журнал: {log}")


def warp_start_action():
    """Действие warp-start: запуск WARP, если он включён (используется фоном)."""
    try:
        if warp_enabled():
            start_warp()
        else:
            info("WARP выключен")
    finally:
        try:
            os.remove(warp_path("starting.pid"))
        except OSError:
            pass


def stop_warp(quiet=False):
    # Остановка во время фонового запуска WARP: прерываем и запуск, иначе он
    # поднимет sing-box уже после остановки обхода. Себя не трогаем.
    pid = warp_starter_pid()
    if pid and pid != os.getpid():
        try:
            os.killpg(pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            os.remove(warp_path("starting.pid"))
        except OSError:
            pass
    if os.path.isfile(WARP_UNIT_PATH):
        run(["systemctl", "stop", WARP_SERVICE], timeout=60)
    run(["pkill", "-f", f"{singbox_path()} run"])
    if os.path.isfile(USQUE_UNIT_PATH):
        run(["systemctl", "stop", USQUE_SERVICE], timeout=60)
    run(["pkill", "-f", f"{usque_path()} -c"])
    if not quiet:
        ok("WARP остановлен")


def enable_warp(assume_yes=False):
    ensure_root(sys.argv)
    os.makedirs(warp_dir(), exist_ok=True)
    os.makedirs(ipset_dir(), exist_ok=True)
    merge_list_file(warp_list_path(), SEED_WARP)
    with open(warp_path("enabled"), "w") as f:
        f.write("1")
    start_warp()
    if warp_running():
        ans = "y"
        if not assume_yes:
            try:
                ans = input("  Проверить сайты из списков и перенести в WARP те, "
                            "что не открываются через zapret? (Y/n) ").strip().lower()
            except EOFError:
                ans = "y"
        if ans not in ("n", "no", "н", "нет"):
            update_warp_routes()


def disable_warp():
    ensure_root(sys.argv)
    try:
        os.remove(warp_path("enabled"))
    except OSError:
        pass
    stop_warp()
    if os.path.isfile(WARP_UNIT_PATH):
        run(["systemctl", "disable", WARP_SERVICE], timeout=60)
    if os.path.isfile(USQUE_UNIT_PATH):
        run(["systemctl", "disable", USQUE_SERVICE], timeout=60)
    flush_dns()


def https_probe(domain, proxy=None, timeout=8.0):
    """
    Успех — получен HTTP-ответ и прочитано 64 КБ тела (или оно кончилось
    раньше): так ловится и обрыв «16 КБ». Код ответа не важен.
    """
    handlers = [urllib.request.ProxyHandler({"https": proxy} if proxy else {}),
                urllib.request.HTTPSHandler(context=ssl.create_default_context())]

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None

    opener = urllib.request.build_opener(NoRedirect, *handlers)
    req = urllib.request.Request(f"https://{domain}/", headers={"User-Agent": BROWSER_UA})
    try:
        try:
            resp = opener.open(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            resp = e  # 3xx/4xx/5xx — сеть до сайта работает
        total = 0
        while total < 65536:
            chunk = resp.read(16384)
            if not chunk:
                return True
            total += len(chunk)
        return True
    except Exception:
        return False


def https_batch(domains, proxy=None):
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=16) as ex:
        return dict(zip(domains, ex.map(lambda d: https_probe(d, proxy), domains)))


def remove_hosts_domains(domains):
    """Убирает из нашего блока hosts строки доменов, переносимых в WARP."""
    names = set()
    for d in domains:
        names.add(d.lower())
        names.add("www." + d.lower())
    out, inside, changed = [], False, False
    for ln in read_hosts():
        if re.match(r"^\s*#.*DoH begin", ln):
            inside = True
        elif re.match(r"^\s*#.*DoH end", ln):
            inside = False
        elif inside:
            parts = ln.split()
            if len(parts) >= 2 and not ln.lstrip().startswith("#") and parts[1].lower() in names:
                changed = True
                continue
        out.append(ln)
    if changed:
        write_hosts(out)


def update_warp_routes():
    """WARP там, где не справляется zapret: перенос неоткрывающихся сайтов."""
    ensure_root(sys.argv)
    if not warp_running():
        err("WARP не запущен")
        return
    if not nfqws2_running():
        warn("zapret не запущен — в WARP попадут и сайты, которые zapret открыл бы сам")
    in_warp = set(list_entries(warp_list_path()))
    excl = set(list_entries(os.path.join(ipset_dir(), "zapret-hosts-user-exclude.txt")))
    cands = []
    for name in ("zapret-hosts-user.txt", "zapret-hosts-auto.txt"):
        for d in list_entries(os.path.join(ipset_dir(), name)):
            if d not in in_warp and d not in excl and d not in cands:
                cands.append(d)
    if not cands:
        info("Нечего проверять")
        return
    head(f"Проверка {len(cands)} сайтов через zapret...")
    direct = https_batch(cands)
    failed = [d for d in cands if not direct[d]]
    if failed:
        # Вторая попытка: случайный сбой не должен навсегда увести сайт в WARP
        # (домены из списка WARP zapret больше не обрабатывает).
        again = https_batch(failed)
        failed = [d for d in failed if not again[d]]
    info(f"открываются через zapret: {len(cands) - len(failed)}, не открываются: {len(failed)}")
    if not failed:
        ok("WARP не нужен ни одному сайту из списков")
        return
    head("Проверка неоткрывшихся через WARP...")
    via = https_batch(failed, proxy=f"http://127.0.0.1:{WARP_MIXED_PORT}")
    move = [d for d in failed if via[d]]
    dead = [d for d in failed if not via[d]]
    if move:
        merge_list_file(warp_list_path(), move)
        write_warp_rules()
        remove_hosts_domains(move)
        flush_dns()
        ok("Перенесено в WARP: " + ", ".join(move))
        time.sleep(1)   # sing-box перечитывает список
        check_warp_dns()
        info("Перезапустите браузер: он помнит старые адреса сайтов. Если в браузере включён "
             "«Безопасный DNS» (DNS через HTTPS), отключите его — иначе он обходит WARP.")
    if dead:
        info("Не открываются и через WARP (нет сайта на корне домена, геоблок или сбой): "
             + ", ".join(dead))
    info(f"Список WARP: {warp_list_path()} (можно править вручную)")


def report_warp_exit():
    """
    Показывает, из какой страны WARP выходит в интернет. Cloudflare сам
    выбирает ближайший узел, и из России это обычно российский узел: тогда
    сайты видят российский адрес, и сервисы, закрытые для России самими
    владельцами (ChatGPT, Claude, Spotify...), через WARP не откроются —
    WARP помогает только от блокировок на стороне провайдера.
    """
    if not WARP_EXIT:
        return
    write_json(warp_path("exit.json"), WARP_EXIT, mode=0o644)
    loc = WARP_EXIT.get("loc", "?")
    info(f"Выход WARP в интернет: страна {loc}, узел Cloudflare {WARP_EXIT.get('colo', '?')}, "
         f"адрес {WARP_EXIT.get('ip', '?')}")
    if loc == "RU":
        warn("Выход — российский узел Cloudflare. Сайты, заблокированные провайдером, откроются;")
        warn("сервисы, которые сами не пускают из России (ChatGPT, Claude, Spotify...), — нет.")


def warp_test(domains=None):
    """Проверка сайтов из списка WARP так, как их видит браузер (через DNS и TUN)."""
    ensure_root(sys.argv)
    if not warp_running():
        err("WARP не запущен")
        return
    doms = domains or list_entries(warp_list_path())
    if not doms:
        info("Список WARP пуст")
        return
    head("Проверка сайтов из списка WARP (как в браузере)...")
    for d in doms:
        try:
            ips = sorted({i[4][0] for i in socket.getaddrinfo(d, 443, socket.AF_INET, socket.SOCK_STREAM)})
        except OSError:
            ips = []
        via = "в туннель" if any(ip.startswith(WARP_FAKE4_PREFIX) for ip in ips) else "МИМО туннеля"
        res = _probe_tls(d, 4) if ips else "DNS: имя не разрешается"
        color = C.GREEN if res.startswith("OK") else C.RED
        print(f"    {d:<28} DNS {via:<13} {_c(color, res)}")
    print()
    info("«OK … 403 Forbidden» или страница «недоступно в вашем регионе» — отказ самого сайта, а не блокировка.")
    ex = read_json(warp_path("exit.json")) or {}
    if ex:
        info(f"Выход WARP: страна {ex.get('loc')}, узел {ex.get('colo')}")


def warp_status_line():
    st = read_json(warp_path("state.json")) or {}
    if warp_running():
        state = _c(C.GREEN, f"работает, узел {st.get('best')}")
    elif warp_starter_pid():
        state = _c(C.YELLOW, "запускается...")
    else:
        state = _c(C.GRAY, "не запущен")
    ex = read_json(warp_path("exit.json")) or {}
    where = f" | выход: {ex.get('loc')}/{ex.get('colo')}" if ex and warp_running() else ""
    print(f"  WARP: {'включён' if warp_enabled() else 'выключен'} | {state} | "
          f"сайтов в списке: {len(list_entries(warp_list_path()))}{where}")


def warp_menu():
    while True:
        print()
        warp_status_line()
        en = warp_enabled()
        if en and not warp_running() and not warp_starter_pid():
            le = file_tail(warp_path("last-error.txt"), 40)
            if le:
                print(_c(C.RED, "  Последняя ошибка:"))
                for ln in le:
                    print(_c(C.GRAY, f"    {ln}"))
        print(f"  [1] {'Выключить' if en else 'Включить'} WARP")
        print("  [2] Подобрать лучший узел Cloudflare заново")
        print("  [3] Проверить сайты и перенести в WARP те, что не открываются через zapret")
        print("  [4] Добавить домен в WARP вручную")
        print("  [5] Импортировать WireGuard-конфиг WARP (если регистрация не проходит)")
        print("  [6] Проверить сайты из списка WARP (как в браузере)")
        print("  [0] Назад")
        try:
            ch = input("\n  Выбор: ").strip()
        except EOFError:
            return
        try:
            warp_menu_action(ch, en)
        except Exception as e:
            set_warp_error(f"Ошибка: {e}")
        if ch == "0":
            return


def warp_menu_action(ch, en):
    """Одно действие меню WARP; исключения перехватывает warp_menu."""
    if ch == "1":
        disable_warp() if en else enable_warp()
    elif ch == "2":
        find_warp_endpoint()
    elif ch == "3":
        update_warp_routes()
    elif ch == "4":
        d = input("  Домен (например, example.com): ").strip().lower()
        if re.fullmatch(r"[a-z0-9.-]+\.[a-z0-9-]+", d):
            merge_list_file(warp_list_path(), [d])
            write_warp_rules()
            remove_hosts_domains([d])
            flush_dns()
            ok(f"{d} добавлен в WARP")
        else:
            err("Некорректный домен")
    elif ch == "5":
        warp_import(input("  Путь к .conf: ").strip())
        if warp_enabled():
            start_warp()
    elif ch == "6":
        warp_test()



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
        print("  [11] WARP для сайтов, которые не открывает zapret")
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
            elif choice == "11":
                warp_menu()
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
    "report": collect_report,
    "update": script_update,
    "uninstall": uninstall,
    "warp-on": None,
    "warp-off": None,
    "warp-scan": None,
    "warp-routes": None,
    "warp-import": None,
    "warp-start": None,
    "warp-test": None,
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
  report     подробный отчёт для поиска неисправностей (файл в /tmp)
  update     обновить сам скрипт из GitHub
  uninstall  удалить из системы
  warp-on      включить WARP для сайтов, которые не открывает zapret
  warp-off     выключить WARP
  warp-scan    подобрать лучший узел Cloudflare WARP
  warp-routes  проверить сайты и перенести неоткрывающиеся в WARP
  warp-import  импортировать WireGuard-конфиг WARP (--warp-config <файл>)
  warp-test    проверить сайты из списка WARP так, как их видит браузер
  warp-start   запустить WARP, если он включён (так обход запускает его следом)

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
    parser.add_argument("--warp-config", help="путь к WireGuard-конфигу WARP для warp-import")
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

    warp_actions = {
        "warp-on": lambda: enable_warp(assume_yes=args.yes),
        "warp-off": disable_warp,
        "warp-scan": lambda: (ensure_root(sys.argv), find_warp_endpoint()),
        "warp-routes": update_warp_routes,
        "warp-import": lambda: (ensure_root(sys.argv), warp_import(args.warp_config)),
        "warp-start": lambda: (ensure_root(sys.argv), warp_start_action()),
        "warp-test": warp_test,
    }
    if action in warp_actions:
        try:
            warp_actions[action]()
        except Exception as e:
            print()
            err(str(e))
            return 1
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
