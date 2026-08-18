#!/usr/bin/env bash
# rank_voice.sh — многопроходный рейтинг стратегий профиля 6 (VOICE_UDP,
# голосовые каналы Discord). Аналог rank_strategies.sh/rank_quic.sh по
# структуре и выходному формату (ORDERED_SUCCESS, last_ordered_profile_6.txt
# — тот же файл, что читает retune_profile() в autotune_daemon.sh), но
# источник живого сигнала другой: НЕ curl/quic_probe.py, а HTTP /probe
# отдельного z2r_test-voice-bot (см. z2r_test-voice-bot/bot.py::handle_probe).
#
# ВАЖНО, в отличие от TCP/QUIC-раннеров: тест идёт ЧЕРЕЗ ПЕСОЧНИЦУ Zenith,
# не боевой /opt/zapret2 — z2r_test-voice-bot сознательно переделан именно
# так (живой инцидент 2026-08-07, см. z2r_test-voice-bot/README.md
# "Песочница, не прод": раньше /voice_test реально переключал боевой
# locked.tsv на время теста, ломая голос всем пользователям сразу).
# Поэтому rank_voice.sh НИЧЕГО не пишет и не откатывает в locked.tsv/
# profile.lock профиля 6 сам — только измеряет через песочницу. Применение
# найденного победителя к боевому профилю 6 (set_strategy) — забота
# вызывающего (retune_profile() в autotune_daemon.sh), как и для всех
# остальных rank_*.sh. Root всё равно нужен — не ради /opt/zapret2 (его
# скрипт не трогает), а ради общего TUNE_LOCK_FILE (см. ниже), который
# лежит в root-owned $ORCH_DIR.
#
# Метрика — время подключения в мс (МЕНЬШЕ = ЛУЧШЕ), как и у
# parse_voice_rank.sh (тот же voice_bot_raw.tsv, только оттуда — из ручного
# /voice_rank в Discord, а не из автоматического прогона).
#
# Запуск: ./rank_voice.sh --passes 3 [--attempts N] [--settle SEC] [--funnel]
#         [--probe-url http://127.0.0.1:8765/probe] [--probe-timeout SEC]

set -uo pipefail

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root (не ради /opt/zapret2 — ради общего TUNE_LOCK_FILE, см. докстринг выше)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/z2r_autobench/logs"
PASSES=3
SETTLE_SECONDS="${SETTLE_SECONDS:-2}"
ATTEMPTS_PER_STRATEGY="${ATTEMPTS_PER_STRATEGY:-2}"
PROFILE="6"
FUNNEL=0
PROBE_URL="${PROBE_URL:-http://127.0.0.1:8765/probe}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-25}"

while [ $# -gt 0 ]; do
  case "$1" in
    --passes) PASSES="$2"; shift 2 ;;
    --attempts) ATTEMPTS_PER_STRATEGY="$2"; shift 2 ;;
    --settle) SETTLE_SECONDS="$2"; shift 2 ;;
    --funnel) FUNNEL=1; shift ;;
    --probe-url) PROBE_URL="$2"; shift 2 ;;
    --probe-timeout) PROBE_TIMEOUT="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

# Не root: не трогаем /opt/zapret2 вообще, только читаем max_strat через
# config_profile_max_strategy (тоже просто чтение z2r'овского config.sh).
# Общий TUNE_LOCK_FILE всё же берём — чтобы наш собственный ретюн-процесс
# и, например, ручной параллельный запуск этого же скрипта не долбили
# песочницу одновременно (Zenith's own sandbox usage для генерации
# геномов — отдельная, уже существующая забота ВНЕ этого скрипта, тут не
# решаем).
acquire_tune_lock "rank_voice.sh" 10 || exit 1

max_strat="$(config_profile_max_strategy "$PROFILE" "")"
if [ -z "$max_strat" ] || [ "$max_strat" -le 0 ]; then
  echo "Не удалось определить число стратегий для профиля $PROFILE." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RAW_FILE="$LOG_DIR/rank_${PROFILE}_${RUN_TS}.raw.tsv"
echo -e "pass\tstrategy\tattempt\tsuccess\tms" > "$RAW_FILE"

# Возвращает "success<TAB>connect_ms<TAB>note" одной строкой. success — 0/1.
probe_voice_strategy() {
  local strategy_n="$1"
  local resp
  resp="$(curl -sS -X POST "$PROBE_URL" -H 'Content-Type: application/json' \
      --max-time "$PROBE_TIMEOUT" \
      -d "{\"strategy_n\": $strategy_n}" 2>/dev/null)"
  if [ -z "$resp" ]; then
    printf '0\t0\tнет ответа от %s (бот не запущен?)\n' "$PROBE_URL"
    return
  fi
  python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception as e:
    print('0\t0\tinvalid JSON: %s' % e)
    sys.exit(0)
note = str(d.get('note', '')).replace('\t', ' ').replace('\n', ' ')
print('%d\t%d\t%s' % (1 if d.get('success') else 0, int(d.get('connect_ms', 0) or 0), note))
" "$resp"
}

echo "=== rank_voice.sh: старт $(date) ==="
if [ "$FUNNEL" = "1" ]; then
  echo "Профиль=6 (VOICE_UDP), стратегии=1..$max_strat, режим=funnel (до $PASSES проходов, отсеивание нерабочих), попыток на стратегию=$ATTEMPTS_PER_STRATEGY, тест через песочницу (не боевой конфиг)"
