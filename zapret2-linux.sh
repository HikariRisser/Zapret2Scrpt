#!/bin/sh
# -*- coding: utf-8 -*-
''':'
# ============================================================================
#  Zapret2 Linux — контроллер zapret2 (обход DPI) одним файлом.
#
#  Этот файл — одновременно сценарий оболочки и программа на Python: начало
#  (до строки из трёх апострофов) исполняет sh, остальное — Python 3.8+.
#  Других файлов рядом не нужно.
#
#  sh zapret2-linux.sh                 меню
#  sh zapret2-linux.sh install         действие (список: sh zapret2-linux.sh --help)
#  sh zapret2-linux.sh tunnel-on       любое действие из --help
#
#  Начало файла:
#    * находит Python 3.8+ (если его нет — предлагает установить);
#    * само запрашивает права root (sudo, doas, pkexec или su);
#    * при запуске двойным щелчком открывает окно терминала;
#    * при ошибке не закрывает окно, пока не нажата Enter.
# ============================================================================

# --- каталог лаунчера (с учётом символических ссылок) ---
SELF="$0"
if command -v readlink >/dev/null 2>&1 && readlink -f "$SELF" >/dev/null 2>&1; then
    SELF="$(readlink -f "$SELF")"
fi
DIR="$(cd "$(dirname "$SELF")" && pwd)"
PY_SCRIPT="$SELF"

say()  { printf '%s\n' "$*"; }
red()  { printf '\033[31m%s\033[0m\n' "$*"; }
yel()  { printf '\033[33m%s\033[0m\n' "$*"; }

# Держим окно открытым, если что-то пошло не так.
hold() {
    if [ -t 0 ] && [ -t 1 ]; then
        printf '\n  Нажмите Enter для выхода... '
        read -r _ || true
    fi
}

die() {
    say ""
    red "  [ОШИБКА] $1"
    [ -n "$2" ] && say "  $2"
    say ""
    hold
    exit "${3:-1}"
}

# --- запуск двойным щелчком: открыть терминал и перезапуститься в нём ---
if [ ! -t 0 ] && [ -z "$ZAPRET2_IN_TERMINAL" ] && { [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; }; then
    export ZAPRET2_IN_TERMINAL=1
    for term in x-terminal-emulator gnome-terminal konsole xfce4-terminal mate-terminal \
                lxterminal tilix kitty alacritty xterm; do
        command -v "$term" >/dev/null 2>&1 || continue
        case "$term" in
            gnome-terminal) exec "$term" -- sh "$SELF" "$@" ;;
            *)              exec "$term" -e sh "$SELF" "$@" ;;
        esac
    done
    # Терминал не найден — продолжаем как есть.
fi

[ "$(uname -s)" = "Linux" ] || die "Этот скрипт для Linux (система: $(uname -s))." \
    "Для Windows используйте Zapret2Windows.cmd"

# --- Python 3.8+ ---
find_python() {
    for py in python3 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python; do
        command -v "$py" >/dev/null 2>&1 || continue
        if "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
            command -v "$py"
            return 0
        fi
    done
    return 1
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif command -v sudo  >/dev/null 2>&1; then sudo "$@"
    elif command -v doas  >/dev/null 2>&1; then doas "$@"
    elif command -v pkexec >/dev/null 2>&1; then pkexec "$@"
    else su -c "$*" root
    fi
}

install_python() {
    if   command -v apt-get >/dev/null 2>&1; then as_root apt-get update && as_root apt-get install -y python3
    elif command -v dnf     >/dev/null 2>&1; then as_root dnf install -y python3
    elif command -v yum     >/dev/null 2>&1; then as_root yum install -y python3
    elif command -v pacman  >/dev/null 2>&1; then as_root pacman -S --noconfirm --needed python
    elif command -v zypper  >/dev/null 2>&1; then as_root zypper --non-interactive install python3
    elif command -v apk     >/dev/null 2>&1; then as_root apk add python3
    elif command -v xbps-install >/dev/null 2>&1; then as_root xbps-install -Sy python3
    else return 1
    fi
}

PY="$(find_python)"
if [ -z "$PY" ]; then
    yel "  Не найден Python 3.8 или новее — он нужен для работы скрипта."
    ans=n
    if [ -t 0 ]; then
        printf '  Установить через менеджер пакетов? (y/N) '
        read -r ans || ans=n
    fi
    case "$ans" in
        y|Y|д|Д|yes|да)
            install_python || die "Не удалось установить Python автоматически." \
                "Установите пакет python3 вручную и повторите."
            PY="$(find_python)" || die "Python установлен, но не найден в PATH."
            ;;
        *) die "Python 3.8+ не установлен." "Установите пакет python3 и повторите." ;;
    esac
fi

# --- аргументы: первое слово без дефиса — это действие ---
if [ $# -gt 0 ]; then
    case "$1" in
        -*) ;;
        *)  first="$1"; shift; set -- --action "$first" "$@" ;;
    esac
fi

# --- нужны ли права root ---
need_root=1
prev=""
for a in "$@"; do
    case "$a" in
        -h|--help|-V|--version|--action=check|--action=status|-acheck|-astatus) need_root=0 ;;
    esac
    case "$prev" in
        --action|-a) case "$a" in check|status) need_root=0 ;; esac ;;
    esac
    prev="$a"
done

export PYTHONIOENCODING=utf-8

if [ "$need_root" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    yel "  Требуются права root — запрашиваю..."
    if command -v sudo >/dev/null 2>&1; then
        sudo env PYTHONIOENCODING=utf-8 "$PY" "$PY_SCRIPT" "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas env PYTHONIOENCODING=utf-8 "$PY" "$PY_SCRIPT" "$@"
    elif command -v pkexec >/dev/null 2>&1; then
        pkexec env PYTHONIOENCODING=utf-8 TERM="${TERM:-xterm}" "$PY" "$PY_SCRIPT" "$@"
    else
        # su принимает одну строку: экранируем каждый аргумент.
        cmd="PYTHONIOENCODING=utf-8 '$PY' '$PY_SCRIPT'"
        for a in "$@"; do
            esc=$(printf '%s' "$a" | sed "s/'/'\\\\''/g")
            cmd="$cmd '$esc'"
        done
        su root -c "$cmd"
    fi
    rc=$?
else
    "$PY" "$PY_SCRIPT" "$@"
    rc=$?
fi

if [ "$rc" -ne 0 ]; then
    say ""
    red "  [ОШИБКА] Скрипт завершился с кодом $rc"
    say "  Прочитайте сообщение выше."
    hold
fi
exit "$rc"
'''
# ============================================================================
#  Дальше — Python.
#
#  Zapret2 Windows-style controller for Linux: системная DPI-десинхронизация
#  через zapret2 (nfqws2 + nftables/iptables) для всех приложений и туннель
#  (sing-box) для сайтов, которым обход DPI не помогает.
#
#  Зависимости: Python 3.8+ (только стандартная библиотека), nftables или
#  iptables, systemd (для автозапуска и туннеля).
# ============================================================================

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
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime

VERSION = "1.8.8"
UPDATE_REPO = "HikariRisser/Zapret2Scrpt"
UPDATE_FILE = "zapret2-linux.sh"
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
    # Предупреждения и ошибки - в stderr: stdout остаётся чистым для
    # перенаправления (report > file), в интерактиве оба видны в терминале.
    print(_c(C.YELLOW, "  ! " + msg), file=sys.stderr)


def err(msg):
    print(_c(C.RED, "  ✘ " + msg), file=sys.stderr)


def info(msg):
    print(_c(C.GRAY, "    " + msg))


def head(msg):
    print(_c(C.CYAN, "  " + msg))


def clear_screen():
    """Очистка экрана ANSI-последовательностью, без os.system/shell."""
    if not os.environ.get("TERM"):
        return
    sys.stdout.write("\033[2J\033[3J\033[H")
    sys.stdout.flush()


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
            # Явная кодировка: при LC_ALL=C text=True по умолчанию берёт
            # locale-кодировку и падает на кириллице в выводе.
            encoding="utf-8",
            errors="replace",
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


def atomic_write(path, data, mode=None):
    """
    Атомарная запись файла: сначала во временный файл в том же каталоге
    (fsync), затем os.replace. Падение процесса не оставляет полузаписанный
    файл - критично для /etc/hosts, config и profiles.json с ключами.
    mode задаётся ДО записи: секреты не должны даже мгновение быть
    читаемыми всеми (umask при open() даёт 0644).
    """
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".zapret2-", dir=directory)
    try:
        if mode is not None:
            os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


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


def cmdline_running(prefix):
    """Есть ли процесс, чья командная строка начинается с prefix."""
    rc, _, _ = run(["pgrep", "-f", "^" + re.escape(prefix)], timeout=10)
    return rc == 0


def kill_by_cmdline(*prefixes, wait=4.0):
    """
    Завершает процессы, чья командная строка НАЧИНАЕТСЯ с одного из prefixes,
    и ждёт их выхода; не вышедшие за wait секунд завершает принудительно.
    Совпадение только с начала строки: иначе под шаблон попал бы любой
    процесс, в аргументах которого встречается этот путь.
    """
    pats = ["^" + re.escape(p) for p in prefixes]
    for pat in pats:
        run(["pkill", "-f", pat], timeout=10)
    end = time.monotonic() + wait
    while time.monotonic() < end:
        if not any(run(["pgrep", "-f", pat], timeout=10)[0] == 0 for pat in pats):
            return
        time.sleep(0.2)
    for pat in pats:
        run(["pkill", "-9", "-f", pat], timeout=10)
    time.sleep(0.3)


def nfqws2_pids():
    """PID'ы процессов nfqws2. Совпадение - только с начала командной
    строки (и путь экранируется): иначе pgrep -f ловит любой процесс,
    в аргументах которого встречается этот путь (редактор, less, grep)."""
    rc, out, _ = run(["pgrep", "-f", "^" + re.escape(nfqws2_path())], timeout=10)
    return out.split() if rc == 0 else []


def nfqws2_running():
    return bool(nfqws2_pids())


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

def http_get(url, timeout=30, retries=3):
    """GET с ретраями: обрыв сети не должен валить установку целиком."""
    last = None
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(
            url, headers={"User-Agent": f"zapret2-linux/{VERSION}", "Accept": "*/*"}
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except Exception as e:  # noqa: BLE001 - ретраим любые сетевые сбои
            last = e
            if attempt < retries:
                time.sleep(1.5 * attempt)
    raise RuntimeError(f"не удалось скачать {url}: {last}")


def download(url, dest, timeout=300, retries=3):
    """Стриминговое скачивание в dest.part с атомарной подменой."""
    last = None
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(
            url, headers={"User-Agent": f"zapret2-linux/{VERSION}", "Accept": "*/*"}
        )
        try:
            part = dest + ".part"
            with urllib.request.urlopen(req, timeout=timeout) as resp, \
                    open(part, "wb") as f:
                shutil.copyfileobj(resp, f)
            os.replace(part, dest)
            return os.path.getsize(dest)
        except Exception as e:  # noqa: BLE001
            last = e
            if attempt < retries:
                time.sleep(1.5 * attempt)
    raise RuntimeError(f"не удалось скачать {url}: {last}")


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
    # Домены, переведённые в туннель, zapret не трогает: их трафик идёт на сервер.
    # zapret не трогает трафик, идущий в туннель (диапазон FakeIP), и
    # соединение с самим сервером туннеля - оба исключаются по адресу.
    # Домены из списка туннеля по имени НЕ исключаются: если браузер обошёл
    # DNS туннеля (свой DNS через HTTPS, старый адрес в памяти) и пошёл на
    # сайт напрямую, zapret остаётся запасным путём, как до переноса.
    ensure_tunnel_ipset()
    wx = f"--ipset-exclude={tunnel_servers_path()}"
    # Порты серверов WireGuard: zapret маскирует их рукопожатие.
    wg_ports = "".join("," + p for p in tunnel_wg_ports()
                       if p not in ("443", "3478", "51820", "88", "1224", "500", "4500"))

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
        # reset: соединение, на котором обнаружен сбой, сразу обрывается, и
        # программа переподключается, а не ждёт таймаутов TCP (иначе видео
        # YouTube и подобное надолго зависают, пока подбирается стратегия).
        f"--filter-tcp=443 --filter-l7=tls <HOSTLIST> {wx} "
        "--in-range=-s5556 --lua-desync=circular:fails=2:retrans=2:nld=2"
        + (":reset " if circular_reset_enabled() else " ") +
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
# 51820,88,1224,500,4500 — порты WireGuard (в т. ч. Proton VPN): zapret маскирует рукопожатие
NFQWS2_PORTS_UDP=443,3478,50000-50099,19294-19344,51820,88,1224,500,4500{wg_ports}

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
        atomic_write(path, "\n".join(lines) + "\n", mode=0o644)
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

    cleanup_legacy_warp()
    merge_list_file(tunnel_list_path(), SEED_TUNNEL)
    merge_list_file(geo_list_path(), SEED_GEO)

    auto = os.path.join(ipset_dir(), "zapret-hosts-auto.txt")
    if not os.path.isfile(auto):
        open(auto, "w", encoding="utf-8").close()


def circular_reset_flag():
    return os.path.join(ipset_dir(), "zapret2win-circular-reset.off")


def circular_reset_enabled():
    """Обрыв зависших соединений при подборе стратегии (по умолчанию включён)."""
    return not os.path.isfile(circular_reset_flag())


def toggle_circular_reset():
    ensure_root(sys.argv)
    if not runtime_installed():
        raise RuntimeError("среда не установлена — сначала выполните установку (пункт 1)")
    if circular_reset_enabled():
        open(circular_reset_flag(), "w", encoding="utf-8").close()
        ok("Обрыв зависших соединений при подборе стратегии выключен")
    else:
        os.remove(circular_reset_flag())
        ok("Обрыв зависших соединений при подборе стратегии включён")
    info("Соединение, на котором стратегия не сработала, сразу обрывается, и программа "
         "переподключается со следующей стратегией, а не ждёт таймаутов (видео не зависает).")
    write_config()
    if nfqws2_running():
        info("Перезапуск обхода...")
        stop_bypass()
        start_bypass()


def write_config():
    atomic_write(config_path(), build_config() + "\n", mode=0o644)


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
        if tunnel_enabled():
            start_tunnel_background()
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
    stop_tunnel(quiet=True)
    run_init("stop")
    time.sleep(1)
    if nfqws2_running():
        # Крайний случай: добиваем процесс и чистим правила
        kill_by_cmdline(nfqws2_path())
        time.sleep(1)
    ok("Обход остановлен")


def status_line():
    if os.path.isdir(tunnel_dir()):
        tunnel_status_line()
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
        sync_tunnel_autostart()
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
    if tunnel_enabled():
        if os.path.isfile(TUNNEL_UNIT_PATH):
            sync_tunnel_autostart()
            ok("Туннель будет запускаться вместе с обходом")
        else:
            warn("Туннель включён, но ещё ни разу не запускался: запустите обход (пункт [2]), "
                 "после этого он будет стартовать при загрузке.")


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
    """
    Удаляет только размеченные блоки (наш и прежней версии проекта).
    Если begin есть, а end потерян (файл был оборван при записи), хвост
    НЕ стирается до конца файла: это защитило бы системные записи ниже.
    """
    out = []
    skip = False
    removed = 0
    begin_re = re.compile(r"^\s*#\s*-+\s*Zapret2(?:Windows|Win)?\s*(?:TUI)?\s*DoH\s*begin\s*-+", re.I)
    end_re = re.compile(r"^\s*#\s*-+\s*Zapret2(?:Windows|Win)?\s*(?:TUI)?\s*DoH\s*end\s*-+", re.I)
    saw_begin = False
    saw_end = False
    for ln in lines:
        if begin_re.match(ln):
            skip = True
            saw_begin = True
            removed += 1
            continue
        if end_re.match(ln):
            skip = False
            saw_end = True
            removed += 1
            continue
        if skip:
            removed += 1
            continue
        out.append(ln)
    if saw_begin and not saw_end:
        warn("в hosts найден незакрытый блок DoH (нет end-маркера); "
             "хвост файла сохранён, проверьте его вручную")
    return out, removed


def write_hosts(lines):
    if os.path.isfile(HOSTS_PATH) and not os.path.isfile(HOSTS_BACKUP):
        shutil.copy2(HOSTS_PATH, HOSTS_BACKUP)
        info(f"резервная копия: {HOSTS_BACKUP}")
    atomic_write(HOSTS_PATH, "\n".join(lines) + "\n", mode=0o644)


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
    # Домены туннеля разрешает DNS sing-box; запись в hosts увела бы их мимо туннеля.
    in_tunnel = set(tunnel_domains())
    domains = [d for d in domains if d.lower() not in in_tunnel]

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
    resolved_by_domain = {}
    failed = []
    sys_ok = []

    def _resolve_one(domain):
        """Возвращает (domain, результат): 'sys' | ip-строка | None."""
        if system_dns_ok(domain):
            return domain, "sys"
        return domain, working_ip(domain)

    # Домены независимы, каждый тянет несколько таймаутов (DoH-провайдеры,
    # TLS-проверки кандидатов) - разрешаем пулом потоков, а не по одному:
    # десятки минут последовательных ожиданий сжимаются в несколько.
    from concurrent.futures import ThreadPoolExecutor, as_completed

    done = 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(_resolve_one, d) for d in targets]
        for fut in as_completed(futures):
            domain, res = fut.result()
            done += 1
            sys.stdout.write(f"\r    [{done}/{len(targets)}] разрешено      ")
            sys.stdout.flush()
            if res == "sys":
                sys_ok.append(domain)
            elif res:
                resolved_by_domain[domain] = res
            else:
                failed.append(domain)
    print("\r" + " " * 60 + "\r", end="")
    # Порядок записей в hosts - как в списке доменов (детерминированно).
    resolved = [(resolved_by_domain[d], d) for d in targets if d in resolved_by_domain]

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
                 TUNNEL_LIST_FILE):
        p = os.path.join(ipset_dir(), name)
        doms = list_entries(p)
        hit = [d for d in doms if re.search(r"youtube|googlevideo|ytimg|ggpht|discord", d)]
        lines.append(f"{name}: {len(doms)} записей; YouTube/Discord: {', '.join(hit) or '—'}")
    lines.append(f"Туннель: {'включён' if tunnel_enabled() else 'выключен'}, "
                 f"{'работает' if tunnel_running() else 'не запущен'}")
    file(tunnel_path("last-error.txt"))

    sec("Другие туннели")
    cmd(["sh", "-c", "ip -br link 2>&1 | grep -iE 'tun|wg|tap|throne|nekoray|hiddify|sing' || echo 'нет'"])
    cmd(["sh", "-c", "ps -eo pid,args | grep -iE '[s]ing-box|[x]ray|[t]hrone|[n]ekoray|[h]iddify|[c]lash|[m]ihomo' | cut -c1-160 || true"])

    lines.append(f"внешний список: {geolist_status()}; всего доменов в туннеле: {len(tunnel_domains())}")
    sec("Туннель: журналы")
    st = read_json(tunnel_path("state.json")) or {}
    lines.append(f"state: active={st.get('active')} tested={st.get('tested')} ranked={st.get('ranked')}")
    for p in load_profiles():      # без ключей и паролей: только тип и адрес
        host, port, _ = profile_server(p)
        ob = p.get("outbound", {})
        extra = []
        if isinstance(ob.get("tls"), dict):
            extra.append("tls" + ("+reality" if "reality" in ob["tls"] else ""))
        if isinstance(ob.get("transport"), dict):
            extra.append(str(ob["transport"].get("type")))
        lines.append(f"профиль: {p.get('type')} {host}:{port} {' '.join(extra)} источник={p.get('source')}")
    lines.append("серверы в исключениях zapret: " + (", ".join(list_entries(tunnel_servers_path())) or "—"))
    for name in ("probe.log", "start.log"):
        lines.append(f"--- {name}")
        lines.extend(file_tail(tunnel_path(name), 60) or ["<пусто>"])
    cmd(["sh", "-c", f"resolvectl status {TUNNEL_TUN} 2>&1 | head -12"])
    cmd(["sh", "-c", f"ip rule 2>&1 | head -12; ip route get {TUNNEL_FAKE4_PREFIX}0.1 2>&1"])
    for d in list_entries(tunnel_list_path())[:3]:
        cmd(["sh", "-c", f"resolvectl query {shlex.quote(d)} 2>&1 | head -4"])
        lines.append(f"через TUN {d}: {_probe_tls(d, 4)}")
    cmd(["journalctl", "-u", TUNNEL_SERVICE, "-n", "40", "--no-pager", "-o", "cat"])
    if os.path.isfile(XRAY_UNIT_PATH):
        cmd(["journalctl", "-u", XRAY_SERVICE, "-n", "25", "--no-pager", "-o", "cat"])

    # Проверка сайтов с отладочным журналом nfqws2: перезапускаем nfqws2 с
    # теми же параметрами + --debug, правила перехвата остаются на месте.
    # Лог пишется в root-only каталог /opt/zapret2: предсказуемое имя в /tmp
    # открыло бы symlink-атаку на чужой файл.
    debug_log = os.path.join(ZAPRET_TARGET, "nfqws2-debug.log")
    pids = nfqws2_pids()
    pid = pids[0] if pids else None
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
    try:
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
    finally:
        # Восстановление обязательно даже при Ctrl-C/исключении: иначе
        # nfqws2 остаётся убитым, а отладочный процесс - осиротевшим.
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

    # Отчёт содержит адреса серверов профилей - только root (0600).
    atomic_write(path, "\n".join(lines) + "\n", mode=0o600)
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


