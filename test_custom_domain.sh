#!/usr/bin/env bash
# test_custom_domain.sh — многопроходный подбор стратегии для одного ИЛИ
# НЕСКОЛЬКИХ доменов сразу. При нескольких доменах ищет стратегии, которые
# работают ОДНОВРЕМЕННО на всех доменах (пересечение), а не по отдельности.
#
# Домены группируются по РЕАЛЬНОМУ числовому профилю, через который они
# маршрутизируются (определяется по хостлистам). Если домены из списка
# попадают в РАЗНЫЕ профили — единой стратегии для них быть не может (это
# независимые числовые ручки), скрипт тестирует каждую группу отдельно и
# явно предупреждает об этом.
#
# Механизм: домен-ключ в locked.tsv ПОДТВЕРЖДЁННО НЕ РАБОТАЕТ (проверено
# эмпирически на сервере — см. историю). Поэтому тест ведётся через
# РЕАЛЬНЫЙ числовой профиль. ПОБОЧНЫЙ ЭФФЕКТ: пока идёт тест, стратегия
# профиля временно меняется для ВСЕХ доменов под этим профилем, не только
# для тестируемых.
#
# Запуск:
#   sudo ./test_custom_domain.sh --domain rutracker.org --domain rutor.info --domain xvideos.com
#   sudo ./test_custom_domain.sh --domain a.com --domain b.com --passes 3 --apply
#   sudo ./test_custom_domain.sh --domain a.com --add-to-rkn
#       (если домена нет ни в одном списке — зарегистрировать в TCP_Custom.txt
#        и тестировать через профиль 3, вместо теста через fallback/профиль 8)
#
# --apply    — оставить победившую стратегию каждого профиля закреплённой
#              (иначе только измеряет и откатывает, как и остальные скрипты)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/z2r_autobench/logs"
PASSES=3
SETTLE_SECONDS="${SETTLE_SECONDS:-3}"
ATTEMPTS_PER_STRATEGY="${ATTEMPTS_PER_STRATEGY:-2}"
APPLY=0
ADD_TO_RKN=0
DOMAINS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAINS+=("$2"); shift 2 ;;
    --passes) PASSES="$2"; shift 2 ;;
    --settle) SETTLE_SECONDS="$2"; shift 2 ;;
    --attempts) ATTEMPTS_PER_STRATEGY="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --add-to-rkn) ADD_TO_RKN=1; shift ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root." >&2
  exit 1
fi

if [ "${#DOMAINS[@]}" -eq 0 ]; then
  echo "Нужен хотя бы один --domain example.com (можно несколько флагов --domain подряд)" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

if ! zapret2_running; then
  echo "zapret2 (nfqws2) не запущен." >&2
  exit 1
fi

acquire_tune_lock "test_custom_domain.sh" 10 || exit 1

probe_domain_url() {
  # -L — следуем редиректам (напр. xvideos.com -> www.xvideos.com с
  # content-length: 0 на корне — без -L тест всегда бы проваливался
  # независимо от реальной работы DPI-обхода).
  local url="$1"
  local bytes
  bytes="$(curl -sL --range "0-${MIN_BYTES_THRESHOLD}" \
      --connect-timeout 3 --max-time "${THROUGHPUT_TIMEOUT:-4}" \
      -o /dev/null -w '%{size_download}' "$url" 2>/dev/null || echo 0)"
  DOMAIN_BYTES="$bytes"
  [ "${bytes:-0}" -ge "$MIN_BYTES_THRESHOLD" ] 2>/dev/null
}

detect_governing_profile() {
  # $1 = домен, печатает "профиль proto title" через пробел. Логика сама
  # теперь живёт в z2r_autobench_lib.sh (z2r_detect_governing_profile) --
  # общая с rank_strategies.sh --domain, см. её же комментарий там про
  # то, зачем это вынесено из этого файла 2026-08-29.
  z2r_detect_governing_profile "$1" "$ADD_TO_RKN"
}

# --- нормализация доменов + группировка по реальному профилю ---
declare -A GROUP_DOMAINS   # profile_key -> "domain1 domain2 ..."
declare -A GROUP_PROTO
declare -A GROUP_TITLE

