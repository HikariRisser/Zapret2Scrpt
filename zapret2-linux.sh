#!/bin/sh
# ============================================================================
#  Zapret2 Linux — лаунчер для zapret2-linux.py
#
#  ./zapret2-linux.sh                  меню
#  ./zapret2-linux.sh install          то же, что --action install
#  ./zapret2-linux.sh warp-on          любое действие из --help
#  ./zapret2-linux.sh --action check   аргументы передаются как есть
#
#  Что делает:
#    * находит Python 3.8+ (если его нет — предлагает установить);
#    * сам запрашивает права root (sudo, pkexec, doas или su);
#    * при запуске двойным щелчком открывает окно терминала;
#    * при ошибке не закрывает окно, пока не нажата Enter.
# ============================================================================

# --- каталог лаунчера (с учётом символических ссылок) ---
SELF="$0"
if command -v readlink >/dev/null 2>&1 && readlink -f "$SELF" >/dev/null 2>&1; then
    SELF="$(readlink -f "$SELF")"
fi
DIR="$(cd "$(dirname "$SELF")" && pwd)"
PY_SCRIPT="$DIR/zapret2-linux.py"

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
            gnome-terminal) exec "$term" -- "$SELF" "$@" ;;
            *)              exec "$term" -e "$SELF" "$@" ;;
        esac
    done
    # Терминал не найден — продолжаем как есть.
fi

[ "$(uname -s)" = "Linux" ] || die "Этот лаунчер для Linux (система: $(uname -s))." \
    "Для Windows используйте Zapret2Windows.cmd"

[ -f "$PY_SCRIPT" ] || die "Не найден zapret2-linux.py рядом с лаунчером." \
    "Ожидался: $PY_SCRIPT"

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
    yel "  Не найден Python 3.8 или новее — он нужен для zapret2-linux.py."
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
