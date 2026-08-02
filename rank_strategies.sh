#!/usr/bin/env bash
# rank_strategies.sh — многопроходный рейтинг стратегий профиля.
# В отличие от exhaustive_tune.sh (один прогон, шумно) — делает несколько
# полных проходов по всем стратегиям и усредняет, чтобы отличить реально
# стабильно хорошие/плохие стратегии от разового сетевого шума.
#
# Запуск: sudo ./rank_strategies.sh --profile 1 --passes 3 [--attempts N] [--settle SEC]

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/z2r_autobench/logs"
PASSES=3
SETTLE_SECONDS="${SETTLE_SECONDS:-3}"
ATTEMPTS_PER_STRATEGY="${ATTEMPTS_PER_STRATEGY:-2}"
PROFILE="1"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --passes) PASSES="$2"; shift 2 ;;
    --attempts) ATTEMPTS_PER_STRATEGY="$2"; shift 2 ;;
    --settle) SETTLE_SECONDS="$2"; shift 2 ;;
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

case "$PROFILE" in
  1) TITLE="YT_TLS/HTTP"; PROTO="tls http"; URL="https://www.youtube.com/"; IS_HTTP=0 ;;
  2) TITLE="Googlevideo_TLS"; PROTO="tls"; URL="$(get_gv_test_url)"; IS_HTTP=0 ;;
  3) TITLE="RKN_TLS"; PROTO="tls"; URL="https://meduza.io"; IS_HTTP=0 ;;
  4) TITLE="Discord_TLS"; PROTO="tls"; URL="https://discord.com/"; IS_HTTP=0 ;;
  8) TITLE="Fallback_TLS"; PROTO="tls"; URL="https://rutracker.org"; IS_HTTP=0 ;;
  9) TITLE="Fallback_HTTP"; PROTO="http"; URL="http://rutracker.org"; IS_HTTP=1 ;;
  *) echo "Неизвестный/неподдерживаемый профиль: $PROFILE (доступны: 1,2,3,4,8,9)" >&2; exit 1 ;;
esac

mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RAW_FILE="$LOG_DIR/rank_${PROFILE}_${RUN_TS}.raw.tsv"
echo -e "pass\tstrategy\tattempt\tsuccess\tbytes" > "$RAW_FILE"

autobench_backup_locks "$RUN_TS"

max_strat="$(config_profile_max_strategy "$PROFILE" "")"
if [ -z "$max_strat" ] || [ "$max_strat" -le 0 ]; then
  echo "Не удалось определить число стратегий для профиля $PROFILE." >&2
  exit 1
fi

declare -A PREV_STRATEGY
for p in $PROTO; do
  PREV_STRATEGY["$p"]="$(get_strategy "$PROFILE" "$p")"
done

echo "=== rank_strategies.sh: старт $(date) ==="
echo "Профиль=$PROFILE ($TITLE), стратегии=1..$max_strat, проходов=$PASSES, попыток на стратегию=$ATTEMPTS_PER_STRATEGY"
echo "Итого запросов: $((max_strat * PASSES * ATTEMPTS_PER_STRATEGY))"
echo ""

total_steps=$((max_strat * PASSES))
current_step=0

for ((pass=1; pass<=PASSES; pass++)); do
  echo "--- Проход $pass/$PASSES ---"
  for ((s=1; s<=max_strat; s++)); do
    for p in $PROTO; do
      set_strategy "$PROFILE" "$p" "$s"
    done
    sleep "$SETTLE_SECONDS"

    for ((attempt=1; attempt<=ATTEMPTS_PER_STRATEGY; attempt++)); do
      success=0
      bytes=0
      if [ "$IS_HTTP" = "1" ]; then
        if probe_http_url "$URL"; then success=1; fi
      else
        if probe_url "$URL"; then
          success=1
          b12=${TLS12_BYTES:-0}; b13=${TLS13_BYTES:-0}
          bytes=$(( b12 > b13 ? b12 : b13 ))
        fi
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$pass" "$s" "$attempt" "$success" "$bytes" >> "$RAW_FILE"
    done
    current_step=$((current_step + 1))
    print_progress "$current_step" "$total_steps" "проход=$pass strategy=$s"
  done
  print_progress_done
  echo "  проход $pass завершён"
done

echo ""
echo "Возврат к исходной стратегии (скрипт только измеряет, решение — за тобой):"
for p in $PROTO; do
  if [ -n "${PREV_STRATEGY[$p]}" ] && [ "${PREV_STRATEGY[$p]}" != "0" ]; then
    set_strategy "$PROFILE" "$p" "${PREV_STRATEGY[$p]}"
    echo "  proto=$p -> strategy=${PREV_STRATEGY[$p]}"
  else
    orch_locked_clear "$PROFILE" "$p"
    echo "  proto=$p -> auto (был не задан)"
  fi
done

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
    # сортировка: по надёжности убыв., затем по среднему байту убыв.
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
    if (!found_fail) print "  (нет — все протестированные хотя бы раз сработали)"
    print ""
    ordered = ""
    for (i = 0; i < n; i++) {
      split(order[i], a, SUBSEP)
      ordered = ordered a[1] " "
    }
    printf "ORDERED_SUCCESS: %s\n", ordered
  }
' "$RAW_FILE"

# Дублируем финальный результат в отдельный файл с предсказуемым именем —
# так внешние скрипты (test_menu.sh) могут забрать его, не захватывая
# весь stdout/stderr через $(...) (что убило бы live-вывод прогресс-бара).
LAST_ORDERED_FILE="$LOG_DIR/last_ordered_profile_${PROFILE}.txt"
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
echo "Сырые данные (все попытки всех проходов): $RAW_FILE"