for raw_domain in "${DOMAINS[@]}"; do
  d="$(printf '%s' "$raw_domain" | sed -E 's#^https?://##; s#/.*$##' | tr '[:upper:]' '[:lower:]')"
  read -r gprofile gproto gtitle <<< "$(detect_governing_profile "$d")"
  GROUP_DOMAINS["$gprofile"]="${GROUP_DOMAINS[$gprofile]:-} $d"
  GROUP_PROTO["$gprofile"]="$gproto"
  GROUP_TITLE["$gprofile"]="$gtitle"
done

echo "=== Группировка доменов по реальным профилям ==="
for gprofile in "${!GROUP_DOMAINS[@]}"; do
  echo "  Профиль $gprofile (${GROUP_TITLE[$gprofile]}): ${GROUP_DOMAINS[$gprofile]}"
done
if [ "${#GROUP_DOMAINS[@]}" -gt 1 ]; then
  echo ""
  echo "ВНИМАНИЕ: домены попали в РАЗНЫЕ профили — единой стратегии для них"
  echo "быть не может (это независимые числовые ручки). Тестирую каждую"
  echo "группу отдельно, ищу пересечение только внутри своей группы."
fi
echo ""

mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d_%H%M%S)"

test_group() {
  local gprofile="$1"
  local gproto="${GROUP_PROTO[$gprofile]}"
  local gtitle="${GROUP_TITLE[$gprofile]}"
  local -a gdomains=(${GROUP_DOMAINS[$gprofile]})
  local ndomains="${#gdomains[@]}"

  echo "=== ВНИМАНИЕ: побочный эффект (профиль $gprofile / $gtitle) ==="
  echo "Пока идёт тест, стратегия ЭТОГО ПРОФИЛЯ будет временно меняться для ВСЕХ"
  echo "доменов, подпадающих под тот же профиль — не только для тестируемых:"
  echo "  ${gdomains[*]}"
  echo "В конце теста исходная стратегия будет восстановлена (если не указан --apply)."
  echo "=================================================="
  echo ""

  local safe_group="profile${gprofile}"
  local raw_file="$LOG_DIR/domains_${safe_group}_${RUN_TS}.raw.tsv"
  echo -e "pass\tstrategy\tattempt\tdomain\tsuccess\tbytes" > "$raw_file"

  autobench_backup_locks "${RUN_TS}_${safe_group}"

  local max_strat
  max_strat="$(config_profile_max_strategy "$gprofile" "")"
  if [ -z "$max_strat" ] || [ "$max_strat" -le 0 ]; then
    echo "Не удалось определить число стратегий для профиля $gprofile." >&2
    return 1
  fi

  declare -A prev_strategy
  for p in $gproto; do
    prev_strategy["$p"]="$(get_strategy "$gprofile" "$p")"
  done

  echo "Профиль=$gprofile ($gtitle), доменов=$ndomains, стратегии=1..$max_strat, проходов=$PASSES"
  echo ""

  local total_steps=$((max_strat * PASSES))
  local current_step=0

  for ((pass=1; pass<=PASSES; pass++)); do
    echo "--- Проход $pass/$PASSES (профиль $gprofile) ---"
    for ((s=1; s<=max_strat; s++)); do
      for p in $gproto; do
        set_strategy "$gprofile" "$p" "$s"
      done
      sleep "$SETTLE_SECONDS"

      for domain in "${gdomains[@]}"; do
        for ((attempt=1; attempt<=ATTEMPTS_PER_STRATEGY; attempt++)); do
          local success=0 bytes=0
          if probe_domain_url "https://$domain/"; then
            success=1
            bytes="${DOMAIN_BYTES:-0}"
          fi
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pass" "$s" "$attempt" "$domain" "$success" "$bytes" >> "$raw_file"
        done
      done
      current_step=$((current_step + 1))
      print_progress "$current_step" "$total_steps" "проход=$pass strategy=$s"
    done
    print_progress_done
    echo "  проход $pass завершён"
  done

  echo ""
  echo "=== Агрегация для профиля $gprofile: пересечение по доменам [${gdomains[*]}] ==="
  echo ""

  # Агрегация в Python (проще и надёжнее многомерной логики в awk после
  # уже пойманного один раз тонкого бага с неинициализированными индексами)
  python3 << PYEOF
import collections

raw_file = "$raw_file"
domains = "${gdomains[*]}".split()
n_domains = len(domains)

# (strategy) -> domain -> {total, success, sum_bytes, cnt_bytes}
stats = collections.defaultdict(lambda: collections.defaultdict(lambda: {"total": 0, "success": 0, "sum_bytes": 0, "cnt_bytes": 0}))

with open(raw_file) as f:
    next(f)  # header
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 6:
            continue
        _pass, strat, _attempt, domain, success, bytes_ = parts
        st = stats[strat][domain]
        st["total"] += 1
        if success == "1":
            st["success"] += 1
            st["sum_bytes"] += int(bytes_)
            st["cnt_bytes"] += 1

# для каждой стратегии: домен считается "надёжно рабочим", если success==total (100% попыток)
rows = []
for strat, per_domain in stats.items():
    ok_domains = 0
    total_bytes = 0
    total_cnt = 0
    domain_status = []
    for d in domains:
        st = per_domain.get(d, {"total": 0, "success": 0, "sum_bytes": 0, "cnt_bytes": 0})
        is_ok = st["total"] > 0 and st["success"] == st["total"]
        if is_ok:
            ok_domains += 1
            total_bytes += st["sum_bytes"]
            total_cnt += st["cnt_bytes"]
        domain_status.append((d, is_ok))
    avg_bytes = (total_bytes / total_cnt) if total_cnt > 0 else 0
    rows.append((strat, ok_domains, avg_bytes, domain_status))

# сортировка: сначала у кого больше доменов работает (полное пересечение — в топе), потом по байтам
rows.sort(key=lambda r: (-r[1], -r[2]))

print(f"{'Стратегия':<10} {'Доменов OK':<12} {'Ср.байт':<12} Детали")
full_match = []
for strat, ok_domains, avg_bytes, domain_status in rows:
    if ok_domains == 0:
        continue
    details = ", ".join(f"{d}{'✓' if ok else '✗'}" for d, ok in domain_status)
    marker = " <-- ВСЕ ДОМЕНЫ" if ok_domains == n_domains else ""
    print(f"{strat:<10} {ok_domains}/{n_domains:<10} {avg_bytes:<12.0f} {details}{marker}")
    if ok_domains == n_domains:
        full_match.append(strat)

print("")
if full_match:
    print(f"ORDERED_SUCCESS: {' '.join(full_match)}")
else:
    print("ORDERED_SUCCESS: ")
    print("")
    print(f"Ни одна стратегия не прошла ВСЕ {n_domains} доменов одновременно.")
    print("Смотри колонку 'Доменов OK' выше — можно выбрать компромисс (не 100%, но большинство).")

with open("$LOG_DIR/last_ordered_profile_${gprofile}.txt", "w") as out:
    out.write(" ".join(full_match) + " ")
PYEOF

  best_strategy="$(head -1 "$LOG_DIR/last_ordered_profile_${gprofile}.txt" | awk '{print $1}')"

  echo ""
  if [ "$APPLY" = "1" ] && [ -n "$best_strategy" ]; then
    for p in $gproto; do
      set_strategy "$gprofile" "$p" "$best_strategy"
    done
    echo "Применено и закреплено для профиля $gprofile: strategy=$best_strategy (--apply)"
  else
    echo "Возврат к исходному состоянию профиля $gprofile:"
    for p in $gproto; do
      if [ -n "${prev_strategy[$p]}" ] && [ "${prev_strategy[$p]}" != "0" ]; then
        set_strategy "$gprofile" "$p" "${prev_strategy[$p]}"
        echo "  proto=$p -> strategy=${prev_strategy[$p]}"
      else
        orch_locked_clear "$gprofile" "$p"
        echo "  proto=$p -> auto"
      fi
    done
    if [ -n "$best_strategy" ]; then
      echo ""
      echo "Стратегия, работающая на ВСЕХ доменах группы: $best_strategy"
      echo "Чтобы закрепить: перезапусти с флагом --apply."
    fi
  fi
  echo ""
  echo "Сырые данные (профиль $gprofile): $raw_file"
  echo ""
}

for gprofile in "${!GROUP_DOMAINS[@]}"; do
  test_group "$gprofile"
done
