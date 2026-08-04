#!/usr/bin/env bash
# cross_device_tune.sh — ищет стратегии, которые работают не только на
# хосте, но и на ВСЕХ реальных клиентских устройствах (ПК, мобильный, ТВ).
#
# rank_strategies.sh/rank_quic.sh тестируют только с самого сервера — по
# опыту с прошлой связкой zapret1+VLESS не все хост-рабочие стратегии
# реально работают на ТВ (разные клиенты ведут себя по-разному даже на
# одном канале). Автоматической проверки на реальных устройствах нет и
# быть не может (это не наш процесс) — поэтому здесь ручной, но
# структурированный обход: берём кандидатов из хост-теста (ORDERED_SUCCESS,
# от лучшей к худшей), применяем по одной, спрашиваем "работает на
# ПК/моб/ТВ?" и копим ответы в файл между запусками. В конце — отчёт:
# какие стратегии "универсальны" (да everywhere), какие частично.
#
# Запуск:
#   sudo ./cross_device_tune.sh --profile 1                       # обход кандидатов из last_ordered_profile_1.txt
#   sudo ./cross_device_tune.sh --profile 1 --candidates "25 22 10"  # свой список вместо файла
#   sudo ./cross_device_tune.sh --profile 1 --retest               # переспросить уже полностью проверенные
#   sudo ./cross_device_tune.sh --profile 1 --report               # только отчёт по уже накопленным данным

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/z2r_autobench/logs"
PROFILE=""
CANDIDATES_OVERRIDE=""
REPORT_ONLY=0
RETEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --candidates) CANDIDATES_OVERRIDE="$2"; shift 2 ;;
    --report) REPORT_ONLY=1; shift ;;
    --retest) RETEST=1; shift ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

[ -n "$PROFILE" ] || { echo "Нужен --profile N" >&2; exit 1; }

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

declare -A PROFILE_PROTO=(
  [1]="tls http"
  [2]="tls"
  [3]="tls"
  [4]="tls"
  [5]="udp"
  [8]="tls"
  [9]="http"
)
PROTO="${PROFILE_PROTO[$PROFILE]:-}"
[ -n "$PROTO" ] || { echo "Профиль $PROFILE не поддерживается (доступны: ${!PROFILE_PROTO[*]})." >&2; exit 1; }

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/cross_device_profile_${PROFILE}.tsv"
[ -f "$LOG_FILE" ] || echo -e "strategy\tpc\tmobile\ttv\ttested_at" > "$LOG_FILE"

# --- накопленные результаты в память: strategy -> pc/mobile/tv/tested_at ---
declare -A RES_PC RES_MOBILE RES_TV RES_TS
while IFS=$'\t' read -r strat pc mobile tv ts; do
  [ "$strat" = "strategy" ] && continue
  [ -n "$strat" ] || continue
  RES_PC["$strat"]="$pc"
  RES_MOBILE["$strat"]="$mobile"
  RES_TV["$strat"]="$tv"
  RES_TS["$strat"]="$ts"
done < "$LOG_FILE"

save_results() {
  # Файл маленький — проще перезаписать целиком из массивов, чем
  # аккуратно апдейтить построчно. Важно: сортируем ТОЛЬКО строки данных
  # (через отдельный пайп в sort), а не всё вместе через head/tail — head
  # умеет читать вперёд большим буфером и может "съесть" часть данных,
  # предназначенных для tail (проверено на практике при подготовке этого
  # скрипта: с head/tail строки данных терялись, оставался только заголовок).
  {
    echo -e "strategy\tpc\tmobile\ttv\ttested_at"
    for s in "${!RES_PC[@]}"; do
      printf '%s\t%s\t%s\t%s\t%s\n' "$s" "${RES_PC[$s]}" "${RES_MOBILE[$s]}" "${RES_TV[$s]}" "${RES_TS[$s]}"
    done | sort -t $'\t' -k1,1n
  } > "$LOG_FILE.tmp"
  mv "$LOG_FILE.tmp" "$LOG_FILE"
}

print_report() {
  echo ""
  echo "=== Кросс-девайс отчёт: профиль $PROFILE ==="
  if [ "${#RES_PC[@]}" -eq 0 ]; then
    echo "Пока нет данных — запусти без --report, чтобы начать обход кандидатов."
    return 0
  fi
  printf "%-10s %-6s %-8s %-6s\n" "Стратегия" "ПК" "Моб" "ТВ"
  local universal="" partial=""
  for s in $(printf '%s\n' "${!RES_PC[@]}" | sort -n); do
    printf "%-10s %-6s %-8s %-6s\n" "$s" "${RES_PC[$s]:--}" "${RES_MOBILE[$s]:--}" "${RES_TV[$s]:--}"
    if [ "${RES_PC[$s]:-}" = "y" ] && [ "${RES_MOBILE[$s]:-}" = "y" ] && [ "${RES_TV[$s]:-}" = "y" ]; then
      universal="$universal$s "
    elif [ "${RES_PC[$s]:-}" = "y" ] || [ "${RES_MOBILE[$s]:-}" = "y" ] || [ "${RES_TV[$s]:-}" = "y" ]; then
      partial="$partial$s "
    fi
  done
  echo ""
  echo "Универсальные (работают и на ПК, и на моб, и на ТВ): ${universal:-нет ещё ни одной}"
  echo "Частично рабочие (не везде):                         ${partial:-нет}"
}