def script_update(assume_yes=False, force=False):
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

    if verdict in ("downgrade", "unversioned") and not force:
        # Откат версии или файл без маркера: --yes НЕ подтверждает замену -
        # тихий автоматический откат недопустим, нужно явное «y» или --force.
        try:
            ans = input("    Всё равно заменить локальный файл? (y/N) ").strip().lower()
        except EOFError:
            ans = ""
        if ans not in ("y", "yes", "д", "да"):
            warn("Отменено")
            print()
            return
    elif not assume_yes:
        try:
            ans = input("    Установить обновление? (y/N) ").strip().lower()
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

    # Синтаксис проверяем ДО замены рабочего файла: падение между open("w")
    # и записью оставило бы обрезанный скрипт (atomic_write страхует и это,
    # но порядок «сначала проверь, потом пиши» дешевле отката).
    tmp_new = self_path + ".new"
    try:
        with open(tmp_new, "w", encoding="utf-8") as f:
            f.write(remote)
    except OSError as e:
        try:
            os.remove(tmp_new)
        except OSError:
            pass
        err(f"не удалось записать обновление: {e}")
        return
    rc, _, errout = run([sys.executable, "-c",
                         "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())",
                         tmp_new], timeout=60)
    if rc != 0:
        try:
            os.remove(tmp_new)
        except OSError:
            pass
        err("Скачанный скрипт содержит синтаксические ошибки, обновление отменено.")
        info(errout[:400])
        return
    try:
        os.chmod(tmp_new, 0o755)
        os.replace(tmp_new, self_path)
    except OSError as e:
        try:
            os.remove(tmp_new)
        except OSError:
            pass
        shutil.copy2(backup, self_path)
        err(f"не удалось заменить файл, копия восстановлена: {e}")
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
    print("    - туннель: процессы sing-box и xray-core, профили и ключи серверов")
    print("    - службы systemd (автозапуск, туннель)")
    print(f"    - каталог {ZAPRET_TARGET} со списками доменов")
    n_marked = count_marked()
    if n_marked:
        print(f"    - {n_marked} строк в {HOSTS_PATH} (блок DoH)")
    if os.path.isfile(HOSTS_BACKUP):
        print(f"    - резервная копия {HOSTS_BACKUP}")
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
    kill_by_cmdline(nfqws2_path())
    time.sleep(1)

    stop_tunnel(quiet=True)
    cleanup_legacy_warp()
    remove_geolist_timer()

    head("[2/4] Удаление службы...")
    run(["systemctl", "disable", TUNNEL_SERVICE], timeout=60)
    for unit in (XRAY_UNIT_PATH, TUNNEL_UNIT_PATH):
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
    try:
        os.remove(HOSTS_BACKUP)     # копия hosts до первой правки больше не нужна
    except OSError:
        pass

    print()
    head("Проверка результата:")
    units = [UNIT_PATH, TUNNEL_UNIT_PATH, XRAY_UNIT_PATH, GEOLIST_UNIT_PATH, GEOLIST_TIMER_PATH] + \
            [f"/etc/systemd/system/{u}.service" for u in LEGACY_WARP_UNITS]
    rc_nft = 1
    if which("nft"):
        rc_nft, _, _ = run(["nft", "list", "table", "inet", "zapret2"], timeout=15)
    # zapret2 init работает и через iptables (системы без nftables) -
    # проверяем и его правила, иначе отчёт об удалении был бы ложно-чистым.
    fw_left = rc_nft == 0
    if not fw_left:
        for saver in ("iptables-save", "ip6tables-save"):
            if not which(saver):
                continue
            rc_sv, out_sv, _ = run([saver], timeout=15)
            if rc_sv == 0 and re.search(r"NFQUEUE|zapret", out_sv, re.I):
                fw_left = True
                break
    checks = [
        ("процесс nfqws2", not nfqws2_running()),
        ("процессы туннеля", not cmdline_running(f"{singbox_path()} run")
                             and not cmdline_running(f"{xray_path()} run")),
        ("правила файрвола", not fw_left),
        ("службы systemd", not service_enabled() and not any(os.path.isfile(u) for u in units)),
        ("каталог среды", not os.path.isdir(ZAPRET_TARGET)),
        ("записи hosts", count_marked() == 0 and not os.path.isfile(HOSTS_BACKUP)),
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
#  Туннель через sing-box: внешний выход для сайтов, с которыми не
#  справляется zapret (блокировка по IP, запрет самого сервиса для России).
#
#  Выход — Proton VPN Free (конфиг WireGuard) или свой сервер (WireGuard,
#  VLESS, VMess, Trojan, Shadowsocks, Hysteria2, TUIC, SOCKS, JSON sing-box,
#  ссылки и подписки). В TUN sing-box маршрутизируется ТОЛЬКО диапазон
#  FakeIP и подсети Telegram: домены из списка туннеля получают FakeIP от DNS
#  sing-box и уходят на сервер, приложение Telegram (ходит по IP, без DNS)
#  уходит туда же; весь остальной трафик идёт мимо sing-box, через zapret.
# ----------------------------------------------------------------------------

SING_BOX_VERSION = "1.14.4"
TUNNEL_SERVICE = "zapret2win-tunnel"
TUNNEL_UNIT_PATH = f"/etc/systemd/system/{TUNNEL_SERVICE}.service"
TUNNEL_MIXED_PORT = 40480
TUNNEL_PROBE_PORT = 40481
TUNNEL_LIST_FILE = "zapret2win-hosts-tunnel.txt"
# xray-core: только для профилей, которые sing-box не умеет (транспорт XHTTP,
# конфиги Xray). Работает локальным прокси, в который sing-box отправляет трафик.
XRAY_SERVICE = "zapret2win-xray"
XRAY_UNIT_PATH = f"/etc/systemd/system/{XRAY_SERVICE}.service"
XRAY_PORT = 40482
XRAY_PROBE_PORT = 40483
# Сайты, по которым проверяется, пускает ли сервис с адреса профиля.
TUNNEL_GEO_FILE = "zapret2win-geo-sites.txt"
SEED_GEO = [
    "# Сайты с региональными ограничениями: по ним выбирается профиль туннеля.",
    "# По домену в строке. Профиль, с которого открывается больше сайтов, - лучший.",
    "claude.ai",
    "chatgpt.com",
    "gemini.google.com",
]
# Признаки отказа по региону: в адресе перенаправления или в тексте страницы.
GEO_RE = re.compile(
    r"app-unavailable-in-region|unavailable[-_ ]in[-_ ](your[-_ ])?(region|country)"
    r"|unsupported[-_ ](country|region)|country[-_ ]not[-_ ]supported"
    r"|not[-_ ](available|supported)[-_ ]in[-_ ]your[-_ ](country|region|location)"
    r"|region[-_ ](restricted|blocked)|geo[-_ ]?(block|restrict)"
    r"|недоступ\w+ в ваш\w+ (стране|регионе)", re.I)
GEO_LABEL = {"ok": "открывается", "challenge": "отвечает (проверка браузера)",
             "geo": "отказ по региону", "deny": "отказ (403)", "fail": "нет ответа"}
TUNNEL_SERVERS_FILE = "zapret2win-ip-tunnel.txt"
SEED_TUNNEL = [
    "# Сайты, которые открываются через туннель (sing-box), а не через zapret.",
    "# Пополняется автоматически (меню туннеля) или вручную, по домену в строке.",
]
BROWSER_UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/130.0 Safari/537.36")

TUNNEL_TUN = "zapret2tun"
# Свои адреса, диапазон FakeIP и номера таблицы/правил маршрутизации —
# намеренно НЕ значения sing-box по умолчанию: их используют другие клиенты
# на sing-box в режиме TUN (Throne, Hiddify, NekoBox...), и при одновременной
# работе трафик и DNS уходили бы не в тот туннель.
TUNNEL_TUN_ADDR4 = "172.31.251.1/30"
TUNNEL_TUN_DNS4 = "172.31.251.2"
TUNNEL_TUN_ADDR6 = "fd7a:7a70:7761::1/126"
TUNNEL_FAKE4 = "10.249.0.0/16"
TUNNEL_FAKE4_PREFIX = "10.249."
TUNNEL_FAKE6 = "fd7a:7a70:fa4e::/64"
# Подсети Telegram (https://core.telegram.org/resources/cidr.txt). Приложение
# Telegram подключается к серверам по IP, без DNS и без TLS-имени, поэтому
# ни FakeIP, ни профили zapret его не ловят. Эти подсети всегда идут в туннель.
TELEGRAM_CIDR4 = ["91.108.56.0/22", "91.108.4.0/22", "91.108.8.0/22", "91.108.16.0/22",
                  "91.108.12.0/22", "149.154.160.0/20", "91.105.192.0/23", "91.108.20.0/22",
                  "185.76.151.0/24"]
TELEGRAM_CIDR6 = ["2001:b28:f23d::/48", "2001:b28:f23f::/48", "2001:67c:4e8::/48",
                  "2001:b28:f23c::/48", "2a0a:f280::/32"]
# Медиасерверы Discord в сети Cloudflare (трансляции, всё больше и голос).
# Discord шлёт на них UDP по адресу из сигнального соединения, без DNS, поэтому
# список доменов туннеля их не касается. У части провайдеров UDP к ним обрезается
# через ~1 с после начала соединения, и zapret это не исправляет: тогда (по
# итогам проверки) в туннель направляется UDP к этим адресам, TCP идёт напрямую.
DISCORD_MEDIA_CIDR4 = ["104.29.0.0/16"]
# Серверы для проверки: отвечают на пакет определения IP без входа в аккаунт.
DISCORD_PROBE_SERVERS = [("104.29.149.69", 19298), ("104.29.155.188", 19298)]
TUNNEL_RT_TABLE = 2649
TUNNEL_RT_RULE = 8640

# Прежняя реализация (WARP) — только для очистки при обновлении.
LEGACY_WARP_UNITS = ("zapret2win-warp", "zapret2win-warp-masque")
LEGACY_WARP_LIST = "zapret2win-hosts-warp.txt"


def tunnel_dir():
    return os.path.join(ZAPRET_TARGET, "tunnel")


def tunnel_path(name):
    return os.path.join(tunnel_dir(), name)


def tunnel_list_path():
    return os.path.join(ipset_dir(), TUNNEL_LIST_FILE)


def tunnel_servers_path():
    return os.path.join(ipset_dir(), TUNNEL_SERVERS_FILE)


def geo_list_path():
    return os.path.join(ipset_dir(), TUNNEL_GEO_FILE)


def xray_path():
    return tunnel_path("xray")


def singbox_path():
    return tunnel_path("sing-box")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, obj, mode=0o600):
    atomic_write(path, json.dumps(obj, ensure_ascii=False, indent=2) + "\n", mode=mode)


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


