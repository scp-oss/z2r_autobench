#!/usr/bin/env bash
# rank_quic.sh — многопроходный рейтинг стратегий профиля 5 (YouTube QUIC,
# UDP 443). Аналог rank_strategies.sh, но через quic_probe.py (aioquic),
# т.к. curl не умеет HTTP/3.
#
# --funnel: см. rank_strategies.sh — каждый следующий проход гоняет только
# кандидатов, переживших предыдущий, вместо честного повтора всех стратегий.
# Старый режим (без --funnel) не тронут.
#
# ВАЖНО про эджи: googlevideo раздаёт разные CDN-узлы на разные запросы, и
# ISP обычно блокирует не домен целиком, а конкретные узлы/подсети. Поэтому
# по умолчанию эдж переразрезолвливается через yt-dlp на каждый проход —
# иначе можно случайно попасть на узел, который вообще не блокируется, и
# получить ложные "100% у всех стратегий" (не отличает рабочие от нерабочих,
# потому что различать нечего). --host/--path фиксируют конкретный эдж
# вручную (например, снятый с реального трафика проблемного устройства —
# TV-приложение YouTube почти всегда требует QUIC без TLS-фолбэка, поэтому
# ломается там, где браузер на десктопе просто откатится на TLS).
#
# Запуск: sudo ./rank_quic.sh --passes 3 [--attempts N] [--settle SEC] [--range-bytes N] [--timeout SEC] [--funnel] [--host HOST [--path PATH]]

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
FUNNEL=0
GV_HOST_OVERRIDE=""
GV_PATH_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --passes) PASSES="$2"; shift 2 ;;
    --attempts) ATTEMPTS_PER_STRATEGY="$2"; shift 2 ;;
    --settle) SETTLE_SECONDS="$2"; shift 2 ;;
    --range-bytes) RANGE_BYTES="$2"; shift 2 ;;
    --timeout) QUIC_TIMEOUT="$2"; shift 2 ;;
    --funnel) FUNNEL=1; shift ;;
    --host) GV_HOST_OVERRIDE="$2"; shift 2 ;;
    --path) GV_PATH_OVERRIDE="$2"; shift 2 ;;
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

# ISP блокирует не домен целиком, а конкретные эджи/подсети, поэтому для
# реального разнообразия эджей меняем сам ролик между проходами, а не
# просто дёргаем yt-dlp заново на тот же video_id — см. GV_TEST_VIDEO_IDS/
# gv_pick_video_id() в z2r_autobench_lib.sh (общие с rank_strategies.sh
# --profile 2, раньше список был продублирован только тут).

# Резолвит GV_HOST/GV_PATH заново (новый эдж от yt-dlp, для видео $1) — или,
# если задан --host, просто фиксирует ручные значения (переразрезолв не нужен).
resolve_edge() {
  local video_id="${1:-}"
  if [ -n "$GV_HOST_OVERRIDE" ]; then
    GV_HOST="$GV_HOST_OVERRIDE"
    GV_PATH="${GV_PATH_OVERRIDE:-/}"
    return 0
  fi
  local url
  url="$(resolve_googlevideo_url "$video_id")"
  if [ -z "$url" ]; then
    return 1
  fi
  GV_HOST="$(python3 -c "from urllib.parse import urlsplit; import sys; print(urlsplit(sys.argv[1]).hostname)" "$url")"
  GV_PATH="$(python3 -c "
from urllib.parse import urlsplit
import sys
u = urlsplit(sys.argv[1])
p = u.path
if u.query:
    p += '?' + u.query
print(p)
" "$url")"
}

if [ -n "$GV_HOST_OVERRIDE" ]; then
  resolve_edge
  echo "Эдж задан вручную: $GV_HOST"
else
  echo "Резолвлю реальный googlevideo videoplayback URL через yt-dlp (видео $(gv_pick_video_id 1))..."
  if ! resolve_edge "$(gv_pick_video_id 1)"; then
    echo "Не удалось получить URL через yt-dlp." >&2
    exit 1
  fi
  echo "Хост: $GV_HOST"
fi

max_strat="$(config_profile_max_strategy "$PROFILE" "")"
if [ -z "$max_strat" ] || [ "$max_strat" -le 0 ]; then
  echo "Не удалось определить число стратегий для профиля $PROFILE." >&2
  exit 1