if [ "$REPORT_ONLY" = "1" ]; then
  print_report
  exit 0
fi

if [ ! -t 0 ]; then
  echo "cross_device_tune.sh требует интерактивный терминал (проверки на устройствах руками) — не для service/cron." >&2
  exit 1
fi

if ! zapret2_running; then
  echo "zapret2 (nfqws2) не запущен." >&2
  exit 1
fi

acquire_tune_lock "cross_device_tune.sh --profile $PROFILE" 10 || exit 1

if [ -n "$CANDIDATES_OVERRIDE" ]; then
  candidates="$CANDIDATES_OVERRIDE"
else
  ordered_file="$LOG_DIR/last_ordered_profile_${PROFILE}.txt"
  if [ ! -s "$ordered_file" ]; then
    echo "Нет $ordered_file — сначала прогони rank_strategies.sh/rank_quic.sh --profile $PROFILE (или передай свой список через --candidates)." >&2
    exit 1
  fi
  candidates="$(cat "$ordered_file")"
fi
[ -n "$(echo "$candidates" | tr -d ' ')" ] || { echo "Список кандидатов пуст." >&2; exit 1; }

# Спрашивает "работает на <label>?" — Enter оставляет прошлый сохранённый
# ответ (или пусто, если его не было). Результат кладёт в переменную $2 по
# имени (printf -v), а не через $(...) — read внутри command substitution
# в этом проекте уже создавал путаницу с живым выводом, не рискуем снова.
read_yn_inline() {
  local label="$1" outvar="$2" existing="${3:-}" prompt ans
  if [ -n "$existing" ]; then
    prompt="  $label — работает? [y/n, Enter=$existing]: "
  else
    prompt="  $label — работает? [y/n, Enter=пропустить]: "
  fi
  read -re -p "$prompt" ans
  case "$ans" in
    y|Y) ans="y" ;;
    n|N) ans="n" ;;
    *) ans="$existing" ;;
  esac
  printf -v "$outvar" '%s' "$ans"
}

declare -A PREV_STRATEGY
for p in $PROTO; do
  PREV_STRATEGY["$p"]="$(get_strategy "$PROFILE" "$p")"
done

echo "=== cross_device_tune.sh: профиль $PROFILE, кандидаты (от лучшей): $candidates ==="
echo "На каждую стратегию: применяю, проверяете на устройствах, отвечаете y/n (Enter — не менять сохранённый ответ)."
echo ""

for s in $candidates; do
  if [ "$RETEST" != "1" ] && [ "${RES_PC[$s]:-}" = "y" ] && [ "${RES_MOBILE[$s]:-}" = "y" ] && [ "${RES_TV[$s]:-}" = "y" ]; then
    echo "Стратегия $s уже отмечена универсальной — пропускаю (--retest чтобы перепроверить)."
    continue
  fi

  for p in $PROTO; do
    bash "$SCRIPT_DIR/set_strategy_cli.sh" set "$PROFILE" "$p" "$s" >/dev/null
  done
  echo ""
  echo "--- Стратегия $s применена (профиль $PROFILE, протокол(ы): $PROTO) ---"

  ans_pc=""; ans_mobile=""; ans_tv=""
  read_yn_inline "ПК" ans_pc "${RES_PC[$s]:-}"
  read_yn_inline "Мобильный" ans_mobile "${RES_MOBILE[$s]:-}"
  read_yn_inline "ТВ" ans_tv "${RES_TV[$s]:-}"

  RES_PC["$s"]="$ans_pc"
  RES_MOBILE["$s"]="$ans_mobile"
  RES_TV["$s"]="$ans_tv"
  RES_TS["$s"]="$(date +%Y-%m-%dT%H:%M:%S)"
  save_results

  if [ "$ans_pc" = "y" ] && [ "$ans_mobile" = "y" ] && [ "$ans_tv" = "y" ]; then
    echo ">>> Стратегия $s — универсальная (ПК+моб+ТВ)."
    read -re -p "Закончить обход прямо сейчас? [Y/n]: " stop_ans
    case "$stop_ans" in
      n|N) ;;
      *) break ;;
    esac
  fi
done

echo ""
echo "Возврат к исходной стратегии:"
for p in $PROTO; do
  if [ -n "${PREV_STRATEGY[$p]}" ] && [ "${PREV_STRATEGY[$p]}" != "0" ]; then
    bash "$SCRIPT_DIR/set_strategy_cli.sh" set "$PROFILE" "$p" "${PREV_STRATEGY[$p]}" >/dev/null
    echo "  proto=$p -> strategy=${PREV_STRATEGY[$p]}"
  fi
done

print_report
echo ""
echo "Данные сохранены: $LOG_FILE (можно продолжить позже тем же запуском — уже проверенные с y/y/y пропускаются)."