def file_tail(path, lines=12):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = re.sub(r"\x1b\[[0-9;]*m", "", f.read())  # цвета sing-box
            return [ln.rstrip() for ln in text.splitlines() if ln.strip()][-lines:]
    except OSError:
        return []


def cleanup_legacy_warp():
    """Убирает следы прежней реализации (WARP): службы, процессы, каталог."""
    old_dir = os.path.join(ZAPRET_TARGET, "warp")
    for svc in LEGACY_WARP_UNITS:
        unit = f"/etc/systemd/system/{svc}.service"
        if os.path.isfile(unit):
            run(["systemctl", "stop", svc], timeout=60)
            run(["systemctl", "disable", svc], timeout=60)
            try:
                os.remove(unit)
            except OSError:
                pass
            run(["systemctl", "daemon-reload"], timeout=60)
    if os.path.isdir(old_dir):
        # Только свои процессы: шаблон «каталог/» задел бы и чужие команды.
        kill_by_cmdline(os.path.join(old_dir, "sing-box") + " run",
                        os.path.join(old_dir, "usque") + " -c", wait=2.0)
        os.makedirs(tunnel_dir(), exist_ok=True)
        old_sb = os.path.join(old_dir, "sing-box")
        if os.path.isfile(old_sb) and not os.path.isfile(singbox_path()):
            try:
                os.replace(old_sb, singbox_path())   # не скачивать заново
            except OSError:
                pass
        shutil.rmtree(old_dir, ignore_errors=True)
    old_list = os.path.join(ipset_dir(), LEGACY_WARP_LIST)
    if os.path.isfile(old_list):
        # Сайты, которые были в списке WARP, переходят в список туннеля.
        if not os.path.isfile(tunnel_list_path()):
            try:
                os.replace(old_list, tunnel_list_path())
            except OSError:
                pass
        else:
            merge_list_file(tunnel_list_path(), list_entries(old_list))
            try:
                os.remove(old_list)
            except OSError:
                pass


# --- sing-box ----------------------------------------------------------------

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
    os.makedirs(tunnel_dir(), exist_ok=True)
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
            src = tf.extractfile(tf.getmember(f"{name}/sing-box"))
            stop_tunnel(quiet=True)
            with open(exe + ".new", "wb") as dst:
                shutil.copyfileobj(src, dst)
        os.chmod(exe + ".new", 0o755)
        os.replace(exe + ".new", exe)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    ok(f"sing-box установлен: {exe}")


def install_xray():
    """Скачивает официальную сборку xray-core с GitHub (один раз)."""
    exe = xray_path()
    if os.access(exe, os.X_OK):
        return
    m = platform.machine().lower()
    arch = {"x86_64": "64", "amd64": "64", "aarch64": "arm64-v8a", "arm64": "arm64-v8a",
            "armv7l": "arm32-v7a", "armv7": "arm32-v7a", "i386": "32", "i686": "32",
            "riscv64": "riscv64"}.get(m)
    if not arch:
        raise RuntimeError(f"нет сборки xray-core для архитектуры {platform.machine()}")
    url = f"https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-{arch}.zip"
    head("Скачивание xray-core (нужен для профилей с XHTTP и конфигов Xray)...")
    info(url)
    import zipfile
    os.makedirs(tunnel_dir(), exist_ok=True)
    tmpdir = tempfile.mkdtemp(prefix="xray-")
    try:
        zpath = os.path.join(tmpdir, "xray.zip")
        download(url, zpath)
        with zipfile.ZipFile(zpath) as zf:
            with zf.open("xray") as src, open(exe + ".new", "wb") as dst:
                shutil.copyfileobj(src, dst)
        os.chmod(exe + ".new", 0o755)
        os.replace(exe + ".new", exe)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    ok(f"xray-core установлен: {exe}")


# --- разбор конфигов и ссылок ------------------------------------------------
#
# Каждый профиль: {"name", "source" ("proton" | "custom"), "type",
# "endpoint" (True для WireGuard), "outbound" (объект sing-box без tag)}.
# Профиль для xray-core дополнительно: "engine": "xray", "xray" (outbound
# Xray), "server": [хост, порт]; его "outbound" - SOCKS на локальный xray.

class NeedXray(Exception):
    """Профиль не для sing-box: его нужно запускать через xray-core."""


class ProfileError(Exception):
    pass


def _b64(text):
    """Base64 в любом варианте (обычный/URL-safe, с выравниванием и без)."""
    import base64
    s = re.sub(r"\s+", "", text).replace("-", "+").replace("_", "/")
    s += "=" * (-len(s) % 4)
    return base64.b64decode(s).decode("utf-8", "replace")


def _is_ip(host):
    try:
        socket.inet_pton(socket.AF_INET6 if ":" in host else socket.AF_INET, host)
        return True
    except (OSError, ValueError):
        return False


def _truthy(v):
    return str(v).lower() in ("1", "true", "yes")


def _tls_block(q, host, force=False):
    """Блок tls для sing-box из параметров ссылки (security, sni, fp, pbk...)."""
    sec = (q.get("security") or "").lower()
    if not force and sec not in ("tls", "reality", "xtls"):
        return None
    tls = {"enabled": True}
    sni = q.get("sni") or q.get("peer") or q.get("servername") or ("" if _is_ip(host) else host)
    if sni:
        tls["server_name"] = sni
    if _truthy(q.get("allowInsecure", "")) or _truthy(q.get("insecure", "")) \
            or _truthy(q.get("allow_insecure", "")):
        tls["insecure"] = True
    if q.get("alpn"):
        tls["alpn"] = [a for a in urllib.parse.unquote(q["alpn"]).split(",") if a]
    fp = q.get("fp") or q.get("fingerprint")
    if sec == "reality":
        if not q.get("pbk"):
            raise ProfileError("в ссылке Reality нет открытого ключа (pbk)")
        tls["reality"] = {"enabled": True, "public_key": q["pbk"], "short_id": q.get("sid", "")}
        fp = fp or "chrome"   # Reality требует uTLS
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    return tls


def _transport_block(q):
    """Блок transport для sing-box (ws, grpc, http, httpupgrade)."""
    net = (q.get("type") or q.get("net") or "tcp").lower()
    host = q.get("host", "")
    path = urllib.parse.unquote(q.get("path", "") or "")
    if net in ("tcp", "raw", ""):
        if (q.get("headerType") or "").lower() == "http":
            tr = {"type": "http", "path": path or "/"}
            if host:
                tr["host"] = host.split(",")
            return tr
        return None
    if net == "ws":
        tr = {"type": "ws", "path": path or "/"}
        m = re.search(r"[?&]ed=(\d+)", tr["path"])
        if m:   # раннее отправление данных, запись Xray «?ed=2048»
            tr["path"] = re.sub(r"[?&]ed=\d+", "", tr["path"]) or "/"
            tr["max_early_data"] = int(m.group(1))
            tr["early_data_header_name"] = "Sec-WebSocket-Protocol"
        if host:
            tr["headers"] = {"Host": host}
        return tr
    if net == "grpc":
        return {"type": "grpc", "service_name": q.get("serviceName") or q.get("servicename") or path}
    if net in ("http", "h2"):
        tr = {"type": "http", "path": path or "/"}
        if host:
            tr["host"] = host.split(",")
        return tr
    if net == "httpupgrade":
        tr = {"type": "httpupgrade", "path": path or "/"}
        if host:
            tr["host"] = host
        return tr
    if net in ("xhttp", "splithttp"):
        raise NeedXray()
    raise ProfileError(f"транспорт «{net}» не поддерживается sing-box")


def _xray_stream(q, host):
    """streamSettings Xray для транспорта XHTTP из параметров ссылки."""
    sec = (q.get("security") or "none").lower()
    sni = q.get("sni") or q.get("peer") or ("" if _is_ip(host) else host)
    fp = q.get("fp") or q.get("fingerprint") or ""
    xh = {"path": urllib.parse.unquote(q.get("path", "") or "") or "/"}
    if q.get("host"):
        xh["host"] = q["host"]
    if q.get("mode"):
        xh["mode"] = q["mode"]
    if q.get("extra"):
        try:
            xh["extra"] = json.loads(urllib.parse.unquote(q["extra"]))
        except ValueError:
            raise ProfileError("параметр extra в ссылке XHTTP - не JSON")
    ss = {"network": "xhttp", "xhttpSettings": xh}
    if sec == "reality":
        if not q.get("pbk"):
            raise ProfileError("в ссылке Reality нет открытого ключа (pbk)")
        ss["security"] = "reality"
        ss["realitySettings"] = {"serverName": sni, "fingerprint": fp or "chrome",
                                 "publicKey": q["pbk"], "shortId": q.get("sid", ""),
                                 "spiderX": urllib.parse.unquote(q.get("spx", "") or "")}
    elif sec in ("tls", "xtls"):
        tls = {"serverName": sni}
        if fp:
            tls["fingerprint"] = fp
        if q.get("alpn"):
            tls["alpn"] = [a for a in urllib.parse.unquote(q["alpn"]).split(",") if a]
        if _truthy(q.get("allowInsecure")) or _truthy(q.get("insecure")):
            tls["allowInsecure"] = True
        ss["security"] = "tls"
        ss["tlsSettings"] = tls
    else:
        ss["security"] = "none"
    return ss


def _xray_link(proto, host, port, q, **user):
    """Профиль для xray-core из ссылки vless/vmess/trojan с транспортом XHTTP."""
    if proto == "trojan":
        settings = {"servers": [{"address": host, "port": port, "password": user["password"]}]}
    else:
        u = {"id": user["uuid"]}
        if proto == "vless":
            u["encryption"] = q.get("encryption") or "none"
            if q.get("flow"):
                u["flow"] = q["flow"]
        else:
            u["security"] = user.get("security") or "auto"
            u["alterId"] = int(user.get("alter_id") or 0)
        settings = {"vnext": [{"address": host, "port": port, "users": [u]}]}
    return {"type": f"{proto}+xhttp", "_xray": {"protocol": proto, "settings": settings,
                                                "streamSettings": _xray_stream(q, host)},
            "_server": [host, port]}


def _split_link(link):
    """Разбор ссылки вида scheme://userinfo@host:port?query#name."""
    u = urllib.parse.urlsplit(link.strip())
    q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query, keep_blank_values=True).items()}
    name = urllib.parse.unquote(u.fragment or "")
    try:
        port = u.port
    except ValueError:
        port = None
    return u, q, name, u.hostname or "", port


def _need(host, port, what="адрес сервера и порт"):
    if not host or not port:
        raise ProfileError(f"в ссылке нет: {what}")


def parse_vless(link):
    u, q, name, host, port = _split_link(link)
    _need(host, port)
    ob = {"type": "vless", "server": host, "server_port": port,
          "uuid": urllib.parse.unquote(u.username or ""), "packet_encoding": "xudp"}
    if q.get("flow"):
        ob["flow"] = q["flow"]
    try:
        tr = _transport_block(q)
    except NeedXray:
        return name or f"VLESS {host}", _xray_link("vless", host, port, q, uuid=ob["uuid"])
    tls = _tls_block(q, host)
    if tls:
        ob["tls"] = tls
    if tr:
        ob["transport"] = tr
    return name or f"VLESS {host}", ob


def parse_vmess(link):
    body = link.strip()[len("vmess://"):]
    if "@" in body and "?" in body:   # редкая запись vmess://uuid@host:port?...
        u, q, name, host, port = _split_link(link)
        _need(host, port)
        ob = {"type": "vmess", "server": host, "server_port": port,
              "uuid": urllib.parse.unquote(u.username or ""), "security": q.get("encryption", "auto"),
              "alter_id": int(q.get("aid", "0") or 0)}
        tls = _tls_block(q, host)
    else:
        try:
            j = json.loads(_b64(body.split("#")[0]))
        except ValueError:
            raise ProfileError("ссылка vmess:// не расшифровывается (ожидался base64 с JSON)")
        host, port = str(j.get("add", "")), int(j.get("port", 0) or 0)
        _need(host, port)
        name = str(j.get("ps", ""))
        q = {"type": j.get("net", "tcp"), "host": j.get("host", ""), "path": j.get("path", ""),
             "headerType": j.get("type", ""), "sni": j.get("sni", ""), "alpn": j.get("alpn", ""),
             "fp": j.get("fp", ""), "security": "tls" if str(j.get("tls", "")).lower() == "tls" else "",
             "serviceName": j.get("path", "") if j.get("net") == "grpc" else ""}
        q = {k: v for k, v in q.items() if v}
        ob = {"type": "vmess", "server": host, "server_port": port, "uuid": str(j.get("id", "")),
              "security": str(j.get("scy") or "auto"), "alter_id": int(j.get("aid", 0) or 0)}
        tls = _tls_block(q, q.get("host") or host)
    try:
        tr = _transport_block(q)
    except NeedXray:
        return name or f"VMess {host}", _xray_link("vmess", host, port, q, uuid=ob["uuid"],
                                                   security=ob["security"], alter_id=ob["alter_id"])
    if tls:
        ob["tls"] = tls
    if tr:
        ob["transport"] = tr
    return name or f"VMess {host}", ob


def parse_trojan(link):
    u, q, name, host, port = _split_link(link)
    _need(host, port)
    ob = {"type": "trojan", "server": host, "server_port": port,
          "password": urllib.parse.unquote(u.username or "")}
    try:
        tr = _transport_block(q)
    except NeedXray:
        q.setdefault("security", "tls")
        return name or f"Trojan {host}", _xray_link("trojan", host, port, q, password=ob["password"])
    if (q.get("security") or "tls").lower() != "none":
        ob["tls"] = _tls_block(q, host, force=True)
    if tr:
        ob["transport"] = tr
    return name or f"Trojan {host}", ob


def parse_ss(link):
    body = link.strip()[len("ss://"):]
    name = ""
    if "#" in body:
        body, frag = body.split("#", 1)
        name = urllib.parse.unquote(frag)
    query = ""
    if "?" in body:
        body, query = body.split("?", 1)
    body = body.rstrip("/")
    if "@" not in body:                       # ss://base64(method:pass@host:port)
        body = _b64(body)
    cred, _, addr = body.rpartition("@")
    if ":" not in cred:                       # ss://base64(method:pass)@host:port
        cred = _b64(urllib.parse.unquote(cred))
    else:
        cred = urllib.parse.unquote(cred)
    method, _, password = cred.partition(":")
    u = urllib.parse.urlsplit("//" + addr)
    _need(u.hostname, u.port)
    ob = {"type": "shadowsocks", "server": u.hostname, "server_port": u.port,
          "method": method, "password": password}
    plugin = urllib.parse.parse_qs(query).get("plugin", [""])[0]
    if plugin:
        pname, _, popts = plugin.partition(";")
        pname = {"simple-obfs": "obfs-local", "obfs": "obfs-local"}.get(pname, pname)
        if pname not in ("obfs-local", "v2ray-plugin"):
            raise ProfileError(f"плагин Shadowsocks «{pname}» sing-box не поддерживает")
        ob["plugin"] = pname
        ob["plugin_opts"] = popts
    return name or f"Shadowsocks {u.hostname}", ob


def parse_hysteria2(link):
    u, q, name, host, port = _split_link(link)
    _need(host, port)
    pwd = urllib.parse.unquote(u.username or "")
    if u.password:
        pwd += ":" + urllib.parse.unquote(u.password)
    ob = {"type": "hysteria2", "server": host, "server_port": port, "password": pwd,
          "tls": _tls_block(q, host, force=True)}
    if q.get("obfs") and q.get("obfs") != "none":
        ob["obfs"] = {"type": q["obfs"], "password": q.get("obfs-password", "")}
    return name or f"Hysteria2 {host}", ob


