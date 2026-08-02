#!/usr/bin/env bash
# night_tune.sh — цикл A: неинтерактивный перебор стратегий (locked.tsv),
# БЕЗ рестарта nfqws2 (locked.lua перечитывает файл раз в ~2 сек).
# Безопасно гонять часто/каждую ночь.
#
# Запуск: sudo ./night_tune.sh [--budget SEC] [--settle SEC] [--attempts N] [--profiles 1,2,3]

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/z2r_autobench/logs"
NIGHT_BUDGET_SECONDS="${NIGHT_BUDGET_SECONDS:-25200}"
SETTLE_SECONDS="${SETTLE_SECONDS:-3}"
ATTEMPTS_PER_STRATEGY="${ATTEMPTS_PER_STRATEGY:-2}"
CURL_TIMEOUT="${CURL_TIMEOUT:-3}"
PROFILES_FILTER=""   # пусто = все профили ниже

while [ $# -gt 0 ]; do
  case "$1" in
    --budget) NIGHT_BUDGET_SECONDS="$2"; shift 2 ;;
    --settle) SETTLE_SECONDS="$2"; shift 2 ;;
    --attempts) ATTEMPTS_PER_STRATEGY="$2"; shift 2 ;;
    --profiles) PROFILES_FILTER="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root (доступ к /opt/zapret2/config и locked.tsv)." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

if ! zapret2_running; then
  echo "zapret2 (nfqws2) не запущен — тесты будут бессмысленны без перехвата трафика." >&2
  echo "Запустите: systemctl start zapret2   (или через z2r, пункт 2)" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/night_tune_${RUN_TS}.tsv"
echo -e "ts\tprofile\ttitle\tproto\tstrategy\tattempt\ttls12_ok\ttls13_ok\tsuccess\tnote" > "$LOG_FILE"

autobench_backup_locks "$RUN_TS"

# профиль_id title proto_list url is_http
PROFILE_DEFS=(
  "1|YT_TLS/HTTP|tls http|https://www.youtube.com/|0"
  "2|Googlevideo_TLS|tls|$(get_gv_test_url)|0"
  "3|RKN_TLS|tls|https://meduza.io|0"
  "8|Fallback_TLS|tls|https://rutracker.org|0"
  "9|Fallback_HTTP|http|http://rutracker.org|1"
)

profile_selected() {
  local pid="$1"
  [ -z "$PROFILES_FILTER" ] && return 0
  case ",$PROFILES_FILTER," in
    *",$pid,"*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "=== night_tune.sh: старт $(date) ==="
echo "Лог: $LOG_FILE"

declare -a RESULT_LINES=()
for def in "${PROFILE_DEFS[@]}"; do
  IFS='|' read -r pid title proto url is_http <<< "$def"
  profile_selected "$pid" || continue
  tune_profile "$pid" "$title" "$proto" "$url" "$is_http" "$LOG_FILE"
  RESULT_LINES+=("RESULT profile=$pid title=$title success=$TUNE_RESULT_SUCCESS strategy=$TUNE_RESULT_STRATEGY bytes=$TUNE_RESULT_BYTES")
done

echo "=== night_tune.sh: финиш $(date) ==="
echo "Итоговые локи (locked.tsv):"
cat "$ORCH_DIR/locked.tsv" 2>/dev/null
echo "Итоговые локи (locked.manual.tsv, fallback):"
cat "$ORCH_DIR/locked.manual.tsv" 2>/dev/null
echo "Полный лог попыток: $LOG_FILE"
echo "--- machine-readable summary ---"
printf '%s\n' "${RESULT_LINES[@]}"
