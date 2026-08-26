#!/usr/bin/env bash
# shorts_probe.sh — диагностика: как GV_TLS (профиль 2) справляется с
# паттерном YouTube Shorts (быстрая последовательная подгрузка НЕСКОЛЬКИХ
# коротких роликов подряд, как при свайпе по ленте), а не с одним долгим
# видео, которое тестирует rank_strategies.sh --profile 2 / обычный
# health-check. Живая жалоба на Server A, 2026-08-18: обычное видео и
# интерфейс YouTube работают нормально, шортсы ощутимо тормозят.
#
# ЭТО ДИАГНОСТИКА, НЕ РЕТЮН: ничего не решает и не остаётся применённым
# по умолчанию (кроме явного --apply) — просто измеряет и печатает время
# загрузки каждого шортса на текущей (или на нескольких сравниваемых)
# стратегии(-ях), чтобы ответить на вопрос "правда ли конкретная
# стратегия хуже держит этот паттерн, или дело не в ней".
#
# Метод: тянет СВЕЖИЙ список реальных id шортсов с канала (по умолчанию
# официальный @YouTube — с очень низким риском, что контент вообще
# когда-нибудь пропадёт, в отличие от произвольных роликов сторонних
# авторов) через yt-dlp --flat-playlist, затем для каждого шортса отдельно
# резолвит videoplayback-URL и качает $MIN_BYTES_THRESHOLD байт, замеряя
# ИМЕННО ВРЕМЯ (не только успех/провал) — жалоба была на скорость, не на
# полную недоступность.
#
# Запуск:
#   sudo ./shorts_probe.sh                          # текущая стратегия, 8 шортсов
#   sudo ./shorts_probe.sh --strategies 5,12,29      # сравнить несколько (профиль 2)
#   sudo ./shorts_probe.sh --count 12 --gap 0.5      # больше роликов, короче пауза
#   sudo ./shorts_probe.sh --channel @SomeChannel    # другой источник шортсов

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/z2r_autobench/logs"
PROFILE="2"
PROTO="tls"
COUNT="${COUNT:-8}"
GAP_SECONDS="${GAP_SECONDS:-1}"
SHORTS_CHANNEL="${SHORTS_CHANNEL:-@YouTube}"
STRATEGIES_ARG=""
FETCH_TIMEOUT="${FETCH_TIMEOUT:-6}"

while [ $# -gt 0 ]; do
  case "$1" in
    --strategies) STRATEGIES_ARG="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --gap) GAP_SECONDS="$2"; shift 2 ;;
    --channel) SHORTS_CHANNEL="$2"; shift 2 ;;
    --timeout) FETCH_TIMEOUT="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

if ! command -v yt-dlp >/dev/null 2>&1; then
  echo "Нужен yt-dlp (тот же, что использует профиль 2/5). Установи: pip install yt-dlp --break-system-packages" >&2
  exit 1
fi

if ! zapret2_running; then
  echo "zapret2 (nfqws2) не запущен." >&2
  exit 1
fi

acquire_tune_lock "shorts_probe.sh" 10 || exit 1

mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RAW_FILE="$LOG_DIR/shorts_probe_${RUN_TS}.raw.tsv"
echo -e "strategy\tindex\tvideo_id\tsuccess\tms\tbytes" > "$RAW_FILE"

echo "Тяну свежий список шортсов с канала $SHORTS_CHANNEL..."
mapfile -t SHORTS_IDS < <(timeout "$YT_RESOLVE_TIMEOUT" yt-dlp --flat-playlist --print id \
    "https://www.youtube.com/${SHORTS_CHANNEL}/shorts" 2>/dev/null | head -n "$COUNT")
if [ "${#SHORTS_IDS[@]}" -eq 0 ]; then
  echo "Не удалось получить список шортсов с $SHORTS_CHANNEL (канал недоступен/нет шортсов/yt-dlp не смог). Попробуй --channel другой." >&2
  exit 1
fi
echo "Получено ${#SHORTS_IDS[@]} шортсов: ${SHORTS_IDS[*]}"
echo ""

# Стратегии для сравнения — по умолчанию только текущая закреплённая
# (ничего не переключаем, просто меряем). Если задан --strategies —
# по очереди применяем каждую и откатываемся к исходной в конце, как и
# остальные rank_*.sh.
declare -a STRATEGIES=()
if [ -n "$STRATEGIES_ARG" ]; then
  IFS=',' read -ra STRATEGIES <<< "$STRATEGIES_ARG"
fi