def parse_hysteria(link):
    u, q, name, host, port = _split_link(link)
    _need(host, port)
    ob = {"type": "hysteria", "server": host, "server_port": port,
          "up_mbps": int(float(q.get("upmbps", "20") or 20)),
          "down_mbps": int(float(q.get("downmbps", "100") or 100)),
          "tls": _tls_block(q, host, force=True)}
    if q.get("auth"):
        ob["auth_str"] = q["auth"]
    if q.get("obfsParam"):
        ob["obfs"] = q["obfsParam"]
    return name or f"Hysteria {host}", ob


def parse_tuic(link):
    u, q, name, host, port = _split_link(link)
    _need(host, port)
    ob = {"type": "tuic", "server": host, "server_port": port,
          "uuid": urllib.parse.unquote(u.username or ""),
          "password": urllib.parse.unquote(u.password or ""),
          "congestion_control": q.get("congestion_control") or q.get("congestion-control") or "bbr",
          "tls": _tls_block(q, host, force=True)}
    mode = q.get("udp_relay_mode") or q.get("udp-relay-mode")
    if mode:
        ob["udp_relay_mode"] = mode
    return name or f"TUIC {host}", ob


def parse_anytls(link):
    u, q, name, host, port = _split_link(link)
    _need(host, port)
    ob = {"type": "anytls", "server": host, "server_port": port,
          "password": urllib.parse.unquote(u.username or ""),
          "tls": _tls_block(q, host, force=True)}
    return name or f"AnyTLS {host}", ob


def parse_socks(link):
    u, q, name, host, port = _split_link(link)
    _need(host, port)
    user, pwd = urllib.parse.unquote(u.username or ""), urllib.parse.unquote(u.password or "")
    if user and not pwd and ":" not in user:      # socks://base64(user:pass)@host:port
        try:
            dec = _b64(user)
            if ":" in dec:
                user, _, pwd = dec.partition(":")
        except Exception:
            pass
    ob = {"type": "socks", "server": host, "server_port": port,
          "version": "4" if u.scheme == "socks4" else "5"}
    if user:
        ob["username"], ob["password"] = user, pwd
    return name or f"SOCKS {host}", ob


def _wg_endpoint(private_key, addresses, peer_host, peer_port, public_key,
                 psk="", mtu=None, reserved=None, keepalive=25, allowed=None):
    if not (private_key and public_key and peer_host and peer_port and addresses):
        raise ProfileError("в конфиге WireGuard не хватает PrivateKey, Address, PublicKey или Endpoint")
    addrs = []
    for a in addresses:
        a = a.strip()
        if a:
            addrs.append(a if "/" in a else a + ("/128" if ":" in a else "/32"))
    peer = {"address": peer_host, "port": int(peer_port), "public_key": public_key,
            "allowed_ips": allowed or ["0.0.0.0/0", "::/0"],
            "persistent_keepalive_interval": int(keepalive or 25)}
    if psk:
        peer["pre_shared_key"] = psk
    if reserved:
        peer["reserved"] = reserved
    return {"type": "wireguard", "mtu": int(mtu or 1408), "address": addrs,
            "private_key": private_key, "peers": [peer]}


def parse_wireguard_conf(text, default_name="WireGuard"):
    """Обычный конфиг WireGuard (.conf): Proton VPN, свой сервер, любой провайдер."""
    iface, peer, cur = {}, {}, None
    for ln in text.splitlines():
        ln = ln.split("#", 1)[0].strip()
        if not ln:
            continue
        low = ln.lower()
        if low == "[interface]":
            cur = iface
        elif low == "[peer]":
            if peer:      # берём первый [Peer]
                cur = {}
            else:
                cur = peer
        elif "=" in ln and cur is not None:
            k, _, v = ln.partition("=")
            cur[k.strip().lower()] = v.strip()
    if any(k in iface for k in ("jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4")):
        raise ProfileError("это конфиг AmneziaWG (параметры Jc/S1/H1…): sing-box его не поддерживает. "
                           "Нужен обычный WireGuard или другой протокол (VLESS, Shadowsocks…)")
    ep = peer.get("endpoint", "")
    u = urllib.parse.urlsplit("//" + ep)
    reserved = [int(x) for x in re.split(r"[,\s]+", iface.get("reserved", peer.get("reserved", "")))
                if x.isdigit()]
    ob = _wg_endpoint(
        iface.get("privatekey"), iface.get("address", "").split(","), u.hostname, u.port,
        peer.get("publickey"), psk=peer.get("presharedkey", ""), mtu=iface.get("mtu"),
        reserved=reserved if len(reserved) == 3 else None,
        keepalive=peer.get("persistentkeepalive") or 25)
    return f"{default_name} {u.hostname}", ob


def parse_wireguard_link(link):
    u, q, name, host, port = _split_link(link)
    _need(host, port)
    reserved = [int(x) for x in re.split(r"[,\s]+", q.get("reserved", "")) if x.isdigit()]
    ob = _wg_endpoint(
        urllib.parse.unquote(u.username or q.get("privatekey", "")),
        urllib.parse.unquote(q.get("address", q.get("ip", ""))).split(","), host, port,
        urllib.parse.unquote(q.get("publickey", q.get("peer", ""))),
        psk=urllib.parse.unquote(q.get("presharedkey", "")), mtu=q.get("mtu"),
        reserved=reserved if len(reserved) == 3 else None)
    return name or f"WireGuard {host}", ob


LINK_PARSERS = {
    "vless": parse_vless, "vmess": parse_vmess, "trojan": parse_trojan, "ss": parse_ss,
    "hysteria2": parse_hysteria2, "hy2": parse_hysteria2, "hysteria": parse_hysteria,
    "tuic": parse_tuic, "anytls": parse_anytls,
    "socks": parse_socks, "socks5": parse_socks, "socks4": parse_socks,
    "wireguard": parse_wireguard_link, "wg": parse_wireguard_link,
}
SUPPORTED_FORMATS = ("конфиг WireGuard (.conf); ссылки vless://, vmess://, trojan://, ss://, "
                     "hysteria2:// (hy2://), hysteria://, tuic://, anytls://, socks5://, wireguard://; "
                     "несколько ссылок или подписка (адрес https://… либо base64); "
                     "JSON sing-box (outbound или целый конфиг); JSON Xray (outbound или целый конфиг). "
                     "Транспорт XHTTP и конфиги Xray работают через xray-core, остальное - через sing-box")
# Служебные типы sing-box, которые не являются выходом на сервер.
_NOT_SERVERS = {"direct", "block", "dns", "selector", "urltest", "tor", "ssh"}


_XRAY_NOT_SERVERS = {"freedom", "blackhole", "dns", "loopback"}


def _xray_server(ob):
    """[хост, порт] сервера из outbound Xray."""
    s = ob.get("settings") or {}
    for key in ("vnext", "servers", "peers"):
        first = (s.get(key) or [{}])[0]
        if first.get("address"):
            return [str(first["address"]), first.get("port")]
        if first.get("endpoint"):                      # WireGuard: "хост:порт"
            h, _, p = str(first["endpoint"]).rpartition(":")
            return [h.strip("[]"), int(p) if p.isdigit() else None]
    if s.get("address"):
        return [str(s["address"]), s.get("port")]
    return ["", None]


def parse_xray_json(j):
    """Конфиг Xray (целый или один outbound): список профилей либо None."""
    if isinstance(j, dict) and isinstance(j.get("outbounds"), list) \
            and any(isinstance(o, dict) and "protocol" in o for o in j["outbounds"]):
        items = j["outbounds"]
    elif isinstance(j, dict) and "protocol" in j and "type" not in j:
        items = [j]
    elif isinstance(j, list) and j and all(isinstance(o, dict) and "protocol" in o for o in j):
        items = j
    else:
        return None
    out = []
    for it in items:
        if not isinstance(it, dict) or it.get("protocol") in _XRAY_NOT_SERVERS:
            continue
        server = _xray_server(it)
        if not server[0]:
            continue
        ob = {k: v for k, v in it.items() if k not in ("tag", "proxySettings", "sendThrough")}
        ss = ob.get("streamSettings")
        if isinstance(ss, dict) and isinstance(ss.get("sockopt"), dict):
            ss["sockopt"].pop("dialerProxy", None)     # цепочки на другие outbound не переносим
        net = (ss or {}).get("network", "tcp") if isinstance(ss, dict) else "tcp"
        name = str(it.get("tag") or f"{it['protocol']} {server[0]}").strip()
        out.append((name, {"type": f"{it['protocol']}+{net} (xray)", "_xray": ob, "_server": server}))
    if not out:
        raise ProfileError("в конфиге Xray нет ни одного сервера (outbound с адресом)")
    return out


def parse_singbox_json(text):
    """Outbound/endpoint sing-box или целый конфиг: берём все серверы из него."""
    try:
        j = json.loads(text)
    except ValueError as e:
        raise ProfileError(f"JSON не разбирается: {e}")
    xray = parse_xray_json(j)
    if xray is not None:
        return xray
    items = []
    if isinstance(j, list):
        items = j
    elif isinstance(j, dict) and ("outbounds" in j or "endpoints" in j):
        items = list(j.get("endpoints") or []) + list(j.get("outbounds") or [])
    elif isinstance(j, dict):
        items = [j]
    out = []
    for it in items:
        if not isinstance(it, dict) or it.get("type") in _NOT_SERVERS or "type" not in it:
            continue
        ob = {k: v for k, v in it.items() if k not in ("tag", "detour", "domain_resolver")}
        name = str(it.get("tag") or f"{it['type']} {it.get('server', '')}").strip()
        out.append((name, ob))
    if not out:
        raise ProfileError("в JSON нет ни одного сервера (outbound с адресом)")
    return out


def parse_profiles(text, source="custom", _depth=0):
    """
    Разбирает всё, что дал пользователь: файл, ссылку, список ссылок,
    подписку. Возвращает (профили, сообщения об ошибках).
    """
    text = text.strip().lstrip("﻿")
    if not text:
        raise ProfileError("пустой ввод")
    profiles, errors = [], []

    def add(name, ob):
        if "_xray" in ob:
            profiles.append({"name": name.strip() or ob["type"], "source": source, "type": ob["type"],
                             "endpoint": False, "engine": "xray", "xray": ob["_xray"],
                             "server": ob["_server"],
                             "outbound": {"type": "socks", "server": "127.0.0.1",
                                          "server_port": XRAY_PORT, "version": "5"}})
            return
        profiles.append({"name": name.strip() or ob.get("type", "сервер"), "source": source,
                         "type": ob.get("type"), "endpoint": ob.get("type") == "wireguard",
                         "outbound": ob})

    if re.search(r"(?im)^\s*\[interface\]", text):
        name, ob = parse_wireguard_conf(text, "Proton VPN" if source == "proton" else "WireGuard")
        add(name, ob)
        return profiles, errors
    if text[0] in "{[":
        for name, ob in parse_singbox_json(text):
            add(name, ob)
        return profiles, errors

    lines = [ln.strip() for ln in text.splitlines() if ln.strip() and not ln.strip().startswith("#")]
    # Подписка: один адрес http(s)://
    if len(lines) == 1 and re.match(r"(?i)^https?://", lines[0]) and _depth == 0:
        try:
            body = http_get(lines[0], timeout=30).decode("utf-8", "replace")
        except Exception as e:
            raise ProfileError(f"подписка не скачалась: {e}")
        return parse_profiles(body, source, _depth + 1)
    # Подписка в base64 (нет ни одной «://»)
    if "://" not in text and _depth < 2:
        try:
            dec = _b64(text)
        except Exception:
            dec = ""
        if "://" in dec or "[Interface]" in dec:
            return parse_profiles(dec, source, _depth + 1)
        raise ProfileError("формат не распознан. Поддерживается: " + SUPPORTED_FORMATS)

    for ln in lines:
        m = re.match(r"^([a-zA-Z0-9]+)://", ln)
        if not m:
            continue
        scheme = m.group(1).lower()
        parser = LINK_PARSERS.get(scheme)
        if not parser:
            errors.append(f"{scheme}://… — формат не поддерживается")
            continue
        try:
            name, ob = parser(ln)
            add(name, ob)
        except ProfileError as e:
            errors.append(f"{scheme}://… — {e}")
        except Exception as e:
            errors.append(f"{scheme}://… — ссылка повреждена ({e.__class__.__name__}: {e})")
    if not profiles and not errors:
        raise ProfileError("формат не распознан. Поддерживается: " + SUPPORTED_FORMATS)
    return profiles, errors


def profile_server(p):
    """(хост, порт, это_udp) сервера профиля."""
    ob = p["outbound"]
    if p.get("engine") == "xray":
        host, port = (p.get("server") or ["", None])[:2]
        net = ((p.get("xray") or {}).get("streamSettings") or {}).get("network", "tcp")
        udp = net in ("kcp", "quic", "hysteria") or (p.get("xray") or {}).get("protocol") in ("wireguard", "hysteria")
        return host, port, udp
    if p.get("endpoint"):
        peer = (ob.get("peers") or [{}])[0]
        return peer.get("address", ""), peer.get("port"), True
    return ob.get("server", ""), ob.get("server_port"), ob.get("type") in ("hysteria", "hysteria2", "tuic")


def load_profiles():
    return read_json(tunnel_path("profiles.json")) or []


def save_profiles(profiles):
    os.makedirs(tunnel_dir(), exist_ok=True)
    write_json(tunnel_path("profiles.json"), profiles)
    update_tunnel_servers(profiles)


def tunnel_ipset_header():
    return (["# Адреса, которые zapret не трогает: трафик в туннель (FakeIP, Telegram) и серверы туннеля.",
             "# Файл создаётся автоматически.", TUNNEL_FAKE4, TUNNEL_FAKE6]
            + TELEGRAM_CIDR4 + TELEGRAM_CIDR6)


def ensure_tunnel_ipset():
    """Файл исключений zapret всегда содержит диапазоны FakeIP."""
    os.makedirs(ipset_dir(), exist_ok=True)
    merge_list_file(tunnel_servers_path(), tunnel_ipset_header())


def update_tunnel_servers(profiles):
    """
    Адреса серверов туннеля — в файл исключений zapret: соединение с самим
    сервером zapret не должен «лечить» подменой SNI и разрезанием (сервер на
    Hetzner/OVH/DigitalOcean попал бы под профиль хостингов).
    """
    ips = []
    for p in profiles:
        host = profile_server(p)[0]
        if not host:
            continue
        if _is_ip(host):
            cand = [host]
        else:
            try:
                cand = sorted({i[4][0] for i in socket.getaddrinfo(host, None)})
            except OSError:
                cand = []
        for ip in cand:
            if ip not in ips:
                ips.append(ip)
    os.makedirs(ipset_dir(), exist_ok=True)
    atomic_write(tunnel_servers_path(),
                 "\n".join(tunnel_ipset_header() + ips) + "\n", mode=0o644)


def tunnel_wg_ports():
    """UDP-порты серверов WireGuard: zapret маскирует их рукопожатие."""
    ports = []
    for p in load_profiles():
        host, port, _ = profile_server(p)
        if p.get("endpoint") and port and str(port) not in ports:
            ports.append(str(port))
    return ports


def profile_parts(p, tag="tunnel", probe=False):
    """(endpoints, outbounds) для конфига sing-box."""
    ob = dict(p["outbound"])
    ob["tag"] = tag
    if p.get("engine") == "xray":
        ob["server_port"] = XRAY_PROBE_PORT if probe else XRAY_PORT
    return ([ob], []) if p.get("endpoint") else ([], [ob])


def xray_config(profile, port):
    """Конфиг xray-core: локальный SOCKS -> сервер профиля."""
    ob = dict(profile["xray"])
    ob["tag"] = "proxy"
    return {"log": {"loglevel": "warning"},
            "inbounds": [{"tag": "socks-in", "listen": "127.0.0.1", "port": port,
                          "protocol": "socks", "settings": {"auth": "noauth", "udp": True}}],
            "outbounds": [ob]}