fi

prev_strategy="$(orch_locked_get "$PROFILE" "$PROTO")"

# См. тот же трап в rank_strategies.sh -- защита от того, что прерывание
# снаружи (напр. systemctl restart автотюн-демона поверх работающего
# перебора) оставит locked.tsv застрявшим на случайном кандидате из
# середины прогона вместо отката к рабочей стратегии.
REVERTED_TO_ENTRY=0
revert_to_entry_strategy() {
  [ "$REVERTED_TO_ENTRY" = "1" ] && return 0
  REVERTED_TO_ENTRY=1
  if [ -n "$prev_strategy" ] && [ "$prev_strategy" != "0" ]; then
    orch_locked_set "$PROFILE" "$PROTO" "$prev_strategy"
    echo "  -> strategy=$prev_strategy"
  else
    orch_locked_clear "$PROFILE" "$PROTO"
    echo "  -> auto (был не задан)"
  fi
}
handle_interrupt_signal() {
  echo "" >&2
  echo "!!! rank_quic.sh прерван сигналом снаружи (напр. systemctl restart поверх работающего демона) -- откатываю locked.tsv к исходной стратегии перед выходом:" >&2
  revert_to_entry_strategy
  exit 143
}
trap handle_interrupt_signal TERM INT
trap revert_to_entry_strategy EXIT

echo "=== rank_quic.sh: старт $(date) ==="
if [ "$FUNNEL" = "1" ]; then
  echo "Профиль=5 (YT_QUIC_UDP), стратегии=1..$max_strat, режим=funnel (до $PASSES проходов, отсеивание нерабочих), попыток на стратегию=$ATTEMPTS_PER_STRATEGY"
  echo "Максимум запросов (если ничего не отсеется): $((max_strat * PASSES * ATTEMPTS_PER_STRATEGY)) (каждый — полный QUIC handshake) — реально будет меньше"
else
  echo "Профиль=5 (YT_QUIC_UDP), стратегии=1..$max_strat, проходов=$PASSES, попыток на стратегию=$ATTEMPTS_PER_STRATEGY"
  echo "Итого запросов: $((max_strat * PASSES * ATTEMPTS_PER_STRATEGY)) (каждый — полный QUIC handshake, дольше curl)"
fi
echo ""

if [ "$FUNNEL" = "1" ]; then
  candidates=""
  for ((s=1; s<=max_strat; s++)); do candidates="$candidates$s "; done

  for ((pass=1; pass<=PASSES; pass++)); do
    ncand=$(echo "$candidates" | wc -w)
    if [ "$ncand" -eq 0 ]; then
      echo "--- Проход $pass/$PASSES пропущен: не осталось кандидатов ---"
      break
    fi
    if [ "$pass" -gt 1 ] && [ -z "$GV_HOST_OVERRIDE" ]; then
      if resolve_edge "$(gv_pick_video_id "$pass")"; then
        echo "  (эдж на этот проход, видео $(gv_pick_video_id "$pass"): $GV_HOST)"
      else
        echo "  не удалось переразрезолвить эдж, использую предыдущий: $GV_HOST" >&2
      fi
    fi
    echo "--- Проход $pass/$PASSES (кандидатов: $ncand, эдж: $GV_HOST) ---"
    step=0
    next_candidates=""
    for s in $candidates; do
      orch_locked_set "$PROFILE" "$PROTO" "$s"
      sleep "$SETTLE_SECONDS"

      pass_ok=0
      for ((attempt=1; attempt<=ATTEMPTS_PER_STRATEGY; attempt++)); do
        bytes_received="$(python3 "$SCRIPT_DIR/quic_probe.py" "$GV_HOST" "$GV_PATH" \
            --range-bytes "$RANGE_BYTES" --timeout "$QUIC_TIMEOUT" 2>>"$LOG_DIR/rank_quic_${RUN_TS}.stderr.log")"
        rc=$?
        success=0
        if [ "$rc" -eq 0 ] && [ "${bytes_received:-0}" -ge "$RANGE_BYTES" ] 2>/dev/null; then
          success=1
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$pass" "$s" "$attempt" "$success" "${bytes_received:-0}" >> "$RAW_FILE"
        [ "$success" = "1" ] && pass_ok=1
      done
      [ "$pass_ok" = "1" ] && next_candidates="$next_candidates$s "
      step=$((step + 1))
      print_progress "$step" "$ncand" "проход=$pass strategy=$s (QUIC, медленно)"
    done
    print_progress_done
    candidates="$next_candidates"
    echo "  проход $pass завершён, выжило кандидатов: $(echo "$candidates" | wc -w)"
  done
