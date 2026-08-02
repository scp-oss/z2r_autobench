#!/usr/bin/env bash
# set_strategy_cli.sh — тонкий мост между zapret-voice-bot (Python/Discord)
# и общей библиотекой z2r_autobench_lib.sh. Не содержит собственной логики,
# только парсит аргументы и вызывает set_strategy()/get_strategy() из lib.
#
# Использование:
#   set_strategy_cli.sh set <profile> <proto> <strategy>
#   set_strategy_cli.sh get <profile> <proto>
#
# Примеры:
#   set_strategy_cli.sh set 6 udp 5      # VOICE_UDP -> стратегия 5
#   set_strategy_cli.sh set 4 tls 12     # DS_TLS -> стратегия 12
#   set_strategy_cli.sh get 6 udp
#
# Код возврата: 0 при успехе, 1 при ошибке аргументов/выполнения.
# Вывод: для 'get' печатает текущую стратегию в stdout, для 'set' — ничего
# в stdout при успехе (только код возврата), диагностика — в stderr.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

usage() {
  echo "Использование: $0 set <profile> <proto> <strategy>" >&2
  echo "            или $0 get <profile> <proto>" >&2
  echo "            или $0 max <profile>" >&2
  exit 1
}

[ $# -ge 1 ] || usage
action="$1"; shift

case "$action" in
  max)
    [ $# -eq 1 ] || usage
    profile="$1"
    config_profile_max_strategy "$profile" ""
    exit 0
    ;;
  set)
    [ $# -eq 3 ] || usage
    profile="$1"; proto="$2"; strategy="$3"
    if ! printf '%s' "$strategy" | grep -Eq '^[0-9]+$'; then
      echo "Стратегия должна быть числом, получено: '$strategy'" >&2
      exit 1
    fi
    if set_strategy "$profile" "$proto" "$strategy"; then
      echo "OK: profile=$profile proto=$proto strategy=$strategy" >&2
      exit 0
    else
      echo "Ошибка set_strategy для profile=$profile proto=$proto strategy=$strategy" >&2
      exit 1
    fi
    ;;
  get)
    [ $# -eq 2 ] || usage
    profile="$1"; proto="$2"
    get_strategy "$profile" "$proto"
    exit 0
    ;;
  *)
    usage
    ;;
esac