PREV_STRATEGY="$(get_strategy "$PROFILE" "$PROTO")"
CHANGED_STRATEGY=0

REVERTED_TO_ENTRY=0
revert_to_entry_strategy() {
  [ "$REVERTED_TO_ENTRY" = "1" ] && return 0
  REVERTED_TO_ENTRY=1
  [ "$CHANGED_STRATEGY" = "1" ] || return 0
  if [ -n "$PREV_STRATEGY" ] && [ "$PREV_STRATEGY" != "0" ]; then
    set_strategy "$PROFILE" "$PROTO" "$PREV_STRATEGY"
    echo "Возврат к исходной стратегии: $PREV_STRATEGY"
  else
    orch_locked_clear "$PROFILE" "$PROTO"
    echo "Возврат к исходной стратегии: auto (был не задан)"
  fi
}
handle_interrupt_signal() {
  echo "" >&2
  echo "!!! shorts_probe.sh прерван сигналом снаружи -- откатываю locked.tsv к исходной стратегии перед выходом:" >&2
  revert_to_entry_strategy
  exit 143
}
trap handle_interrupt_signal TERM INT
trap revert_to_entry_strategy EXIT

if [ "${#STRATEGIES[@]}" -eq 0 ]; then
  STRATEGIES=("$PREV_STRATEGY")
  echo "Стратегия для теста: текущая закреплённая ($PREV_STRATEGY) -- переключений не будет."
else
  echo "Сравниваю стратегии: ${STRATEGIES[*]}"
fi
echo ""

probe_one_short() {
  local video_id="$1"
  local url
  url="$(resolve_googlevideo_url "$video_id")"
  if [ -z "$url" ]; then
    printf '0\t0\t0\n'
    return
  fi
  local out
  out="$(curl --range "0-${MIN_BYTES_THRESHOLD}" \
      --connect-timeout 3 --max-time "$FETCH_TIMEOUT" \
      -s -o /dev/null -w '%{size_download}\t%{time_total}' "$url" 2>/dev/null)"
  local bytes ms
  bytes="$(echo "$out" | awk -F'\t' '{print $1+0}')"
  ms="$(echo "$out" | awk -F'\t' '{printf "%d", $2*1000}')"
  local success=0
  [ "${bytes:-0}" -ge "$MIN_BYTES_THRESHOLD" ] 2>/dev/null && success=1
  printf '%s\t%s\t%s\n' "$success" "${ms:-0}" "${bytes:-0}"
}

for strat in "${STRATEGIES[@]}"; do
  if [ "$strat" != "$PREV_STRATEGY" ] || [ "${#STRATEGIES[@]}" -gt 1 ]; then
    set_strategy "$PROFILE" "$PROTO" "$strat"
    CHANGED_STRATEGY=1
    sleep 2
  fi
  echo "--- Стратегия $strat ---"
  idx=0
  for vid in "${SHORTS_IDS[@]}"; do
    idx=$((idx + 1))
    IFS=$'\t' read -r success ms bytes < <(probe_one_short "$vid")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$strat" "$idx" "$vid" "$success" "$ms" "$bytes" >> "$RAW_FILE"
    if [ "$success" = "1" ]; then
      echo "  [$idx/${#SHORTS_IDS[@]}] $vid: ok, ${ms}ms, ${bytes} байт"
    else
      echo "  [$idx/${#SHORTS_IDS[@]}] $vid: ПРОВАЛ (${ms}ms, ${bytes} байт)"
    fi
    sleep "$GAP_SECONDS"
  done
  echo ""
done

echo "=== Итог по стратегиям (среднее/макс время успешных запросов, мс) ==="
awk -F'\t' '
  NR==1 { next }
  {
    strat=$1; succ=$4; ms=$5
    total[strat]++
    if (succ==1) { successes[strat]++; summs[strat]+=ms; if (ms+0 > maxms[strat]+0) maxms[strat]=ms+0 }
  }
  END {
    printf "%-12s %-10s %-12s %-12s\n", "Стратегия", "Успех", "Ср.мс", "Макс.мс"
    for (s in total) {
      avg = (s in successes) ? summs[s]/successes[s] : 0
      printf "%-12s %-10s %-12.0f %-12s\n", s, successes[s]+0"/"total[s], avg, maxms[s]+0
    }
  }
' "$RAW_FILE"

echo ""
echo "Сырые данные: $RAW_FILE"
echo ""
echo "Для сравнения — время того же теста на обычном видео: rank_strategies.sh --profile 2 --passes 1 (или health-check в daemon_profile_2.log)"