else
  total_steps=$((max_strat * PASSES))
  current_step=0

  for ((pass=1; pass<=PASSES; pass++)); do
    if [ "$pass" -gt 1 ] && [ -z "$GV_HOST_OVERRIDE" ]; then
      if resolve_edge "$(gv_pick_video_id "$pass")"; then
        echo "  (эдж на этот проход, видео $(gv_pick_video_id "$pass"): $GV_HOST)"
      else
        echo "  не удалось переразрезолвить эдж, использую предыдущий: $GV_HOST" >&2
      fi
    fi
    echo "--- Проход $pass/$PASSES (эдж: $GV_HOST) ---"
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
fi

echo ""
echo "Возврат к исходной стратегии:"
revert_to_entry_strategy

echo ""
echo "=== Агрегация по $PASSES проходам ==="
echo ""

awk -F'\t' '
  BEGIN { nstrat = 0 }
  NR==1 { next }
  {
    pass = $1; strat = $2; succ = $4; bytes = $5
    total[strat]++
    if (pass+0 > maxpass[strat]+0) maxpass[strat] = pass+0
    if (succ == 1) {
      successes[strat]++
      sumbytes[strat] += bytes
      cntbytes[strat]++
    }
  }
  END {
    printf "%-10s %-12s %-15s %-10s %-6s\n", "Стратегия", "Успех", "Ср.байт", "Надёжность", "Раунд"
    n = 0
    max_s = 0
    for (s in total) { if (s+0 > max_s) max_s = s+0 }
    for (si = 1; si <= max_s; si++) {
      s = si
      if ((s in total) && (s in successes) && successes[s] > 0) {
        rate = successes[s] / total[s]
        avgb = sumbytes[s] / cntbytes[s]
        order[n] = s SUBSEP rate SUBSEP avgb SUBSEP maxpass[s]
        n++
      }
    }
    for (i = 0; i < n; i++) {
      for (j = i+1; j < n; j++) {
        split(order[i], a, SUBSEP); split(order[j], b, SUBSEP)
        if (b[4]+0 > a[4]+0 || (b[4]+0 == a[4]+0 && (b[2]+0 > a[2]+0 || (b[2]+0 == a[2]+0 && b[3]+0 > a[3]+0)))) {
          tmp = order[i]; order[i] = order[j]; order[j] = tmp
        }
      }
    }
    for (i = 0; i < n; i++) {
      split(order[i], a, SUBSEP)
      s = a[1]; rate = a[2]; avgb = a[3]; mp = a[4]
      printf "%-10s %-12s %-15.0f %-10s %-6s\n", s, successes[s]"/"total[s], avgb, sprintf("%.0f%%", rate*100), mp
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
    pass = $1; strat = $2; succ = $4; bytes = $5
    if (!(strat in total)) { stratlist[nstrat] = strat; nstrat++ }
    total[strat]++
    if (pass+0 > maxpass[strat]+0) maxpass[strat] = pass+0
    if (succ == 1) { successes[strat]++; sumbytes[strat] += bytes; cntbytes[strat]++ }
  }
  END {
    n = 0
    for (k = 0; k < nstrat; k++) {
      s = stratlist[k]
      if ((s in successes) && successes[s] > 0) {
        rate = successes[s] / total[s]
        avgb = sumbytes[s] / cntbytes[s]
        order[n] = s SUBSEP rate SUBSEP avgb SUBSEP maxpass[s]
        n++
      }
    }
    for (i = 0; i < n; i++) {
      for (j = i+1; j < n; j++) {
        split(order[i], a, SUBSEP); split(order[j], b, SUBSEP)
        if (b[4]+0 > a[4]+0 || (b[4]+0 == a[4]+0 && (b[2]+0 > a[2]+0 || (b[2]+0 == a[2]+0 && b[3]+0 > a[3]+0)))) {
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
