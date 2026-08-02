#!/usr/bin/env bash
# exhaustive_tune.sh — полный перебор всех стратегий профиля (без остановки
# на первой успешной), чтобы ответить на вопрос "это лучшая или просто
# рабочая стратегия". Дороже по времени, чем night_tune.sh: 30 стратегий ×
# 2 попытки × (settle+timeout) секунд ≈ несколько минут на профиль.
#
# Запуск: sudo ./exhaustive_tune.sh --profile 1 [--budget SEC] [--attempts N]

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/z2r_autobench/logs"
NIGHT_BUDGET_SECONDS="${NIGHT_BUDGET_SECONDS:-1800}"
SETTLE_SECONDS="${SETTLE_SECONDS:-3}"
ATTEMPTS_PER_STRATEGY="${ATTEMPTS_PER_STRATEGY:-2}"
PROFILE="1"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --budget) NIGHT_BUDGET_SECONDS="$2"; shift 2 ;;
    --settle) SETTLE_SECONDS="$2"; shift 2 ;;
    --attempts) ATTEMPTS_PER_STRATEGY="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

if ! zapret2_running; then
  echo "zapret2 (nfqws2) не запущен." >&2
  exit 1
fi

acquire_tune_lock "exhaustive_tune.sh" 10 || exit 1

mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/exhaustive_${RUN_TS}.tsv"
echo -e "ts\tprofile\ttitle\tproto\tstrategy\tattempt\ttls12_ok\ttls13_ok\tsuccess\tnote" > "$LOG_FILE"
autobench_backup_locks "$RUN_TS"

case "$PROFILE" in
  1) TITLE="YT_TLS/HTTP"; PROTO="tls http"; URL="https://www.youtube.com/"; IS_HTTP=0 ;;
  2) TITLE="Googlevideo_TLS"; PROTO="tls"; URL="$(get_gv_test_url)"; IS_HTTP=0 ;;
  3) TITLE="RKN_TLS"; PROTO="tls"; URL="https://meduza.io"; IS_HTTP=0 ;;
  4) TITLE="Discord_TLS"; PROTO="tls"; URL="https://discord.com/"; IS_HTTP=0 ;;
  8) TITLE="Fallback_TLS"; PROTO="tls"; URL="https://rutracker.org"; IS_HTTP=0 ;;
  9) TITLE="Fallback_HTTP"; PROTO="http"; URL="http://rutracker.org"; IS_HTTP=1 ;;
  *) echo "Неизвестный/неподдерживаемый профиль: $PROFILE (доступны: 1,2,3,4,8,9)" >&2; exit 1 ;;
esac

echo "=== exhaustive_tune.sh: старт $(date) ==="
echo "Профиль=$PROFILE ($TITLE), бюджет=${NIGHT_BUDGET_SECONDS}s"
echo ""

tune_profile_exhaustive "$PROFILE" "$TITLE" "$PROTO" "$URL" "$IS_HTTP" "$LOG_FILE"

echo ""
echo "=== Итог ==="
echo "locked.tsv:"
cat "$ORCH_DIR/locked.tsv" 2>/dev/null
echo "Полный лог: $LOG_FILE"