def validate_profile(p):
    """Проверяет профиль настоящим sing-box или xray-core: (годен, текст ошибки)."""
    if p.get("engine") == "xray":
        try:
            install_xray()
        except Exception as e:
            return False, f"xray-core не скачался: {e}"
        path = tunnel_path("validate-xray.json")
        write_json(path, xray_config(p, XRAY_PROBE_PORT))
        rc, out, errout = run([xray_path(), "run", "-test", "-c", path], timeout=30)
        try:
            os.remove(path)
        except OSError:
            pass
        msg = [ln for ln in (out + "\n" + errout).splitlines() if ln.strip()]
        return rc == 0, (msg[-1] if msg else "")
    eps, obs = profile_parts(p)
    cfg = {"log": {"level": "error"}, "outbounds": obs + [{"type": "direct", "tag": "direct"}],
           "route": {"final": "tunnel", "default_domain_resolver": "local"},
           "dns": {"servers": [{"type": "local", "tag": "local"}]}}
    if eps:
        cfg["endpoints"] = eps
    path = tunnel_path("validate.json")
    write_json(path, cfg)
    rc, out, errout = run([singbox_path(), "check", "-c", path], timeout=30)
    try:
        os.remove(path)
    except OSError:
        pass
    msg = re.sub(r"\x1b\[[0-9;]*m", "", (errout or out)).strip().splitlines()
    return rc == 0, (msg[-1] if msg else "")


def import_profiles(text, source="custom", replace=False):
    """Разбирает ввод, проверяет профили sing-box и сохраняет годные."""
    ensure_root(sys.argv)
    cleanup_legacy_warp()
    if not os.access(singbox_path(), os.X_OK):
        install_singbox()
    profiles, errors = parse_profiles(text, source)
    good = []
    for p in profiles:
        valid, why = validate_profile(p)
        if valid:
            good.append(p)
        else:
            eng = "xray-core" if p.get("engine") == "xray" else "sing-box"
            errors.append(f"{p['name']} — {eng} не принял профиль: {why}")
    for e in errors:
        warn(e)
    if not good:
        raise ProfileError("ни один профиль не подошёл")
    if len(good) > 40:
        warn(f"В подписке {len(good)} серверов — беру первые 40.")
        good = good[:40]
    existing = [] if replace else load_profiles()
    names = {p["name"] for p in existing}
    for p in good:
        base, n = p["name"], 2
        while p["name"] in names:      # одинаковые имена различаем номером
            p["name"] = f"{base} ({n})"
            n += 1
        names.add(p["name"])
        existing.append(p)
    save_profiles(existing)
    ok(f"Добавлено профилей: {len(good)}. Всего: {len(existing)}")
    for p in good:
        host, port, _ = profile_server(p)
        info(f"{p['name']}  [{p['type']}]  {host}:{port}")
    # zapret должен узнать о новых серверах (исключения, порты WireGuard).
    write_config()
    if nfqws2_running():
        info("Перезапуск обхода, чтобы zapret учёл серверы туннеля...")
        run_init("stop")
        run_init("start")
    st = read_json(tunnel_path("state.json")) or {}
    if not (st.get("pinned") and find_profile(st.get("active", ""))):
        try:
            os.remove(tunnel_path("state.json"))    # выбрать лучший профиль заново
        except OSError:
            pass
    return good


def read_user_input(value):
    """Путь к файлу -> его содержимое; иначе сам текст (ссылка, base64, JSON)."""
    value = value.strip().strip("'\"")
    path = os.path.expanduser(value)
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    if "\n" not in value and "://" not in value and not value.startswith(("{", "[")) \
            and ("/" in value or value.endswith((".conf", ".json", ".txt"))):
        raise ProfileError(f"файл не найден: {path}")
    return value


# --- конфигурация sing-box ---------------------------------------------------

def ipv6_available():
    return os.path.isfile("/proc/net/if_inet6")


# --- внешний список сайтов с региональными ограничениями ---------------------
#
# Сайты, которые сами не пускают из России (claude.ai, chatgpt.com...),
# «обучением» не найти: соединение с ними проходит, отказ приходит уже от
# сайта. Их список ведёт сообщество (itdoginfo/allow-domains, раздел
# GeoBlock). При включённом туннеле он скачивается, добавляется к списку
# туннеля и обновляется раз в сутки. Свой список туннеля при этом не меняется.

GEOLIST_URL = "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Categories/geoblock.lst"
GEOLIST_FILE = "zapret2win-hosts-geoblock.txt"
GEOLIST_SERVICE = "zapret2win-geolist"
GEOLIST_UNIT_PATH = f"/etc/systemd/system/{GEOLIST_SERVICE}.service"
GEOLIST_TIMER_PATH = f"/etc/systemd/system/{GEOLIST_SERVICE}.timer"
GEOLIST_MAX_AGE = 24 * 3600
# systemd-resolved принимает не больше 1024 доменов на интерфейс.
TUNNEL_DOMAINS_MAX = 1000
_DOMAIN_RE = re.compile(r"^(?:[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?\.)+[a-z0-9-]{2,}$")


def geolist_path():
    return os.path.join(ipset_dir(), GEOLIST_FILE)


def geolist_enabled():
    return not os.path.isfile(tunnel_path("geolist.off"))


def geolist_entries():
    return list_entries(geolist_path()) if geolist_enabled() else []


def geolist_age():
    """Сколько секунд назад список обновлялся; None, если его ещё нет."""
    try:
        return max(0.0, time.time() - os.path.getmtime(geolist_path()))
    except OSError:
        return None


def tunnel_domains():
    """Все домены, идущие в туннель: свой список и внешний, без повторов."""
    doms = list_entries(tunnel_list_path())
    seen = set(doms)
    for d in geolist_entries():
        if d not in seen:
            seen.add(d)
            doms.append(d)
    return doms[:TUNNEL_DOMAINS_MAX]


def parse_geolist(text):
    """Домены из скачанного списка: по одному в строке, прочее отбрасывается."""
    out, seen = [], set()
    for ln in text.splitlines():
        d = ln.split("#", 1)[0].strip().lower().strip(".")
        if d and _DOMAIN_RE.match(d) and d not in seen:
            seen.add(d)
            out.append(d)
    return out


def fetch_geolist():
    """Скачивает список: напрямую, а если не вышло и туннель работает - через него."""
    last = None
    openers = [urllib.request.build_opener()]
    if tunnel_running():
        proxy = f"http://127.0.0.1:{TUNNEL_MIXED_PORT}"
        openers.append(urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy})))
    for op in openers:
        try:
            req = urllib.request.Request(GEOLIST_URL, headers={"User-Agent": f"zapret2-linux/{VERSION}"})
            with op.open(req, timeout=30) as r:
                doms = parse_geolist(r.read(4 * 1024 * 1024).decode("utf-8", "replace"))
            if len(doms) < 50:
                raise ValueError(f"в ответе только {len(doms)} доменов - это не список")
            return doms
        except Exception as e:
            last = e
    raise RuntimeError(f"список не скачался: {last}")


def update_geolist(force=False):
    """
    Обновляет внешний список, если он старше суток (или force). Возвращает
    True, если список скачан заново. Сбой не мешает работе: остаётся прежний.
    """
    if not geolist_enabled():
        return False
    age = geolist_age()
    if not force and age is not None and age < GEOLIST_MAX_AGE - 3600:
        return False
    try:
        doms = fetch_geolist()
    except Exception as e:
        warn(f"Внешний список сайтов с региональными ограничениями: {e}")
        if age is not None:
            info("Используется прежний список.")
        return False
    old = set(list_entries(geolist_path()))
    os.makedirs(ipset_dir(), exist_ok=True)
    tmp = geolist_path() + ".new"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# Сайты, которые сами не пускают из России. Источник:\n"
                f"# {GEOLIST_URL}\n"
                "# Файл обновляется автоматически раз в сутки - правки здесь будут потеряны.\n"
                "# Свои сайты добавляйте в " + TUNNEL_LIST_FILE + ".\n")
        f.write("\n".join(doms) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, geolist_path())
    new = set(doms)
    ok(f"Внешний список сайтов с региональными ограничениями: {len(doms)} доменов"
       + (f" (добавлено {len(new - old)}, убрано {len(old - new)})" if old else ""))
    remove_hosts_domains(doms)
    write_tunnel_rules()
    flush_dns()
    return True


def install_geolist_timer():
    """
    Обновление списка раз в сутки - таймер systemd. Таймеру нужен скрипт по
    постоянному адресу, поэтому в каталог туннеля кладётся его копия.
    """
    if not which("systemctl"):
        return
    copy = tunnel_path("zapret2-linux.sh")
    try:
        if os.path.abspath(__file__) != copy:
            shutil.copy2(os.path.abspath(__file__), copy)
            os.chmod(copy, 0o755)
    except OSError:
        return
    with open(GEOLIST_UNIT_PATH, "w", encoding="utf-8") as f:
        f.write(f"""[Unit]
Description=Zapret2: update the list of region-restricted sites for the tunnel
After=network-online.target

[Service]
Type=oneshot
ExecStart={sys.executable} {copy} --action tunnel-geolist-auto
""")
    with open(GEOLIST_TIMER_PATH, "w", encoding="utf-8") as f:
        f.write(f"""[Unit]
Description=Zapret2: daily update of the region-restricted sites list

[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
RandomizedDelaySec=10min

[Install]
WantedBy=timers.target
""")
    run(["systemctl", "daemon-reload"], timeout=60)
    run(["systemctl", "enable", "--now", f"{GEOLIST_SERVICE}.timer"], timeout=60)


def remove_geolist_timer():
    if which("systemctl"):
        run(["systemctl", "disable", "--now", f"{GEOLIST_SERVICE}.timer"], timeout=60)
    removed = False
    for unit in (GEOLIST_TIMER_PATH, GEOLIST_UNIT_PATH):
        try:
            os.remove(unit)
            removed = True
        except OSError:
            pass
    if removed and which("systemctl"):
        run(["systemctl", "daemon-reload"], timeout=60)


def sync_geolist():
    """Таймер и свежий список есть, пока включены туннель и внешний список."""
    if tunnel_enabled() and geolist_enabled():
        install_geolist_timer()
        update_geolist()
    else:
        remove_geolist_timer()


def geolist_action(force=True):
    ensure_root(sys.argv)
    if not geolist_enabled():
        info("Внешний список выключен (меню туннеля, пункт [12]).")
        return
    update_geolist(force=force)


def toggle_geolist():
    ensure_root(sys.argv)
    flag = tunnel_path("geolist.off")
    if geolist_enabled():
        os.makedirs(tunnel_dir(), exist_ok=True)
        with open(flag, "w") as f:
            f.write("1")
        remove_geolist_timer()
        write_tunnel_rules()
        flush_dns()
        ok("Внешний список выключен: в туннель идут только сайты из своего списка.")
    else:
        try:
            os.remove(flag)
        except OSError:
            pass
        sync_geolist()
        write_tunnel_rules()
        flush_dns()
        if tunnel_enabled():
            ok(f"Внешний список включён: {len(geolist_entries())} доменов.")
        else:
            ok("Внешний список включён: он скачается при включении туннеля.")


def geolist_status():
    if not geolist_enabled():
        return "выключен"
    n = len(geolist_entries())
    age = geolist_age()
    if age is None or not n:
        return "ещё не скачан"
    when = "меньше часа назад" if age < 3600 else f"{int(age // 3600)} ч назад"
    return f"{n} доменов, обновлён {when}"


def write_tunnel_rules():
    """rule-set для sing-box из списка туннеля; sing-box перечитывает его сам."""
    doms = tunnel_domains() or ["tunnel.invalid"]
    write_json(tunnel_path("rules.json"),
               {"version": 2, "rules": [{"domain_suffix": doms}]}, mode=0o644)
    # Полный перечень доменов для скрипта DNS (свой список + внешний).
    atomic_write(tunnel_path("domains.txt"),
                 "\n".join(tunnel_domains()) + "\n", mode=0o644)
    write_tunnel_dns_script()
    if tunnel_tun_exists():
        apply_tunnel_dns()


def tunnel_dns_script_path():
    return tunnel_path("dns-setup.sh")


def write_tunnel_dns_script():
    """
    Скрипт, который направляет DNS-запросы доменов из списка туннеля в sing-box.
    systemd-resolved сам в TUN не ходит, поэтому для интерфейса TUN задаются
    DNS-сервер sing-box и «маршрутные домены» (~домен): в sing-box идут запросы
    только этих доменов и их поддоменов, остальной DNS не меняется.
    """
    script = f"""#!/bin/sh
# Сгенерировано zapret2-linux: DNS доменов туннеля -> sing-box (FakeIP)
IF={TUNNEL_TUN}
LIST='{tunnel_path("domains.txt")}'
command -v resolvectl >/dev/null 2>&1 || exit 0
i=0
while [ $i -lt 30 ] && ! ip link show "$IF" >/dev/null 2>&1; do sleep 0.5; i=$((i+1)); done
ip link show "$IF" >/dev/null 2>&1 || exit 0
DOMS=$(grep -v '^[[:space:]]*#' "$LIST" 2>/dev/null | tr -d ' \\t\\r' | grep . | sed 's/^/~/' | tr '\\n' ' ')
[ -n "$DOMS" ] && DOMS="$DOMS ~{DOH_CANARY}"
resolvectl dns "$IF" {TUNNEL_TUN_DNS4} || exit 0
if [ -n "$DOMS" ]; then resolvectl domain "$IF" $DOMS; else resolvectl domain "$IF" ""; fi
resolvectl default-route "$IF" false 2>/dev/null
resolvectl flush-caches 2>/dev/null
exit 0
"""
    os.makedirs(tunnel_dir(), exist_ok=True)
    with open(tunnel_dns_script_path(), "w", encoding="utf-8") as f:
        f.write(script)
    os.chmod(tunnel_dns_script_path(), 0o755)


def tunnel_tun_exists():
    return os.path.isdir(f"/sys/class/net/{TUNNEL_TUN}")


def apply_tunnel_dns():
    if which("resolvectl"):
        run(["/bin/sh", tunnel_dns_script_path()], timeout=40)


def firefox_doh_forced():
    """
    True, если в Firefox DNS через HTTPS включён вручную (network.trr.mode
    2 или 3): тогда Firefox не слушает системный DNS и сайты из списка
    туннеля идут мимо него. Включённый по умолчанию DoH отключается сам.
    """
    import glob
    import pwd
    homes = set()
    for name in (os.environ.get("SUDO_USER"), os.environ.get("USER")):
        try:
            if name:
                homes.add(pwd.getpwnam(name).pw_dir)
        except KeyError:
            pass
    for home in homes:
        for base in (".mozilla/firefox", "snap/firefox/common/.mozilla/firefox",
                     ".var/app/org.mozilla.firefox/.mozilla/firefox"):
            for prefs in glob.glob(os.path.join(home, base, "*", "prefs.js")):
                try:
                    with open(prefs, encoding="utf-8", errors="replace") as f:
                        if re.search(r'user_pref\("network\.trr\.mode",\s*[23]\)', f.read()):
                            return True
                except OSError:
                    pass
    return False


def warn_browser_dns():
    if firefox_doh_forced():
        warn("В Firefox вручную включён «DNS через HTTPS»: он узнаёт адреса сайтов мимо туннеля.")
        info("Настройки Firefox -> Приватность и защита -> DNS через HTTPS -> «Отключено», затем перезапустите Firefox.")
    else:
        info("Браузер нужно перезапустить: он помнит прежние адреса сайтов. Если в браузере вручную "
             "включён «Безопасный DNS» (DNS через HTTPS), отключите его.")


