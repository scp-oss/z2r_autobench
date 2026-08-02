#!/usr/bin/env bash
# rank_quic.sh — многопроходный рейтинг стратегий профиля 5 (YouTube QUIC,
# UDP 443). Аналог rank_strategies.sh, но через quic_probe.py (aioquic),
# т.к. curl не умеет HTTP/3.
#
# Запуск: sudo ./rank_quic.sh --passes 3 [--attempts N] [--settle SEC] [--range-bytes N] [--timeout SEC]

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/z2r_autobench/logs"
PASSES=3
SETTLE_SECONDS="${SETTLE_SECONDS:-3}"
ATTEMPTS_PER_STRATEGY="${ATTEMPTS_PER_STRATEGY:-2}"
RANGE_BYTES="${RANGE_BYTES:-524288}"
QUIC_TIMEOUT="${QUIC_TIMEOUT:-4}"
PROFILE="5"
PROTO="udp"

while [ $# -gt 0 ]; do
  case "$1" in
    --passes) PASSES="$2"; shift 2 ;;
    --attempts) ATTEMPTS_PER_STRATEGY="$2"; shift 2 ;;
    --settle) SETTLE_SECONDS="$2"; shift 2 ;;
    --range-bytes) RANGE_BYTES="$2"; shift 2 ;;
    --timeout) QUIC_TIMEOUT="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root." >&2
  exit 1
fi

if ! python3 -c "import aioquic" >/dev/null 2>&1; then
  echo "Не найден пакет aioquic. Установи: pip install aioquic --break-system-packages" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

if ! zapret2_running; then
  echo "zapret2 (nfqws2) не запущен." >&2
  exit 1
fi

# См. rank_strategies.sh — тот же общий лок, чтобы демон и ручной запуск
# не переключали профиль 5 одновременно вперемешку.
acquire_tune_lock "rank_quic.sh" 10 || exit 1

mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RAW_FILE="$LOG_DIR/rank_quic_${RUN_TS}.raw.tsv"
echo -e "pass\tstrategy\tattempt\tsuccess\tbytes" > "$RAW_FILE"
autobench_backup_locks "$RUN_TS"

echo "Резолвлю реальный googlevideo videoplayback URL через yt-dlp..."
GV_URL="$(resolve_googlevideo_url)"
if [ -z "$GV_URL" ]; then
  echo "Не удалось получить URL через yt-dlp." >&2
  exit 1
fi
GV_HOST="$(python3 -c "from urllib.parse import urlsplit; import sys; print(urlsplit(sys.argv[1]).hostname)" "$GV_URL")"
GV_PATH="$(python3 -c "
from urllib.parse import urlsplit
import sys
u = urlsplit(sys.argv[1])
p = u.path
if u.query:
    p += '?' + u.query
print(p)
" "$GV_URL")"
echo "Хост: $GV_HOST"

max_strat="$(config_profile_max_strategy "$PROFILE" "")"
if [ -z "$max_strat" ] || [ "$max_strat" -le 0 ]; then
  echo "Не удалось определить число стратегий для профиля $PROFILE." >&2
  exit 1
fi

prev_strategy="$(orch_locked_get "$PROFILE" "$PROTO")"

echo "=== rank_quic.sh: старт $(date) ==="
echo "Профиль=5 (YT_QUIC_UDP), стратегии=1..$max_strat, проходов=$PASSES, попыток на стратегию=$ATTEMPTS_PER_STRATEGY"
echo "Итого запросов: $((max_strat * PASSES * ATTEMPTS_PER_STRATEGY)) (каждый — полный QUIC handshake, дольше curl)"
echo ""

total_steps=$((max_strat * PASSES))
current_step=0

for ((pass=1; pass<=PASSES; pass++)); do
  echo "--- Проход $pass/$PASSES ---"
  for ((s=1; s<=max_strat; s++)); do
    orch_locked_set "$PROFILE" "$PROTO" "$s"
    sleep "$SETTLE_SECONDS"

    for ((attempt=1; attempt<=ATTEMPTS_PER_STRATEGY; attempt++)); do
      bytes_received="$(python3 "$SCRIPT_DIR/quic_probe.py" "$GV_HOST" "$GV_PATH" \
          --range-bytes "$RANGE_BYTES" --timeout "$QUIC_TIMEOUT" 2>>"$LOG_DIR/rank_quic_${RUN_TS}.stderr.log")"
      rc=$?
      success=0
      if [ "$rc" -eq 0 ] && [ "${bytes_received:-0}" -ge "$RANGE_BYTES" ] 2>/dev/null; then
        success=1
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$pass" "$s" "$attempt" "$success" "${bytes_received:-0}" >> "$RAW_FILE"
    done
    current_step=$((current_step + 1))
    print_progress "$current_step" "$total_steps" "проход=$pass strategy=$s (QUIC, медленно)"
  done
  print_progress_done
  echo "  проход $pass завершён"
