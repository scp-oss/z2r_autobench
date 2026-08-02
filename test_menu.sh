#!/usr/bin/env bash
# test_menu.sh — единая точка входа для тестирования всех профилей z2r.
#
# ВАЖНО: подскрипты (rank_strategies.sh/rank_quic.sh) вызываются НАПРЯМУЮ,
# без $(...)-захвата — иначе весь live-вывод (прогресс-бар, "проход N/M")
# уходит в чёрную дыру до самого завершения команды (так и было раньше,
# из-за этого казалось что тест завис). Результат для сводки читаем не
# из stdout, а из файла last_ordered_profile_<N>.txt, который каждый
# подскрипт пишет сам по итогу работы — это разделяет "что показать live"
# и "что вернуть как результат", не заставляя их конфликтовать.
#
# Запуск:
#   sudo ./test_menu.sh                  — интерактивное меню
#   sudo ./test_menu.sh --profile 1      — тест одного профиля, без меню
#   sudo ./test_menu.sh --all            — все тестируемые профили подряд
#   sudo ./test_menu.sh --all --passes 5 — тот же с другим числом проходов
#   sudo ./test_menu.sh --domain example.com [--passes 3] [--apply]
#                                         — тест конкретного домена (см. ниже)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/z2r_autobench/logs"
PASSES="${PASSES:-3}"
MODE=""
SINGLE_PROFILE=""
CUSTOM_DOMAIN=""
APPLY_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) SINGLE_PROFILE="$2"; MODE="single"; shift 2 ;;
    --all) MODE="all"; shift ;;
    --domain) CUSTOM_DOMAIN="$2"; MODE="domain"; shift 2 ;;
    --passes) PASSES="$2"; shift 2 ;;
    --apply) APPLY_FLAG="--apply"; shift ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root." >&2
  exit 1
fi

declare -A TITLES=(
  [1]="YT_TLS"
  [2]="GV_TLS"
  [3]="RKN_TLS"
  [4]="DS_TLS"
  [5]="YT_QUIC_UDP"
  [6]="VOICE_UDP"
  [7]="GAMES_UDP"
  [8]="FB_TLS"
  [9]="FB_HTTP"
)

read_last_ordered() {
  # $1 = profile id, печатает содержимое last_ordered_profile_<N>.txt или пусто
  local f="$LOG_DIR/last_ordered_profile_$1.txt"
  [ -f "$f" ] && cat "$f" || echo ""
}

test_profile() {
  local pid="$1"
  local title="${TITLES[$pid]}"

  case "$pid" in
    1|2|3|4|8|9)
      echo "--- Тестирую $title (профиль $pid), $PASSES проход(ов) ---"
      bash "$SCRIPT_DIR/rank_strategies.sh" --profile "$pid" --passes "$PASSES"
      local ordered
      ordered="$(read_last_ordered "$pid")"
      echo ""
      echo ">>> $pid $title: ${ordered:-нет успешных}"
      ;;
    5)
      echo "--- Тестирую $title (профиль 5, QUIC), $PASSES проход(ов) ---"
      bash "$SCRIPT_DIR/rank_quic.sh" --passes "$PASSES"
      local ordered
      ordered="$(read_last_ordered "5")"
      echo ""
      echo ">>> $pid $title: ${ordered:-нет успешных}"
      ;;
    6)
      echo "--- $title (профиль 6): читаю уже накопленные данные бота ---"
      if [ -f "$LOG_DIR/voice_bot_raw.tsv" ]; then
        bash "$SCRIPT_DIR/parse_voice_rank.sh"
        local ordered
        ordered="$(read_last_ordered "6")"
        echo ""
        if [ -n "$ordered" ]; then
          echo ">>> $pid $title: $ordered"
        else
          echo ">>> $pid $title: данные есть, но нет успешных стратегий (или файл пуст)"
        fi
      else
        echo ">>> $pid $title: нет данных — запусти /voice_rank в Discord-боте хотя бы раз"
      fi
      ;;
    7)
      echo ">>> $pid $title: тестер не реализован (сделаем позже)"
      ;;
    *)
      echo ">>> $pid $title: неизвестный профиль" >&2
      ;;
  esac
}

show_menu() {
  echo "=== z2r test_menu ===" >&2
  echo "Профили:" >&2
  for pid in 1 2 3 4 5 6 7 8 9; do
    echo "  $pid) ${TITLES[$pid]}" >&2
  done
  echo "  0) Все тестируемые профили (1,2,3,4,5,8,9 полным тестом; 6 — из кэша; 7 — заглушка)" >&2
  echo "  d) Тест конкретного домена (найти рабочие стратегии для своего сайта)" >&2
  echo "  q) Выход" >&2
  echo "" >&2
  read -re -p "Выбор: " choice
  echo "$choice"
}

run_all() {
  echo "=== Полный прогон всех тестируемых профилей ($PASSES проход(ов) на TLS/QUIC) ==="
  echo ""
  for pid in 1 2 3 4 5 6 7 8 9; do
    test_profile "$pid"
    echo ""
  done
  echo "=== ИТОГ ==="
  for pid in 1 2 3 4 5 6 7 8 9; do
    local title="${TITLES[$pid]}"
    if [ "$pid" = "7" ]; then
      echo "$pid $title: тестер не реализован (сделаем позже)"
      continue
    fi
    local ordered
    ordered="$(read_last_ordered "$pid")"
    echo "$pid $title: ${ordered:-нет данных}"
  done
}

run_domain_test() {
  local domain="$1"
  echo "--- Тест домена $domain (через профиль 3/RKN-механику, как z2r делает для custom-доменов) ---"
  bash "$SCRIPT_DIR/test_custom_domain.sh" --domain "$domain" --passes "$PASSES" $APPLY_FLAG
}

if [ "$MODE" = "all" ]; then
  run_all
  exit 0
fi

if [ "$MODE" = "domain" ]; then
  run_domain_test "$CUSTOM_DOMAIN"
  exit 0
fi

if [ "$MODE" = "single" ]; then
  if [ -z "${TITLES[$SINGLE_PROFILE]:-}" ]; then
    echo "Неизвестный профиль: $SINGLE_PROFILE (доступны: 1-9)" >&2
    exit 1
  fi
  test_profile "$SINGLE_PROFILE"
  exit 0
fi

# интерактивное меню
while true; do
  choice="$(show_menu)"
  case "$choice" in
    q|Q|"") echo "Выход."; exit 0 ;;
    0) run_all ;;
    1|2|3|4|5|6|7|8|9) test_profile "$choice" ;;
    d|D)
      read -re -p "Домен (например example.com, без https://): " dom
      [ -n "$dom" ] && run_domain_test "$dom"
      ;;
    *) echo "Некорректный выбор." ;;
  esac
  echo ""
done