def check_tunnel_dns():
    """Проверяет, что домен из списка туннеля действительно получает FakeIP."""
    doms = tunnel_domains()
    if not doms:
        return
    try:
        ips = {i[4][0] for i in socket.getaddrinfo(doms[0], 443, socket.AF_INET, socket.SOCK_STREAM)}
    except OSError as e:
        ips = set()
        warn(f"DNS: {doms[0]} не разрешается ({e})")
    if any(ip.startswith(TUNNEL_FAKE4_PREFIX) for ip in ips):
        ok(f"DNS доменов из списка идёт в туннель ({doms[0]} -> {sorted(ips)[0]})")
        return
    warn(f"DNS: {doms[0]} получает обычный адрес ({', '.join(sorted(ips)) or 'нет'}), "
         f"а не адрес туннеля {TUNNEL_FAKE4_PREFIX}x.x — сайт пойдёт мимо туннеля.")
    if not which("resolvectl"):
        info("В системе нет systemd-resolved: автоматическая настройка DNS для туннеля не поддерживается.")
    else:
        info(f"Проверьте: resolvectl status {TUNNEL_TUN}; запись домена в /etc/hosts.")


def build_tunnel_config(profile):
    write_tunnel_rules()
    eps, obs = profile_parts(profile)
    # Без IPv6 в системе sing-box не сможет назначить TUN v6-адрес и упадёт.
    v6 = ipv6_available()
    fake = {"type": "fakeip", "tag": "fakeip", "inet4_range": TUNNEL_FAKE4}
    if v6:
        fake["inet6_range"] = TUNNEL_FAKE6
    discord_media = DISCORD_MEDIA_CIDR4 if discord_media_tunneled() else []
    # Из адресов Discord в туннель идёт только UDP (медиа); TCP к ним - напрямую.
    discord_tcp = ([{"inbound": ["tun-in"], "network": "tcp", "ip_cidr": discord_media,
                     "outbound": "direct"}] if discord_media else [])
    cfg = {
        "log": {"level": "warn", "timestamp": True},
        "dns": {
            "servers": [
                {"type": "local", "tag": "local"},
                fake,
                # Настоящие адреса сайтов из списка ищем через сам туннель.
                {"type": "tcp", "tag": "tunnel-dns", "server": "1.1.1.1", "detour": "tunnel"},
            ],
            "rules": [{"domain": [DOH_CANARY], "action": "predefined", "rcode": "NXDOMAIN"},
                      {"inbound": ["tun-in"], "rule_set": ["tunnel-domains"],
                       "query_type": ["A", "AAAA"], "server": "fakeip"}],
            "final": "local",
        },
        "inbounds": [
            {
                "type": "tun", "tag": "tun-in", "interface_name": TUNNEL_TUN,
                "address": [TUNNEL_TUN_ADDR4] + ([TUNNEL_TUN_ADDR6] if v6 else []),
                "mtu": 1400,
                "auto_route": True,
                # В TUN идут только FakeIP, подсети Telegram и (если проверка так
                # решила) медиасерверы Discord: остальной трафик мимо sing-box.
                "route_address": ([TUNNEL_FAKE4] + TELEGRAM_CIDR4 + discord_media
                                  + ([TUNNEL_FAKE6] + TELEGRAM_CIDR6 if v6 else [])),
                "iproute2_table_index": TUNNEL_RT_TABLE,
                "iproute2_rule_index": TUNNEL_RT_RULE,
            },
            {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1",
             "listen_port": TUNNEL_MIXED_PORT},
        ],
        "outbounds": [{"type": "direct", "tag": "direct"}] + obs,
        "route": {
            "rule_set": [{"type": "local", "tag": "tunnel-domains", "format": "source",
                          "path": tunnel_path("rules.json")}],
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
            ] + discord_tcp + [
                {"inbound": ["tun-in", "mixed-in"], "action": "resolve", "server": "tunnel-dns"},
                {"inbound": ["tun-in", "mixed-in"], "outbound": "tunnel"},
            ],
            "final": "direct",
            "auto_detect_interface": True,
            "default_domain_resolver": "local",
        },
        "experimental": {"cache_file": {"enabled": True, "path": tunnel_path("cache.db"),
                                        "store_fakeip": True}},
    }
    if eps:
        cfg["endpoints"] = eps
    return cfg


# --- проверка туннеля ---------------------------------------------------------

# Firefox спрашивает этот домен у системного DNS; ответ «нет такого домена»
# выключает его встроенный DNS через HTTPS (если тот включён по умолчанию, а
# не вручную). Иначе Firefox узнаёт адреса сайтов мимо туннеля.
DOH_CANARY = "use-application-dns.net"

TUNNEL_TRACE_LAST = ""   # чем закончилась последняя проверка туннеля
TUNNEL_EXIT = {}         # откуда туннель выходит в интернет: loc, colo, ip


def tunnel_trace(port, timeout=6.0):
    """
    Запрос https://1.1.1.1/cdn-cgi/trace через прокси sing-box: мс или -1.
    Ответ содержит страну (loc) и адрес (ip), под которыми туннель виден
    сайтам. Прокси задан для http и https, чтобы запрос не ушёл напрямую.
    """
    global TUNNEL_TRACE_LAST
    proxy = f"http://127.0.0.1:{port}"
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": proxy, "https": proxy}),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    for url in ("https://1.1.1.1/cdn-cgi/trace", "https://www.cloudflare.com/cdn-cgi/trace"):
        t0 = time.monotonic()
        try:
            with opener.open(url, timeout=timeout) as r:
                text = r.read(4096).decode("utf-8", "replace")
            if "loc=" in text:
                TUNNEL_EXIT.clear()
                for key in ("loc", "colo", "ip"):
                    mm = re.search(rf"(?m)^{key}=(\S+)", text)
                    if mm:
                        TUNNEL_EXIT[key] = mm.group(1)
                TUNNEL_TRACE_LAST = f"{url}: ответ получен, страна {TUNNEL_EXIT.get('loc')}"
                return int((time.monotonic() - t0) * 1000)
            TUNNEL_TRACE_LAST = f"{url}: неожиданный ответ"
        except Exception as e:
            TUNNEL_TRACE_LAST = f"{url}: {e.__class__.__name__}: {e}"
    return -1


def tunnel_ping(port, tries=3, timeout=4.0):
    """
    Задержка через туннель: время установки TCP-соединения с 1.1.1.1:443
    через прокси sing-box (CONNECT), лучший из нескольких замеров, мс.
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


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def geo_probe(domain, port, timeout=10.0):
    """
    Пускает ли сайт с адреса туннеля. Запрос идёт через локальный прокси.
    'ok' - открывается; 'geo' - отказ по региону (код 451, перенаправление
    или страница с таким текстом); 'challenge' - сайт отвечает, но требует
    проверку браузера (по ней регион не определить); 'deny' - отказ 403 без
    объяснения (часто так закрывают адреса VPN); 'fail' - нет ответа.
    """
    proxy = f"http://127.0.0.1:{port}"
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": proxy, "https": proxy}),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()), _NoRedirect())
    url = f"https://{domain}/"
    for _ in range(4):
        req = urllib.request.Request(url, headers={
            "User-Agent": BROWSER_UA, "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9"})
        try:
            r = opener.open(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            r = e
        except Exception:
            return "fail"
        code = r.getcode()
        hdr = r.headers
        try:
            body = r.read(65536).decode("utf-8", "replace")
        except Exception:
            body = ""
        finally:
            r.close()
        if code == 451:
            return "geo"
        if 300 <= code < 400 and hdr.get("Location"):
            loc = urllib.parse.urljoin(url, hdr["Location"])
            if GEO_RE.search(loc):
                return "geo"
            if not loc.lower().startswith("https://"):
                return "ok"
            url = loc
            continue
        if GEO_RE.search(body[:20000]) and code >= 400:
            return "geo"
        if (hdr.get("cf-mitigated") or "").lower() == "challenge":
            return "challenge"
        if code == 403:
            return "geo" if GEO_RE.search(body) else "deny"
        if GEO_RE.search(body[:20000]) and len(body) < 20000:
            return "geo"
        return "ok" if code < 500 else "fail"
    return "ok"


def geo_check(port):
    """Проверка всех сайтов из списка региональных ограничений: {сайт: статус}."""
    sites = list_entries(geo_list_path())
    if not sites:
        return {}
    import concurrent.futures
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        return dict(zip(sites, ex.map(lambda d: geo_probe(d, port), sites)))


def geo_score(geo):
    """Сколько сайтов пускают с этого адреса (проверка браузера - не отказ)."""
    return sum(1 for v in geo.values() if v in ("ok", "challenge"))


def geo_summary(geo):
    if not geo:
        return ""
    bad = [f"{d}: {GEO_LABEL[v]}" for d, v in geo.items() if v not in ("ok", "challenge")]
    return f"сайты {geo_score(geo)}/{len(geo)}" + (f" ({'; '.join(bad)})" if bad else "")


def start_xray_probe(profile):
    """Пробный xray-core для профиля: процесс или None."""
    global TUNNEL_TRACE_LAST
    install_xray()
    path = tunnel_path("probe-xray.json")
    write_json(path, xray_config(profile, XRAY_PROBE_PORT))
    logf = open(tunnel_path("probe-xray.log"), "w")
    proc = subprocess.Popen([xray_path(), "run", "-c", path], stdout=logf, stderr=subprocess.STDOUT)
    logf.close()
    if not wait_local_port(XRAY_PROBE_PORT, 8.0, proc):
        TUNNEL_TRACE_LAST = "xray-core не запустился: " + " | ".join(file_tail(tunnel_path("probe-xray.log"), 3))
        stop_proc(proc)
        return None
    return proc


def stop_proc(proc):
    if proc is None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()


def test_profile(profile):
    """Пробный запуск профиля: (задержка мс или -1, страна выхода, {сайт: статус})."""
    global TUNNEL_TRACE_LAST
    host, port, is_udp = profile_server(profile)
    # Быстрый отсев: если TCP-порт сервера не отвечает, туннель не поднимется.
    if host and port and not is_udp:
        try:
            socket.create_connection((host, int(port)), timeout=3).close()
        except OSError as e:
            TUNNEL_TRACE_LAST = f"сервер {host}:{port} не принимает соединение ({e})"
            try:
                os.remove(tunnel_path("probe.log"))
            except OSError:
                pass
            return -1, None, {}
    xproc = None
    if profile.get("engine") == "xray":
        try:
            xproc = start_xray_probe(profile)
        except Exception as e:
            TUNNEL_TRACE_LAST = f"xray-core: {e}"
        if xproc is None:
            return -1, None, {}
    eps, obs = profile_parts(profile, probe=True)
    cfg = {
        "log": {"level": "info"},
        "dns": {"servers": [{"type": "local", "tag": "local"}]},
        "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1",
                      "listen_port": TUNNEL_PROBE_PORT}],
        "outbounds": obs + [{"type": "direct", "tag": "direct"}],
        "route": {"final": "tunnel", "auto_detect_interface": True,
                  "default_domain_resolver": "local"},
    }
    if eps:
        cfg["endpoints"] = eps
    probe = tunnel_path("probe.json")
    write_json(probe, cfg)
    logf = open(tunnel_path("probe.log"), "w")
    proc = subprocess.Popen([singbox_path(), "run", "-c", probe],
                            stdout=logf, stderr=subprocess.STDOUT)
    try:
        if not wait_local_port(TUNNEL_PROBE_PORT, 8.0, proc):
            return -1, None, {}
        if tunnel_trace(TUNNEL_PROBE_PORT, 6.0) < 0:
            return -1, None, {}
        loc = TUNNEL_EXIT.get("loc")
        ping = tunnel_ping(TUNNEL_PROBE_PORT)
        if ping < 2:
            ping = tunnel_trace(TUNNEL_PROBE_PORT, 6.0)
        if ping < 0:
            return -1, loc, {}
        return ping, loc, geo_check(TUNNEL_PROBE_PORT)
    finally:
        stop_proc(proc)
        stop_proc(xproc)
        logf.close()


def select_profile(skip=(), autostart=True):
    """
    Проверяет все профили и выбирает лучший: сначала тот, с которого
    открывается больше сайтов из списка региональных ограничений, затем
    зарубежный выход, затем наименьшая задержка. Снимает ручное закрепление.
    """
    profiles = load_profiles()
    merge_list_file(geo_list_path(), SEED_GEO)
    if not profiles:
        set_tunnel_error("Нет ни одного профиля: импортируйте конфиг Proton VPN Free или своего сервера.")
        return None
    was_running = tunnel_running()
    stop_tunnel(quiet=True)
    results = []
    head("Проверка профилей туннеля...")
    last_fail = []
    for p in profiles:
        if p["name"] in skip:
            continue
        sys.stdout.write(f"    {p['name'][:40]:<40} ")
        sys.stdout.flush()
        ms, loc, geo = test_profile(p)
        if ms >= 0:
            results.append({"name": p["name"], "ms": ms, "loc": loc, "geo": geo,
                            "geo_ok": geo_score(geo)})
            flag = _c(C.YELLOW, " (Россия!)") if loc == "RU" else ""
            gs = geo_summary(geo)
            print(_c(C.GREEN, f"{ms} мс, выход: {loc}") + flag + (f", {gs}" if gs else ""))
        else:
            print(_c(C.GRAY, "нет ответа"))
            last_fail = [f"Профиль «{p['name']}»: {TUNNEL_TRACE_LAST}"] + file_tail(tunnel_path("probe.log"), 6)
    # Доступ к сайтам с региональными ограничениями важнее всего, затем
    # зарубежный выход, затем скорость.
    results.sort(key=lambda r: (-r["geo_ok"], r["loc"] == "RU", r["ms"]))
    if not results:
        set_tunnel_error("Ни один профиль туннеля не ответил.", last_fail)
        warn("Сервер недоступен или его протокол блокируется провайдером.")
        info("Попробуйте при запущенном zapret, другой сервер или другой протокол.")
        return None
    best = results[0]
    write_json(tunnel_path("state.json"), {"active": best["name"], "pinned": False, "ranked": results,
                                           "tested": datetime.now().isoformat(timespec="seconds")})
    clear_tunnel_error()
    gs = geo_summary(best["geo"])
    ok(f"Лучший профиль: {best['name']} (задержка {best['ms']} мс, выход: {best['loc']}"
       + (f", {gs}" if gs else "") + ")")
    if best["geo"] and best["geo_ok"] < len(best["geo"]):
        warn("Ни с одного профиля не открываются все сайты из списка региональных ограничений.")
    if autostart:
        if was_running or (tunnel_enabled() and nfqws2_running()):
            start_tunnel()
        elif tunnel_enabled():
            info("Туннель запустится вместе с обходом (пункт [2] главного меню).")
        else:
            info("Туннель выключен: включите его в меню туннеля, пункт [1].")
    return best["name"]


def use_profile(ref):
    """
    Ручной выбор: номер или имя профиля закрепляет его (автовыбор его не
    сменит); 'auto' снимает закрепление и выбирает лучший заново.
    """
    ensure_root(sys.argv)
    ref = str(ref).strip()
    if ref.lower() in ("auto", "авто"):
        return select_profile()
    profiles = load_profiles()
    profile = None
    if ref.isdigit() and 1 <= int(ref) <= len(profiles):
        profile = profiles[int(ref) - 1]
    else:
        profile = next((p for p in profiles if p["name"] == ref), None) \
            or next((p for p in profiles if ref.lower() in p["name"].lower()), None)
    if not profile:
        raise ProfileError(f"профиль не найден: {ref}")
    st = read_json(tunnel_path("state.json")) or {}
    st.update({"active": profile["name"], "pinned": True})
    was_running = tunnel_running()
    write_json(tunnel_path("state.json"), st)
    ok(f"Выбран профиль «{profile['name']}». Он закреплён: автовыбор его не сменит.")
    if was_running or (tunnel_enabled() and nfqws2_running()):
        start_tunnel()
    elif not tunnel_enabled():
        info("Туннель выключен: включите его в меню туннеля, пункт [1].")
    return profile["name"]


def tunnel_geo():
    """Проверка сайтов с региональными ограничениями через работающий туннель."""
    merge_list_file(geo_list_path(), SEED_GEO)
    if not tunnel_running():
        raise RuntimeError("Туннель не запущен")
    head("Проверка региональных ограничений через активный профиль...")
    geo = geo_check(TUNNEL_MIXED_PORT)
    for d, v in geo.items():
        color = C.GREEN if v in ("ok", "challenge") else C.RED
        print(f"    {d:<28} " + _c(color, GEO_LABEL[v]))
    info(f"Список сайтов: {geo_list_path()} (можно править вручную)")
    if geo and geo_score(geo) < len(geo) and len(load_profiles()) > 1:
        info("Пункт «Проверить профили и выбрать лучший» подберёт профиль, с которого открывается больше сайтов.")


# --- запуск и остановка -------------------------------------------------------

def tunnel_running():
    rc, _, _ = run(["systemctl", "is-active", "--quiet", TUNNEL_SERVICE], timeout=10)
    return rc == 0


def tunnel_enabled():
    return os.path.isfile(tunnel_path("enabled"))


def xray_unit_content():
    return f"""[Unit]
