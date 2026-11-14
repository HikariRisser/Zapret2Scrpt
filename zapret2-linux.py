#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Переходный файл — скачивать и запускать его НЕ нужно.

С версии 1.7.0 Linux-скрипт — один файл zapret2-linux.sh. Этот файл остаётся
в репозитории только для тех, у кого установлена версия 1.6.1 или старше: их
пункт «Обновить скрипт» скачивает именно zapret2-linux.py. При запуске файл
скачивает новый zapret2-linux.sh рядом с собой, запускает его и удаляет себя.
"""
import os
import shutil
import sys
import urllib.request

VERSION = "1.7.0"
URL = "https://raw.githubusercontent.com/HikariRisser/Zapret2Scrpt/main/zapret2-linux.sh"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    target = os.path.join(here, "zapret2-linux.sh")
    print("  zapret2: скрипт теперь состоит из одного файла zapret2-linux.sh — скачиваю его...")
    try:
        with urllib.request.urlopen(URL, timeout=60) as r:
            data = r.read()
    except Exception as e:
        print(f"  Не удалось скачать {URL}: {e}")
        print("  Скачайте zapret2-linux.sh вручную и запускайте его: sh zapret2-linux.sh")
        return 1
    if b"def main(" not in data or not data.startswith(b"#!/bin/sh"):
        print(f"  По адресу {URL} вернулся не скрипт. Скачайте zapret2-linux.sh вручную.")
        return 1
    if os.path.isfile(target):
        shutil.copy2(target, target + ".old.bak")      # прежний лаунчер
    with open(target, "wb") as f:
        f.write(data)
    os.chmod(target, 0o755)
    try:
        os.remove(os.path.abspath(__file__))           # этот файл больше не нужен
    except OSError:
        pass
    print(f"  Готово: {target}. Файл zapret2-linux.py больше не нужен.")
    os.execv("/bin/sh", ["/bin/sh", target] + sys.argv[1:])


if __name__ == "__main__":
    sys.exit(main())