done

echo ""
echo "Возврат к исходной стратегии:"
if [ -n "$prev_strategy" ] && [ "$prev_strategy" != "0" ]; then
  orch_locked_set "$PROFILE" "$PROTO" "$prev_strategy"
  echo "  -> strategy=$prev_strategy"
else
  orch_locked_clear "$PROFILE" "$PROTO"
  echo "  -> auto (был не задан)"
fi

echo ""
echo "=== Агрегация по $PASSES проходам ==="
echo ""

awk -F'\t' '
  BEGIN { nstrat = 0 }
  NR==1 { next }
  {
    strat = $2; succ = $4; bytes = $5
    total[strat]++
    if (succ == 1) {
      successes[strat]++
      sumbytes[strat] += bytes
      cntbytes[strat]++
    }
  }
  END {
    printf "%-10s %-12s %-15s %-10s\n", "Стратегия", "Успех", "Ср.байт", "Надёжность"
    n = 0
    max_s = 0
    for (s in total) { if (s+0 > max_s) max_s = s+0 }
    for (si = 1; si <= max_s; si++) {
      s = si
      if ((s in total) && (s in successes) && successes[s] > 0) {
        rate = successes[s] / total[s]
        avgb = sumbytes[s] / cntbytes[s]
        order[n] = s SUBSEP rate SUBSEP avgb
        n++
      }
    }
    for (i = 0; i < n; i++) {
      for (j = i+1; j < n; j++) {
        split(order[i], a, SUBSEP); split(order[j], b, SUBSEP)
        if (b[2]+0 > a[2]+0 || (b[2]+0 == a[2]+0 && b[3]+0 > a[3]+0)) {
          tmp = order[i]; order[i] = order[j]; order[j] = tmp
        }
      }
    }
    for (i = 0; i < n; i++) {
      split(order[i], a, SUBSEP)
      s = a[1]; rate = a[2]; avgb = a[3]
      printf "%-10s %-12s %-15.0f %-10s\n", s, successes[s]"/"total[s], avgb, sprintf("%.0f%%", rate*100)
    }
    print ""
    print "Провалились во всех попытках всех проходов:"
    found_fail = 0
    for (si = 1; si <= max_s; si++) {
      s = si
      if ((s in total) && !((s in successes) && successes[s] > 0)) {
        printf "  strategy=%s (total=%s, success=0)\n", s, total[s]
        found_fail = 1
      }
    }
    if (!found_fail) print "  (нет)"
    print ""
    ordered = ""
    for (i = 0; i < n; i++) {
      split(order[i], a, SUBSEP)
      ordered = ordered a[1] " "
    }
    printf "ORDERED_SUCCESS: %s\n", ordered
  }
' "$RAW_FILE"

LAST_ORDERED_FILE="$LOG_DIR/last_ordered_profile_5.txt"
awk -F'\t' '
  BEGIN { nstrat = 0 }
  NR==1 { next }
  {
    strat = $2; succ = $4; bytes = $5
    if (!(strat in total)) { stratlist[nstrat] = strat; nstrat++ }
    total[strat]++
    if (succ == 1) { successes[strat]++; sumbytes[strat] += bytes; cntbytes[strat]++ }
  }
  END {
    n = 0
    for (k = 0; k < nstrat; k++) {
      s = stratlist[k]
      if ((s in successes) && successes[s] > 0) {
        rate = successes[s] / total[s]
        avgb = sumbytes[s] / cntbytes[s]
        order[n] = s SUBSEP rate SUBSEP avgb
        n++
      }
    }
    for (i = 0; i < n; i++) {
      for (j = i+1; j < n; j++) {
        split(order[i], a, SUBSEP); split(order[j], b, SUBSEP)
        if (b[2]+0 > a[2]+0 || (b[2]+0 == a[2]+0 && b[3]+0 > a[3]+0)) {
          tmp = order[i]; order[i] = order[j]; order[j] = tmp
        }
      }
    }
    ordered = ""
    for (i = 0; i < n; i++) { split(order[i], a, SUBSEP); ordered = ordered a[1] " " }
    print ordered
  }
' "$RAW_FILE" > "$LAST_ORDERED_FILE"
echo "Итоговый результат сохранён: $LAST_ORDERED_FILE"

echo ""
echo "Сырые данные: $RAW_FILE"
