#!/usr/bin/env bash
# parse_voice_rank.sh — читает voice_bot_raw.tsv (пишет zapret-voice-bot
# через команду /voice_rank в Discord) и выдаёт тот же формат вывода, что
# rank_strategies.sh/rank_quic.sh: таблицу + строку ORDERED_SUCCESS.
#
# В отличие от TLS/QUIC-тестов, метрика тут — время подключения в мс,
# МЕНЬШЕ = ЛУЧШЕ (обратный порядок сортировки).
#
# Использование: ./parse_voice_rank.sh [путь_к_voice_bot_raw.tsv]

set -uo pipefail

RAW_FILE="${1:-/opt/z2r_autobench/logs/voice_bot_raw.tsv}"

if [ ! -f "$RAW_FILE" ]; then
  echo "Файл не найден: $RAW_FILE" >&2
  echo "Данных ещё нет — запусти /voice_rank в Discord хотя бы раз." >&2
  exit 1
fi

awk -F'\t' '
  BEGIN { nstrat = 0 }
  NR==1 { next }
  {
    strat = $3; succ = $5; ms = $6
    if (!(strat in total)) {
      stratlist[nstrat] = strat
      nstrat++
    }
    total[strat]++
    if (succ == 1) {
      successes[strat]++
      summs[strat] += ms
      cntms[strat]++
    }
  }
  END {
    printf "%-12s %-12s %-15s %-10s\n", "Стратегия", "Успех", "Ср.мс", "Надёжность"
    n = 0
    for (k = 0; k < nstrat; k++) {
      s = stratlist[k]
      if (s in successes) {
        rate = successes[s] / total[s]
        avgms = summs[s] / cntms[s]
        order[n] = s SUBSEP rate SUBSEP avgms
        n++
      }
    }
    # сортировка: по надёжности убыв., затем по времени подключения ВОЗР. (быстрее = лучше)
    for (i = 0; i < n; i++) {
      for (j = i+1; j < n; j++) {
        split(order[i], a, SUBSEP); split(order[j], b, SUBSEP)
        if (b[2]+0 > a[2]+0 || (b[2]+0 == a[2]+0 && b[3]+0 < a[3]+0)) {
          tmp = order[i]; order[i] = order[j]; order[j] = tmp
        }
      }
    }
    for (i = 0; i < n; i++) {
      split(order[i], a, SUBSEP)
      s = a[1]; rate = a[2]; avgms = a[3]
      printf "%-12s %-12s %-15.0f %-10s\n", s, successes[s]"/"total[s], avgms, sprintf("%.0f%%", rate*100)
    }
    print ""
    print "Провалились во всех попытках:"
    found_fail = 0
    for (k = 0; k < nstrat; k++) {
      s = stratlist[k]
      if (!(s in successes)) { printf "  %s (total=%s)\n", s, total[s]; found_fail = 1 }
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

LOG_DIR="$(dirname "$RAW_FILE")"
LAST_ORDERED_FILE="$LOG_DIR/last_ordered_profile_6.txt"
awk -F'\t' '
  BEGIN { nstrat = 0 }
  NR==1 { next }
  {
    strat = $3; succ = $5; ms = $6
    if (!(strat in total)) { stratlist[nstrat] = strat; nstrat++ }
    total[strat]++
    if (succ == 1) { successes[strat]++; summs[strat] += ms; cntms[strat]++ }
  }
  END {
    n = 0
    for (k = 0; k < nstrat; k++) {
      s = stratlist[k]
      if (s in successes) {
        rate = successes[s] / total[s]
        avgms = summs[s] / cntms[s]
        order[n] = s SUBSEP rate SUBSEP avgms
        n++
      }
    }
    for (i = 0; i < n; i++) {
      for (j = i+1; j < n; j++) {
        split(order[i], a, SUBSEP); split(order[j], b, SUBSEP)
        if (b[2]+0 > a[2]+0 || (b[2]+0 == a[2]+0 && b[3]+0 < a[3]+0)) {
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
