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

# profile/proto раньше проходили в set_strategy()/get_strategy() (в итоге
# в locked.tsv, ту же TSV, что читает нативный zapret-lib) БЕЗ ЕДИНОЙ
# проверки -- только strategy была заякорена на цифры. Вызывающий (напр.
# z0r-panel через sudoers `set_strategy_cli.sh set *`) мог передать
# что угодно, включая таб/перевод строки, ломающие структуру TSV-файла.
# Найдено при аудите перед деплоем на МТС 2026-08-17. profile -- всегда
# небольшое целое (circular_locked:key=N, N сейчас 1-9, но новые профили
# добавляются со временем, поэтому просто "цифры", не жёсткий список).
# proto -- всегда короткое слово из строчных латинских букв (tls/udp/http
# и т.п., опять же без жёсткого списка на будущее).
_validate_profile_proto() {
  local profile="$1" proto="$2"
  if ! printf '%s' "$profile" | grep -Eq '^[0-9]{1,4}$'; then
    echo "profile должен быть небольшим целым числом, получено: '$profile'" >&2
    exit 1
  fi
  if ! printf '%s' "$proto" | grep -Eq '^[a-z]{1,16}$'; then
    echo "proto должен состоять из строчных латинских букв, получено: '$proto'" >&2
    exit 1
  fi
}

case "$action" in
  max)
    [ $# -eq 1 ] || usage
    profile="$1"
    if ! printf '%s' "$profile" | grep -Eq '^[0-9]{1,4}$'; then
      echo "profile должен быть небольшим целым числом, получено: '$profile'" >&2
      exit 1
    fi
    config_profile_max_strategy "$profile" ""
    exit 0
    ;;
  set)
    [ $# -eq 3 ] || usage
    profile="$1"; proto="$2"; strategy="$3"
    _validate_profile_proto "$profile" "$proto"
    if ! printf '%s' "$strategy" | grep -Eq '^[0-9]+$'; then
      echo "Стратегия должна быть числом, получено: '$strategy'" >&2
      exit 1
    fi
    if set_strategy "$profile" "$proto" "$strategy"; then
      # set_strategy() пишет только locked.tsv (реальное поведение nfqws2).
      # profile.lock (шапка меню z2r) синхронизируем отдельно, как это уже
      # делает retune_profile() в autotune_daemon.sh — иначе locked.tsv и
      # меню расходятся, ровно та путаница, что уже была в этой сессии.
      if type profile_state_set >/dev/null 2>&1; then
        profile_state_set "$profile" "$proto" "$strategy" 2>/dev/null || true
      fi
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
    _validate_profile_proto "$profile" "$proto"
    get_strategy "$profile" "$proto"
    exit 0
    ;;
  *)
    usage
    ;;
esac