Description=Zapret2 tunnel helper (xray-core) for XHTTP and Xray profiles
After=network-online.target {SERVICE_NAME}.service
PartOf={TUNNEL_SERVICE}.service

[Service]
Type=simple
ExecStart={xray_path()} run -c {tunnel_path('xray.json')}
Restart=on-failure
RestartSec=5
"""


def tunnel_unit_content(with_xray=False):
    xray = f"\nRequires={XRAY_SERVICE}.service\nAfter={XRAY_SERVICE}.service" if with_xray else ""
    # WantedBy/PartOf: при автозапуске обхода туннель поднимается и
    # останавливается вместе со службой zapret.
    return f"""[Unit]
Description=Zapret2 tunnel (sing-box) for sites zapret can't open
After=network-online.target {SERVICE_NAME}.service
Wants=network-online.target
PartOf={SERVICE_NAME}.service{xray}

[Service]
Type=simple
ExecStart={singbox_path()} run -c {tunnel_path('config.json')}
ExecStartPost=-/bin/sh {tunnel_dns_script_path()}
Restart=on-failure
RestartSec=5

[Install]
WantedBy={SERVICE_NAME}.service
"""


def sync_tunnel_autostart():
    """
    Автозапуск обхода запускает и туннель: юнит туннеля привязан к службе
    zapret, пока включены и автозапуск, и туннель.
    """
    if not os.path.isfile(TUNNEL_UNIT_PATH):
        return
    # disable убирает и прежнюю привязку к multi-user.target (версия 1.5.0).
    run(["systemctl", "disable", TUNNEL_SERVICE], timeout=60)
    if service_enabled() and tunnel_enabled():
        run(["systemctl", "enable", TUNNEL_SERVICE], timeout=60)


def set_tunnel_error(message, details=()):
    """Запоминает причину сбоя: её видно в меню туннеля, а не только при запуске."""
    details = list(details)
    err(message)
    for ln in details:
        print(_c(C.GRAY, f"    {ln}"))
    try:
        os.makedirs(tunnel_dir(), exist_ok=True)
        atomic_write(tunnel_path("last-error.txt"),
                     f"{datetime.now().isoformat(timespec='seconds')} {message}\n"
                     + "\n".join(details) + "\n", mode=0o644)
    except OSError:
        pass


def clear_tunnel_error():
    try:
        os.remove(tunnel_path("last-error.txt"))
    except OSError:
        pass


def journal_tail(lines=15):
    rc, out, _ = run(["journalctl", "-u", TUNNEL_SERVICE, "-n", str(lines),
                      "--no-pager", "-o", "cat"], timeout=15)
    out = re.sub(r"\x1b\[[0-9;]*m", "", out)
    return [ln for ln in out.splitlines() if ln.strip()] if rc == 0 else []


def find_profile(name):
    for p in load_profiles():
        if p["name"] == name:
            return p
    return None


def start_tunnel_process(profile):
    """
    'ok', 'crash' (sing-box завершился: ошибка конфига, TUN, прав) или
    'notunnel' (sing-box работает, но трафик через сервер не идёт).
    """
    write_json(tunnel_path("config.json"), build_tunnel_config(profile))
    rc, out, errout = run([singbox_path(), "check", "-c", tunnel_path("config.json")], timeout=30)
    if rc != 0:
        set_tunnel_error("Конфиг sing-box не прошёл проверку.", (errout or out).splitlines())
        return "crash"
    use_xray = profile.get("engine") == "xray"
    if use_xray:
        try:
            install_xray()
        except Exception as e:
            set_tunnel_error(f"xray-core не скачался: {e}")
            return "crash"
        write_json(tunnel_path("xray.json"), xray_config(profile, XRAY_PORT))
        with open(XRAY_UNIT_PATH, "w", encoding="utf-8") as f:
            f.write(xray_unit_content())
    with open(TUNNEL_UNIT_PATH, "w", encoding="utf-8") as f:
        f.write(tunnel_unit_content(with_xray=use_xray))
    run(["systemctl", "daemon-reload"], timeout=60)
    if use_xray:
        run(["systemctl", "reset-failed", XRAY_SERVICE], timeout=30)
        run(["systemctl", "restart", XRAY_SERVICE], timeout=60)
        if not wait_local_port(XRAY_PORT, 10.0):
            rc, out, _ = run(["journalctl", "-u", XRAY_SERVICE, "-n", "12", "--no-pager", "-o", "cat"], timeout=15)
            set_tunnel_error("xray-core не запустился.", [ln for ln in out.splitlines() if ln.strip()])
            return "crash"
    elif os.path.isfile(XRAY_UNIT_PATH):
        run(["systemctl", "stop", XRAY_SERVICE], timeout=60)
    run(["systemctl", "reset-failed", TUNNEL_SERVICE], timeout=30)
    run(["systemctl", "restart", TUNNEL_SERVICE], timeout=60)
    # Создание TUN и маршрутов может занять несколько секунд.
    if not wait_local_port(TUNNEL_MIXED_PORT, 30.0, alive=tunnel_running):
        if tunnel_running():
            set_tunnel_error("sing-box не открыл локальный порт за 30 секунд.", journal_tail())
        else:
            set_tunnel_error("Служба sing-box завершилась при запуске.", journal_tail())
        return "crash"
    for _ in range(3):
        if not tunnel_running():
            break
        if tunnel_trace(TUNNEL_MIXED_PORT, 6.0) >= 0:
            clear_tunnel_error()
            return "ok"
        time.sleep(1)
    if not tunnel_running():
        set_tunnel_error("Служба sing-box завершилась.", journal_tail())
        return "crash"
    set_tunnel_error(f"Через профиль «{profile['name']}» не идёт трафик.",
                     [f"Проверка туннеля: {TUNNEL_TRACE_LAST}"] + journal_tail(8))
    return "notunnel"


def start_tunnel():
    ensure_root(sys.argv)
    cleanup_legacy_warp()
    if not which("systemctl"):
        set_tunnel_error("Для туннеля нужен systemd (sing-box запускается как служба).")
        return
    if not load_profiles():
        set_tunnel_error("Нет ни одного профиля: импортируйте конфиг Proton VPN Free или своего сервера.")
        return
    try:
        if not os.access(singbox_path(), os.X_OK):
            install_singbox()
    except Exception as e:
        lines = str(e).splitlines() or ["ошибка"]
        set_tunnel_error(lines[0], lines[1:])
        return
    stop_tunnel(quiet=True)
    sync_geolist()      # список старше суток обновляется; таймер на месте
    st = read_json(tunnel_path("state.json")) or {}
    profile = find_profile(st.get("active", ""))
    if not profile:
        name = select_profile(autostart=False)
        profile = find_profile(name) if name else None
    if not profile:
        return
    head(f"Запуск туннеля (профиль «{profile['name']}»)...")
    r = start_tunnel_process(profile)
    if r == "notunnel" and st.get("pinned"):
        warn("Профиль выбран вручную, поэтому на другой не переключаюсь. "
             "Автовыбор: меню туннеля, пункт [5].")
    elif r == "notunnel" and len(load_profiles()) > 1:
        warn("Профиль не отвечает, проверяю остальные...")
        stop_tunnel(quiet=True)
        name = select_profile(skip=(profile["name"],), autostart=False)
        profile = find_profile(name) if name else None
        r = start_tunnel_process(profile) if profile else "crash"
    if r != "ok":
        stop_tunnel(quiet=True)
        err("Туннель не запущен. Причина выше; она же в меню туннеля и в журнале:")
        info(f"journalctl -u {TUNNEL_SERVICE}")
        return
    sync_tunnel_autostart()
    apply_tunnel_dns()
    flush_dns()
    ok(f"Туннель работает: «{profile['name']}». Сайтов в туннеле: {tunnel_sites_summary()}")
    report_tunnel_exit()
    check_tunnel_dns()


def report_tunnel_exit():
    """Показывает, из какой страны туннель выходит в интернет."""
    if not TUNNEL_EXIT:
        return
    write_json(tunnel_path("exit.json"), TUNNEL_EXIT, mode=0o644)
    loc = TUNNEL_EXIT.get("loc", "?")
    info(f"Выход в интернет: страна {loc}, адрес {TUNNEL_EXIT.get('ip', '?')}")
    if loc == "RU":
        warn("Выход — в России: сервисы, которые сами не пускают из России, через туннель не откроются.")


def tunnel_starter_pid():
    """PID фонового запуска туннеля, если он ещё идёт."""
    try:
        with open(tunnel_path("starting.pid")) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def start_tunnel_background():
    """Запуск туннеля следом за zapret, не задерживая сам обход."""
    if tunnel_starter_pid():
        info("Туннель уже запускается в фоне")
        return
    log = tunnel_path("start.log")
    os.makedirs(tunnel_dir(), exist_ok=True)
    with open(log, "w", encoding="utf-8") as f:
        p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--action", "tunnel-start"],
                             stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT,
                             start_new_session=True)
    with open(tunnel_path("starting.pid"), "w") as f:
        f.write(str(p.pid))
    info(f"Туннель запускается в фоне — статус в меню [11], журнал: {log}")


def tunnel_start_action():
    """Действие tunnel-start: запуск туннеля, если он включён (используется фоном)."""
    try:
        if tunnel_enabled():
            start_tunnel()
        else:
            info("Туннель выключен")
    finally:
        try:
            os.remove(tunnel_path("starting.pid"))
        except OSError:
            pass


def stop_tunnel(quiet=False):
    # Остановка во время фонового запуска: прерываем и запуск. Себя не трогаем.
    pid = tunnel_starter_pid()
    if pid and pid != os.getpid():
        try:
            os.killpg(pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            os.remove(tunnel_path("starting.pid"))
        except OSError:
            pass
    if os.path.isfile(TUNNEL_UNIT_PATH):
        run(["systemctl", "stop", TUNNEL_SERVICE], timeout=60)
    if os.path.isfile(XRAY_UNIT_PATH):
        run(["systemctl", "stop", XRAY_SERVICE], timeout=60)
    kill_by_cmdline(f"{singbox_path()} run", f"{xray_path()} run")
    if not quiet:
        ok("Туннель остановлен")


def enable_tunnel(assume_yes=False):
    ensure_root(sys.argv)
    cleanup_legacy_warp()
    os.makedirs(tunnel_dir(), exist_ok=True)
    os.makedirs(ipset_dir(), exist_ok=True)
    merge_list_file(tunnel_list_path(), SEED_TUNNEL)
    merge_list_file(geo_list_path(), SEED_GEO)
    if not load_profiles():
        raise RuntimeError(
            "Сначала добавьте профиль: Proton VPN Free (пункт [2]) или свой сервер (пункт [3])."
        )
    with open(tunnel_path("enabled"), "w") as f:
        f.write("1")
    sync_geolist()
    start_tunnel()
    if tunnel_running():
        ans = "y"
        if not assume_yes:
            try:
                ans = input("  Проверить сайты из списков и трансляции Discord и перенести в туннель "
                            "то, что не работает через zapret? (Y/n) ").strip().lower()
            except EOFError:
                ans = "y"
        if ans not in ("n", "no", "н", "нет"):
            update_tunnel_routes()


def disable_tunnel():
    ensure_root(sys.argv)
    try:
        os.remove(tunnel_path("enabled"))
    except OSError:
        pass
    stop_tunnel()
    remove_geolist_timer()
    if os.path.isfile(TUNNEL_UNIT_PATH):
        run(["systemctl", "disable", TUNNEL_SERVICE], timeout=60)
    flush_dns()


# --- распределение сайтов ----------------------------------------------------

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
    """Убирает из нашего блока hosts строки доменов, переносимых в туннель."""
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


def add_tunnel_domains(domains):
    merge_list_file(tunnel_list_path(), domains)
    write_tunnel_rules()
    remove_hosts_domains(domains)
    flush_dns()


def discord_media_tunneled():
    return os.path.isfile(tunnel_path("discord-media.on"))


def _discord_probe_one(ip, port):
    """
    Проверка медиасервера Discord так, как его видит трансляция: пакет
    определения IP (на него сервер отвечает без входа в аккаунт), затем ~3 с
    потока по 1000 байт, затем снова пакет определения IP.
    'ok' - ответ есть и в начале, и после потока; 'blocked' - ответ только в
    начале (соединение обрезается, как у трансляций); None - сервер не ответил.
    """
    disc = struct.pack(">HHI", 1, 70, int.from_bytes(os.urandom(4), "big")) + b"\0" * 66
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.5)

    def ask(tries):
        for _ in range(tries):
            try:
                s.sendto(disc, (ip, port))
                s.recvfrom(2048)
                return True
            except OSError:
                pass
        return False

    try:
        if not ask(2):
            return None
        for _ in range(300):
            s.sendto(os.urandom(1000), (ip, port))
            time.sleep(0.01)
        return "ok" if ask(3) else "blocked"
    except OSError:
        return None
    finally:
        s.close()


def discord_stream_probe():
    """
    Может ли zapret обеспечить трансляции Discord: 'ok', 'blocked' или None
    (проверить не удалось). Проверка идёт напрямую, мимо туннеля: если адреса
    Discord уже направлены в туннель, на время проверки для сервера проверки
    ставится правило «через основную таблицу» раньше правил sing-box.
    """
    results = []
    for ip, port in DISCORD_PROBE_SERVERS:
        rule = ["ip", "rule", "add", "to", f"{ip}/32", "lookup", "main",
                "priority", str(TUNNEL_RT_RULE - 1)]
        bypass = discord_media_tunneled() and tunnel_tun_exists()
        if bypass:
            run(rule)
        try:
            results.append(_discord_probe_one(ip, port))
        finally:
            if bypass:
                run(["ip", "rule", "del"] + rule[3:])
    if "blocked" in results:
        return "blocked"
    if "ok" in results:
        return "ok"
    return None


def check_discord_streams():
    """Итог проверки трансляций Discord; при необходимости - UDP Discord в туннель."""
    head("Проверка трансляций Discord через zapret...")
    if not nfqws2_running():
        warn("Трансляции Discord: не проверено — zapret не запущен")
        return
    r = discord_stream_probe()
    if r is None:
        warn("Трансляции Discord: проверить не удалось — серверы проверки не ответили")
        return
    if r == "ok":
        if discord_media_tunneled():
            ok("Трансляции Discord: zapret справляется. UDP к медиасерверам Discord "
               "по-прежнему идёт через туннель (вернуть напрямую: удалить "
               f"{tunnel_path('discord-media.on')} и перезапустить туннель)")
        else:
            ok("Трансляции Discord: работают через zapret")
        return
    if discord_media_tunneled():
        info("Трансляции Discord: zapret не справляется (сервер перестаёт отвечать через ~1 с); "
             "UDP к медиасерверам Discord уже идёт через туннель")
        return
    with open(tunnel_path("discord-media.on"), "w", encoding="utf-8") as f:
        f.write("auto\n")
    warn("Трансляции Discord: zapret не справляется (сервер перестаёт отвечать через ~1 с)")
    info("Направляю UDP к медиасерверам Discord (" + ", ".join(DISCORD_MEDIA_CIDR4)
         + ") в туннель; голос и сайты на этих адресах идут как раньше. Перезапуск туннеля...")
    start_tunnel()
    info("Начните трансляцию заново: уже идущая останется на прежнем пути.")


def update_tunnel_routes():
    """Туннель там, где не справляется zapret: сайты и трансляции Discord."""
    ensure_root(sys.argv)
    if not tunnel_running():
        raise RuntimeError("Туннель не запущен")
    _update_tunnel_sites()
    print()
    check_discord_streams()


def _update_tunnel_sites():
    """Перенос в туннель сайтов, которые не открываются через zapret."""
    if not nfqws2_running():
        warn("zapret не запущен — в туннель попадут и сайты, которые zapret открыл бы сам")
    in_tunnel = set(tunnel_domains())
    excl = set(list_entries(os.path.join(ipset_dir(), "zapret-hosts-user-exclude.txt")))
    cands = []
    for name in ("zapret-hosts-user.txt", "zapret-hosts-auto.txt"):
        for d in list_entries(os.path.join(ipset_dir(), name)):
            if d not in in_tunnel and d not in excl and d not in cands:
                cands.append(d)
    if not cands:
        info("Нечего проверять")
        return
    head(f"Проверка {len(cands)} сайтов через zapret...")
    direct = https_batch(cands)
    failed = [d for d in cands if not direct[d]]
    if failed:
        # Вторая попытка: случайный сбой не должен навсегда увести сайт в туннель
        # (домены из списка туннеля zapret больше не обрабатывает).
        again = https_batch(failed)
        failed = [d for d in failed if not again[d]]
    info(f"открываются через zapret: {len(cands) - len(failed)}, не открываются: {len(failed)}")
    if not failed:
        ok("Туннель не нужен ни одному сайту из списков")
        return
    head("Проверка неоткрывшихся через туннель...")
    via = https_batch(failed, proxy=f"http://127.0.0.1:{TUNNEL_MIXED_PORT}")
    move = [d for d in failed if via[d]]
    dead = [d for d in failed if not via[d]]
    if move:
        add_tunnel_domains(move)
        ok("Перенесено в туннель: " + ", ".join(move))
        time.sleep(1)   # sing-box перечитывает список
        check_tunnel_dns()
        info("Перезапустите браузер: он помнит старые адреса сайтов. Если в браузере включён "
             "«Безопасный DNS» (DNS через HTTPS), отключите его — иначе он обходит туннель.")
    if dead:
        info("Не открываются и через туннель (нет сайта на корне домена или сбой): "
             + ", ".join(dead))
    info(f"Список туннеля: {tunnel_list_path()} (можно править вручную)")


def tunnel_test(domains=None):
    """Проверка сайтов из списка туннеля так, как их видит браузер (через DNS и TUN)."""
    ensure_root(sys.argv)
    if not tunnel_running():
        raise RuntimeError("Туннель не запущен")
    # Внешний список большой - проверяем свой, а из внешнего берём несколько для примера.
    doms = domains or (list_entries(tunnel_list_path()) + geolist_entries()[:5])
    if not doms:
        info("Список туннеля пуст")
        return
    head("Проверка сайтов из списка туннеля (как в браузере)...")
    for d in doms:
        try:
            ips = sorted({i[4][0] for i in socket.getaddrinfo(d, 443, socket.AF_INET, socket.SOCK_STREAM)})
        except OSError:
            ips = []
        via = "в туннель" if any(ip.startswith(TUNNEL_FAKE4_PREFIX) for ip in ips) else "МИМО туннеля"
        res = _probe_tls(d, 4) if ips else "DNS: имя не разрешается"
        color = C.GREEN if res.startswith("OK") else C.RED
        print(f"    {d:<28} DNS {via:<13} {_c(color, res)}")
    print()
    info("«OK … 403 Forbidden» или страница «недоступно в вашем регионе» — отказ самого сайта, а не блокировка.")
    ex = read_json(tunnel_path("exit.json")) or {}
    if ex:
        info(f"Выход туннеля: страна {ex.get('loc')}, адрес {ex.get('ip')}")
    warn_browser_dns()


# --- меню ---------------------------------------------------------------------

PROTON_HELP = """
  Proton VPN Free — бесплатный тариф без ограничения трафика.
    1. Зарегистрируйтесь на https://account.protonvpn.com (нужна почта).
    2. Раздел «Downloads» -> «WireGuard configuration».
    3. Платформа: Router (или GNU/Linux). Protocol: WireGuard.
    4. Выберите бесплатный сервер (Free). Для Дальнего Востока ближе Япония (JP).
    5. Нажмите «Create» и скачайте файл .conf.
  Можно импортировать несколько файлов (разные страны) — скрипт выберет лучший.
  Если сайт Proton не открывается, зайдите на него с телефона (мобильный интернет).