else
  echo "Профиль=6 (VOICE_UDP), стратегии=1..$max_strat, проходов=$PASSES, попыток на стратегию=$ATTEMPTS_PER_STRATEGY, тест через песочницу (не боевой конфиг)"
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
    echo "--- Проход $pass/$PASSES (кандидатов: $ncand) ---"
    step=0
    next_candidates=""
    for s in $candidates; do
      pass_ok=0
      for ((attempt=1; attempt<=ATTEMPTS_PER_STRATEGY; attempt++)); do
        IFS=$'\t' read -r success ms note < <(probe_voice_strategy "$s")
        printf '%s\t%s\t%s\t%s\t%s\n' "$pass" "$s" "$attempt" "${success:-0}" "${ms:-0}" >> "$RAW_FILE"
        [ "${success:-0}" = "1" ] && pass_ok=1
        sleep "$SETTLE_SECONDS"
      done
      [ "$pass_ok" = "1" ] && next_candidates="$next_candidates$s "
      step=$((step + 1))
      print_progress "$step" "$ncand" "проход=$pass strategy=$s (voice)"
    done
    print_progress_done
    candidates="$next_candidates"
    echo "  проход $pass завершён, выжило кандидатов: $(echo "$candidates" | wc -w)"
  done
else
  total_steps=$((max_strat * PASSES))
  current_step=0

  for ((pass=1; pass<=PASSES; pass++)); do
    echo "--- Проход $pass/$PASSES ---"
    for ((s=1; s<=max_strat; s++)); do
      for ((attempt=1; attempt<=ATTEMPTS_PER_STRATEGY; attempt++)); do
        IFS=$'\t' read -r success ms note < <(probe_voice_strategy "$s")
        printf '%s\t%s\t%s\t%s\t%s\n' "$pass" "$s" "$attempt" "${success:-0}" "${ms:-0}" >> "$RAW_FILE"
        sleep "$SETTLE_SECONDS"
      done
      current_step=$((current_step + 1))
      print_progress "$current_step" "$total_steps" "проход=$pass strategy=$s (voice)"
    done
    print_progress_done
    echo "  проход $pass завершён"
  done
fi

echo ""
echo "=== Агрегация по $PASSES проходам (меньше мс = лучше) ==="
echo ""

awk -F'\t' '
  BEGIN { nstrat = 0 }
  NR==1 { next }
  {
    pass = $1; strat = $2; succ = $4; ms = $5
    if (!(strat in total)) { stratlist[nstrat] = strat; nstrat++ }
    total[strat]++
    if (pass+0 > maxpass[strat]+0) maxpass[strat] = pass+0
    if (succ == 1) {
      successes[strat]++
      summs[strat] += ms
      cntms[strat]++
    }
  }
  END {
    printf "%-10s %-12s %-15s %-10s %-6s\n", "Стратегия", "Успех", "Ср.мс", "Надёжность", "Раунд"
    n = 0
    for (k = 0; k < nstrat; k++) {
      s = stratlist[k]
      if ((s in successes) && successes[s] > 0) {
        rate = successes[s] / total[s]
        avgms = summs[s] / cntms[s]
        order[n] = s SUBSEP rate SUBSEP avgms SUBSEP maxpass[s]
        n++
      }
    }
    # сортировка: сначала кто дольше пережил воронку, затем по надёжности
    # убыв., затем по среднему времени подключения ВОЗР. (быстрее = лучше —
    # единственное отличие от rank_strategies.sh/rank_quic.sh, там наоборот)
    for (i = 0; i < n; i++) {
      for (j = i+1; j < n; j++) {
        split(order[i], a, SUBSEP); split(order[j], b, SUBSEP)
        if (b[4]+0 > a[4]+0 || (b[4]+0 == a[4]+0 && (b[2]+0 > a[2]+0 || (b[2]+0 == a[2]+0 && b[3]+0 < a[3]+0)))) {
          tmp = order[i]; order[i] = order[j]; order[j] = tmp
        }
      }
    }
    for (i = 0; i < n; i++) {
      split(order[i], a, SUBSEP)
      s = a[1]; rate = a[2]; avgms = a[3]; mp = a[4]
      printf "%-10s %-12s %-15.0f %-10s %-6s\n", s, successes[s]"/"total[s], avgms, sprintf("%.0f%%", rate*100), mp
    }
    print ""
    print "Провалились во всех попытках всех проходов:"
    found_fail = 0
    for (k = 0; k < nstrat; k++) {
      s = stratlist[k]
      if (!((s in successes) && successes[s] > 0)) {
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

LAST_ORDERED_FILE="$LOG_DIR/last_ordered_profile_6.txt"
awk -F'\t' '
  BEGIN { nstrat = 0 }
  NR==1 { next }
  {
    pass = $1; strat = $2; succ = $4; ms = $5
    if (!(strat in total)) { stratlist[nstrat] = strat; nstrat++ }
    total[strat]++
    if (pass+0 > maxpass[strat]+0) maxpass[strat] = pass+0
    if (succ == 1) { successes[strat]++; summs[strat] += ms; cntms[strat]++ }
  }
  END {
    n = 0
    for (k = 0; k < nstrat; k++) {
      s = stratlist[k]
      if ((s in successes) && successes[s] > 0) {
        rate = successes[s] / total[s]
        avgms = summs[s] / cntms[s]
        order[n] = s SUBSEP rate SUBSEP avgms SUBSEP maxpass[s]
        n++
      }
    }
    for (i = 0; i < n; i++) {
      for (j = i+1; j < n; j++) {
        split(order[i], a, SUBSEP); split(order[j], b, SUBSEP)
        if (b[4]+0 > a[4]+0 || (b[4]+0 == a[4]+0 && (b[2]+0 > a[2]+0 || (b[2]+0 == a[2]+0 && b[3]+0 < a[3]+0)))) {
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
