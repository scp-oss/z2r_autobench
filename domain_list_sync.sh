#!/usr/bin/env bash
# domain_list_sync.sh — печатает содержимое официального курированного
# списка доменов ($Z2R_BASE/lists/<файл>.txt) для конкретного профиля,
# один домен на строку (комментарии/пустые строки отфильтрованы). Только
# ЧТЕНИЕ, ничего не пишет и не изменяет — источник правды остаётся файл
# на диске, панель (см. z0r-panel /domains "Синхронизировать") сама
# решает, что делать с полученным списком (get_or_create_domain, тот же
# путь, что и ручное добавление).
#
# Список файлов курируется вручную здесь — НЕ угадывается по шаблону
# имени (напр. "russia-<профиль>.txt"), так как реального соответствия
# файл-на-профиль для всех профилей нет (проверено на живом сервере
# 2026-08-31: /opt/zator/lists/ содержит russia-youtube.txt,
# russia-discord.txt для YT_TLS/DS_TLS, но нет аналогов для
# RKN_TLS/GV_TLS/Fallback-профилей — если появятся, добавляй сюда явно).
#
# YT_QUIC_UDP -> russia-youtubeQ.txt добавлен по прямому запросу
# 2026-08-31 — тот же домен-пул, что и остальные, ИМЕННО ЭТИМ файлом
# (не russia-youtube.txt), т.к. это отдельный курированный список под
# UDP/QUIC-вариант YouTube, см. CLAUDE.md "Test domains". Не путать с
# тем, что реальный тестовый эдж для профиля 5 в rank_quic.sh/Zenith
# резолвится динамически через yt-dlp на каждый раунд — эти domain_pool
# записи для YT_QUIC_UDP остаются placeholder'ами (см. z0r-panel
# CLAUDE.md "DOMAIN_LIST_PROFILES narrowed"), синхронизация тут просто
# даёт готовый список вместо пустого одного placeholder-домена.
#
# Использование:
#   domain_list_sync.sh <профиль>       # печатает домены в stdout
#   domain_list_sync.sh --list-profiles # какие профили вообще поддержаны
#
# Код возврата: 0 при успехе, 1 если для профиля нет известного файла
# или файл не найден на диске.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Та же инлайновая копия _z2r_detect_base(), что rkn_list_cli.sh/z0r уже
# используют для этой же причины (см. CLAUDE.md "/opt/zapret2 vs
# /opt/zator") — этому скрипту не нужен весь z2r_autobench_lib.sh
# (требует живой z2r_lib), только сам путь $Z2R_BASE.
_z2r_detect_base() {
  if [ -d "/opt/zapret2/z2r_lib" ]; then
    echo "/opt/zapret2"
  elif [ -d "/opt/zator/z2r_lib" ]; then
    echo "/opt/zator"
  else
    echo "/opt/zapret2"
  fi
}
Z2R_BASE="${Z2R_BASE:-$(_z2r_detect_base)}"

declare -A PROFILE_LIST_FILES=(
  [YT_TLS]="russia-youtube.txt"
  [DS_TLS]="russia-discord.txt"
  [YT_QUIC_UDP]="russia-youtubeQ.txt"
)

usage() {
  echo "Использование: $0 <профиль>" >&2
  echo "            или $0 --list-profiles" >&2
  exit 1
}

[ $# -ge 1 ] || usage

if [ "$1" = "--list-profiles" ]; then
  for p in "${!PROFILE_LIST_FILES[@]}"; do
    echo "$p"
  done
  exit 0
fi

profile="$1"
file="${PROFILE_LIST_FILES[$profile]:-}"
if [ -z "$file" ]; then
  echo "Нет известного курированного списка для профиля '$profile' (поддержаны: ${!PROFILE_LIST_FILES[*]})." >&2
  exit 1
fi

path="$Z2R_BASE/lists/$file"
if [ ! -f "$path" ]; then
  echo "Файл не найден: $path" >&2
  exit 1
fi

grep -vE '^\s*(#|$)' "$path"