"""

CUSTOM_HELP = f"""
  Свой сервер (VPS). Вставьте ссылку, путь к файлу или адрес подписки.
  Поддерживается: {SUPPORTED_FORMATS}.
"""


def tunnel_sites_summary():
    own = len(list_entries(tunnel_list_path()))
    ext = len(tunnel_domains()) - own
    return f"{own} своих + {ext} из внешнего списка" if ext > 0 else str(own)


def tunnel_status_line():
    st = read_json(tunnel_path("state.json")) or {}
    if tunnel_running():
        state = _c(C.GREEN, f"работает, профиль «{st.get('active')}»"
                   + (" (выбран вручную)" if st.get("pinned") else ""))
    elif tunnel_starter_pid():
        state = _c(C.YELLOW, "запускается...")
    else:
        state = _c(C.GRAY, "не запущен")
    ex = read_json(tunnel_path("exit.json")) or {}
    where = f" | выход: {ex.get('loc')}" if ex and tunnel_running() else ""
    print(f"  Туннель: {'включён' if tunnel_enabled() else 'выключен'} | {state} | "
          f"профилей: {len(load_profiles())} | сайтов: {tunnel_sites_summary()}{where}")


def show_profiles():
    profiles = load_profiles()
    if not profiles:
        info("Профилей нет")
        return profiles
    st = read_json(tunnel_path("state.json")) or {}
    active = st.get("active")
    tested = {r["name"]: r for r in st.get("ranked") or []}
    for i, p in enumerate(profiles, 1):
        host, port, _ = profile_server(p)
        mark = ""
        if p["name"] == active:
            mark = _c(C.GREEN, " <- активный" + (", выбран вручную" if st.get("pinned") else ""))
        src = "Proton" if p.get("source") == "proton" else "свой"
        r = tested.get(p["name"])
        res = ""
        if r:
            gs = geo_summary(r.get("geo") or {})
            res = _c(C.GRAY, f"  {r['ms']} мс, выход {r['loc']}" + (f", {gs}" if gs else ""))
        elif st.get("ranked") is not None:
            res = _c(C.GRAY, "  при проверке не ответил")
        print(f"    [{i}] {p['name']}  [{p['type']}, {src}]  {host}:{port}{res}{mark}")
    return profiles


def tunnel_menu():
    while True:
        print()
        tunnel_status_line()
        en = tunnel_enabled()
        if en and not tunnel_running() and not tunnel_starter_pid():
            le = file_tail(tunnel_path("last-error.txt"), 40)
            if le:
                print(_c(C.RED, "  Последняя ошибка:"))
                for ln in le:
                    print(_c(C.GRAY, f"    {ln}"))
        print(f"  [1] {'Выключить' if en else 'Включить'} туннель")
        print("  [2] Proton VPN Free: импортировать конфиг WireGuard")
        print("  [3] Свой сервер: импортировать конфиг, ссылку или подписку")
        print("  [4] Выбрать профиль вручную")
        print("  [5] Проверить профили и выбрать лучший автоматически")
        print("  [6] Проверить сайты и трансляции Discord; что не работает через zapret - в туннель")
        print("  [7] Добавить домен в туннель вручную")
        print("  [8] Проверить сайты из списка туннеля (как в браузере)")
        print("  [9] Профили: показать / удалить")
        print("  [10] Региональные ограничения: проверить сайты через активный профиль")
        print(f"  [11] Внешний список сайтов с региональными ограничениями: обновить сейчас ({geolist_status()})")
        print("  [12] Внешний список: " + ("выключить" if geolist_enabled() else "включить"))
        print("  [0] Назад")
        try:
            ch = input("\n  Выбор: ").strip()
        except EOFError:
            return
        if ch == "0":
            return
        try:
            tunnel_menu_action(ch, en)
        except ProfileError as e:
            err(str(e))
        except Exception as e:
            set_tunnel_error(f"Ошибка: {e}")


def tunnel_menu_action(ch, en):
    """Одно действие меню туннеля; исключения перехватывает tunnel_menu."""
    if ch == "1":
        disable_tunnel() if en else enable_tunnel()
    elif ch in ("2", "3"):
        print(PROTON_HELP if ch == "2" else CUSTOM_HELP)
        value = input("  Путь к файлу .conf: " if ch == "2"
                      else "  Ссылка, путь к файлу или адрес подписки: ").strip()
        if not value:
            return
        import_profiles(read_user_input(value), "proton" if ch == "2" else "custom")
        select_profile()
    elif ch == "4":
        if not show_profiles():
            return
        n = input("  Номер профиля (a — выбрать автоматически, Enter — отмена): ").strip()
        if n:
            use_profile("auto" if n.lower() in ("a", "а") else n)
    elif ch == "5":
        select_profile()
    elif ch == "6":
        update_tunnel_routes()
    elif ch == "11":
        geolist_action()
    elif ch == "12":
        toggle_geolist()
    elif ch == "10":
        tunnel_geo()
    elif ch == "7":
        d = input("  Домен (например, example.com): ").strip().lower()
        if re.fullmatch(r"[a-z0-9.-]+\.[a-z0-9-]+", d):
            add_tunnel_domains([d])
            ok(f"{d} добавлен в туннель")
            if tunnel_running():
                time.sleep(1)
                tunnel_test([d])
        else:
            err("Некорректный домен")
    elif ch == "8":
        tunnel_test()
    elif ch == "9":
        profiles = show_profiles()
        if not profiles:
            return
        n = input("  Номер профиля для удаления (Enter — ничего не удалять): ").strip()
        if n.isdigit() and 1 <= int(n) <= len(profiles):
            gone = profiles.pop(int(n) - 1)
            save_profiles(profiles)
            st = read_json(tunnel_path("state.json")) or {}
            if st.get("active") == gone["name"]:
                stop_tunnel(quiet=True)
                try:
                    os.remove(tunnel_path("state.json"))
                except OSError:
                    pass
            write_config()
            ok(f"Профиль «{gone['name']}» удалён")


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
                clear_screen()
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

        clear_screen()
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
        print("  [11] Туннель для сайтов, которые не открывает zapret (Proton VPN Free / свой сервер)")
        print("  [12] Быстрый подбор стратегий (обрыв зависших соединений): "
              + ("выключить" if circular_reset_enabled() else "включить"))
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
                tunnel_menu()
            elif choice == "12":
                toggle_circular_reset()
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
    "report": collect_report,
    "update": script_update,
    "uninstall": uninstall,
    "tunnel-on": None,
    "tunnel-off": None,
    "tunnel-import": None,
    "tunnel-select": None,
    "tunnel-use": None,
    "tunnel-geo": None,
    "tunnel-geolist": None,
    "tunnel-geolist-auto": None,
    "tunnel-routes": None,
    "tunnel-test": None,
    "tunnel-list": None,
    "tunnel-start": None,
}


def acquire_lock(shared=False):
    """
    Не даёт двум экземплярам одновременно писать hosts/config/profiles.json.
    Читающие действия (status, check) берут общий lock, меняющие -
    эксклюзивный. Возвращает открытый файл-лок (держать до конца работы).
    """
    import fcntl

    lock_path = "/var/lock/zapret2win.lock"
    try:
        os.makedirs("/var/lock", exist_ok=True)
        lock_file = open(lock_path, "a+")
    except OSError:
        return None  # без /var/lock работаем как раньше
    flags = fcntl.LOCK_SH if shared else fcntl.LOCK_EX
    try:
        fcntl.flock(lock_file.fileno(), flags | fcntl.LOCK_NB)
        return lock_file
    except OSError:
        lock_file.close()
        # Сообщение - в stderr: это ошибка, а не полезный вывод.
        print(_c(C.RED, "  Другой экземпляр zapret2-linux уже работает."),
              file=sys.stderr)
        print("  Дождитесь его завершения (или закройте второе окно) и повторите.",
              file=sys.stderr)
        sys.exit(3)


def main():
    if sys.platform != "linux":
        print(_c(C.RED, f"  Этот скрипт предназначен для Linux (текущая платформа: {sys.platform})."))
        print("  Для Windows используйте Zapret2Windows.ps1")
        return 2

    # «sh zapret2-linux.sh install» — первое слово без дефиса считается действием.
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        sys.argv[1:2] = ["--action", sys.argv[1]]

    parser = argparse.ArgumentParser(
        prog="zapret2-linux.sh",
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
  tunnel-on      включить туннель для сайтов, которые не открывает zapret
  tunnel-off     выключить туннель
  tunnel-import  добавить сервер: --config <файл> или --link <ссылка/подписка>;
                 с --proton — как конфиг Proton VPN Free
  tunnel-select  проверить профили и выбрать лучший (с учётом региональных ограничений сайтов)
  tunnel-use     выбрать профиль вручную: --profile <номер | имя | auto>
  tunnel-geo     проверить сайты с региональными ограничениями через активный профиль
  tunnel-geolist обновить внешний список сайтов с региональными ограничениями
  tunnel-routes  проверить сайты и перенести неоткрывающиеся в туннель
  tunnel-test    проверить сайты из списка туннеля так, как их видит браузер
  tunnel-list    показать профили
  tunnel-start   запустить туннель, если он включён (так обход запускает его следом)

Примеры:
  sh zapret2-linux.sh
  sh zapret2-linux.sh install
  sh zapret2-linux.sh check
""",
    )
    parser.add_argument(
        "--action", "-a", default="menu", choices=sorted(ACTIONS.keys()),
        help="действие (по умолчанию: menu)",
    )
    parser.add_argument("--config", help="tunnel-import: путь к файлу конфига (WireGuard .conf, JSON, список ссылок)")
    parser.add_argument("--link", help="tunnel-import: ссылка на сервер (vless://… и др.) или адрес подписки")
    parser.add_argument("--profile", help="tunnel-use: номер или имя профиля; auto - выбрать автоматически")
    parser.add_argument("--proton", action="store_true", help="tunnel-import: это конфиг Proton VPN Free")
    parser.add_argument("--yes", "-y", action="store_true",
                        help="не задавать вопросов подтверждения")
    parser.add_argument("--force", action="store_true",
                        help="update: подтвердить замену даже при откате версии")
    parser.add_argument("--version", "-V", action="version",
                        version=f"zapret2-linux {VERSION}")
    args = parser.parse_args()

    action = args.action

    # Читающие действия идут под общим локом, меняющие - под эксклюзивным.
    _lock = acquire_lock(shared=action in ("status", "check", "tunnel-list"))

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

    def do_import():
        src = args.config or args.link
        if not src:
            raise ProfileError("укажите --config <файл> или --link <ссылка>")
        import_profiles(read_user_input(src), "proton" if args.proton else "custom")
        select_profile()

    warp_actions = {
        "tunnel-on": lambda: enable_tunnel(assume_yes=args.yes),
        "tunnel-off": disable_tunnel,
        "tunnel-import": do_import,
        "tunnel-select": lambda: (ensure_root(sys.argv), select_profile()),
        "tunnel-use": lambda: use_profile(args.profile or "") if args.profile else (show_profiles(), info("укажите --profile <номер | имя | auto>")),
        "tunnel-geo": tunnel_geo,
        "tunnel-geolist": geolist_action,
        "tunnel-geolist-auto": lambda: geolist_action(force=False),
        "tunnel-routes": update_tunnel_routes,
        "tunnel-test": tunnel_test,
        "tunnel-list": show_profiles,
        "tunnel-start": lambda: (ensure_root(sys.argv), tunnel_start_action()),
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
        if action == "update":
            func(assume_yes=args.yes, force=args.force)
        elif action in ("uninstall", "deps"):
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
