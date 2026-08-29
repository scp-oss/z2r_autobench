#!/usr/bin/env bash
# rank_strategies.sh — многопроходный рейтинг стратегий профиля.
# В отличие от exhaustive_tune.sh (один прогон, шумно) — делает несколько
# полных проходов по всем стратегиям и усредняет, чтобы отличить реально
# стабильно хорошие/плохие стратегии от разового сетевого шума.
#
# --funnel: тот же смысл (несколько проходов, усреднение), но дешевле —
# каждый следующий проход гоняет только тех кандидатов, кто пережил
# предыдущий (хоть раз сработал), а не все стратегии заново. Старый режим
# (без --funnel) остаётся как есть — им пользуются, если нужно честно
# перепроверить вообще все стратегии на каждом проходе.
#
# --domain example.com: тестировать конкретный домен вместо
# захардкоженного URL профиля. Профиль ОПРЕДЕЛЯЕТСЯ ПО ДОМЕНУ (через
# z2r_detect_governing_profile из z2r_autobench_lib.sh, та же логика, что
# в test_custom_domain.sh) и переопределяет --profile, если оба заданы —
# домен маршрутизируется через РЕАЛЬНЫЙ числовой профиль, гадать его
# заранее руками не нужно (и нельзя протестировать домен через "не тот"
# профиль — это была бы ложная проверка). GV_ROTATE (профиль 2, живой
# эдж googlevideo.com на каждый проход) в этом режиме недостижим — детектор
# никогда не возвращает профиль 2 для произвольного домена.
#
# Запуск: sudo ./rank_strategies.sh --profile 1 --passes 3 [--attempts N] [--settle SEC] [--funnel]
#         sudo ./rank_strategies.sh --domain example.com --funnel --passes 3

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/z2r_autobench/logs"
PASSES=3
SETTLE_SECONDS="${SETTLE_SECONDS:-3}"
ATTEMPTS_PER_STRATEGY="${ATTEMPTS_PER_STRATEGY:-2}"
PROFILE="1"
FUNNEL=0
INCLUDE_CLONE=0
DOMAIN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --passes) PASSES="$2"; shift 2 ;;
    --attempts) ATTEMPTS_PER_STRATEGY="$2"; shift 2 ;;
    --settle) SETTLE_SECONDS="$2"; shift 2 ;;
    --funnel) FUNNEL=1; shift ;;
    --include-clone-strategies) INCLUDE_CLONE=1; shift ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

# Стратегии 31,32,33,34,35,36,38,39,41,42 в общем TCP-шаблоне
# z2r_tcp_tls_common (используется профилями 1/2/3/8) используют
# --lua-desync=tls_client_hello_clone:blob=clone_deepseek|clone_hcaptcha:...
# — этот blob не статический файл, а захватывается ДИНАМИЧЕСКИ из живого
# TLS-хендшейка к chat.deepseek.com/hcaptcha.com. Если на этой машине
# никто и никогда не заходил на эти домены через nfqws2 — blob навсегда
# "unavailable", и стратегия молча передаёт пакеты БЕЗ обхода вообще
# (LUA ERROR в консоли, "passing packet unmodified"). Это не баг подбора —
# такая стратегия может даже показать "успех" в тесте, если ISP в моменте
# не блокирует конкретный URL, и попасть в топ рейтинга как рабочая, хотя
# реально не делает ничего. Проверено вживую на боевом сервере (strategy=36 на
# профиле 1 сломала работавший доступ на телефоне). Исключаем по
# умолчанию; --include-clone-strategies возвращает старое поведение
# (например, если blob уже прогрет вручную и известно, что работает).
CLONE_DEPENDENT_STRATEGIES="31 32 33 34 35 36 38 39 41 42"
clone_dependent_profile() {
  case "$1" in 1|2|3|8) return 0 ;; *) return 1 ;; esac
}
is_clone_dependent_strategy() {
  local s="$1"
  case " $CLONE_DEPENDENT_STRATEGIES " in
    *" $s "*) return 0 ;;
    *) return 1 ;;
  esac
}

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

# --domain переопределяет --profile целиком: домен маршрутизируется через
# РЕАЛЬНЫЙ числовой профиль по хостлистам (та же логика, что в
# test_custom_domain.sh, общая функция z2r_detect_governing_profile в
# z2r_autobench_lib.sh) — угадывать профиль руками для конкретного домена
# не нужно и рискованно (протестировать не через тот профиль — ложная
# проверка, которая ничего не говорит о реальной маршрутизации домена).
if [ -n "$DOMAIN" ]; then
  DOMAIN="$(printf '%s' "$DOMAIN" | sed -E 's#^https?://##; s#/.*$##' | tr '[:upper:]' '[:lower:]')"
  read -r PROFILE PROTO TITLE <<< "$(z2r_detect_governing_profile "$DOMAIN" 0)"
  URL="https://$DOMAIN/"
  IS_HTTP=0
  echo "Домен $DOMAIN -> профиль $PROFILE ($TITLE)"
fi

# Не начинаем перебор, если кто-то другой (демон или второй ручной запуск)
# уже крутит стратегии прямо сейчас — иначе оба прогона будут писать в
# locked.tsv поверх друг друга и оба получат мусорные результаты.
acquire_tune_lock "rank_strategies.sh --profile $PROFILE${DOMAIN:+ --domain $DOMAIN}" 10 || exit 1

if [ -z "$DOMAIN" ]; then
  case "$PROFILE" in
    1) TITLE="YT_TLS/HTTP"; PROTO="tls http"; URL="https://www.youtube.com/"; IS_HTTP=0 ;;
    2) TITLE="Googlevideo_TLS"; PROTO="tls"; URL="$(get_gv_test_url "$(gv_pick_video_id 1)")"; IS_HTTP=0 ;;
    3) TITLE="RKN_TLS"; PROTO="tls"; URL="https://meduza.io"; IS_HTTP=0 ;;
    4) TITLE="Discord_TLS"; PROTO="tls"; URL="https://discord.com/"; IS_HTTP=0 ;;
    8) TITLE="Fallback_TLS"; PROTO="tls"; URL="https://rutracker.org"; IS_HTTP=0 ;;
    9) TITLE="Fallback_HTTP"; PROTO="http"; URL="http://rutracker.org"; IS_HTTP=1 ;;
    *) echo "Неизвестный/неподдерживаемый профиль: $PROFILE (доступны: 1,2,3,4,8,9)" >&2; exit 1 ;;
  esac
fi

# Профиль 2 переразрезолвливает эдж (новое видео из GV_TEST_VIDEO_IDS) на
# КАЖДЫЙ проход -- см. комментарий у GV_TEST_VIDEO_IDS в z2r_autobench_lib.sh.
# Без этого весь прогон (все 52 стратегии, оба режима) бьёт в один и тот же
# эдж всю дорогу -- если именно он забанен, "проваливаются все стратегии"
# ничего не говорит о самих стратегиях (живой случай 2026-08-18). В режиме
# --domain недостижимо: z2r_detect_governing_profile никогда не
# возвращает профиль 2 для произвольного домена.
GV_ROTATE=0
[ "$PROFILE" = "2" ] && GV_ROTATE=1

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

# Живой случай на Server A, 2026-08-18: `systemctl restart autotune-daemon`
# попал прямо в середину прогона этого скрипта (демон вызывает его как
# блокирующий дочерний процесс) — SIGTERM убил перебор посреди пассивной
# пробы стратегии 30 из 52, откат "к исходной стратегии" (см. ниже) не
# успел выполниться, locked.tsv застрял на случайном кандидате из
# середины перебора вместо возврата к рабочей стратегии. GV_TLS "завис"
# на несколько часов, пока не заметили и не поправили руками.
# REVERTED_TO_ENTRY — защита от двойного отката (нормальный путь ниже
# вызывает revert_to_entry_strategy явно для красивого порядка вывода,
# EXIT-трап подстраховывает на любой другой выход, включая ранние `exit 1`
# после этой точки — если оба сработают, второй вызов будет no-op).
REVERTED_TO_ENTRY=0
revert_to_entry_strategy() {
  [ "$REVERTED_TO_ENTRY" = "1" ] && return 0
  REVERTED_TO_ENTRY=1
  for p in $PROTO; do
    if [ -n "${PREV_STRATEGY[$p]:-}" ] && [ "${PREV_STRATEGY[$p]}" != "0" ]; then
      set_strategy "$PROFILE" "$p" "${PREV_STRATEGY[$p]}"
      echo "  proto=$p -> strategy=${PREV_STRATEGY[$p]}"
    else
      orch_locked_clear "$PROFILE" "$p"
      echo "  proto=$p -> auto (был не задан)"
    fi
  done
}
handle_interrupt_signal() {
  echo "" >&2
  echo "!!! rank_strategies.sh прерван сигналом снаружи (напр. systemctl restart поверх работающего демона) -- откатываю locked.tsv к исходной стратегии перед выходом:" >&2
  revert_to_entry_strategy
  exit 143
}
trap handle_interrupt_signal TERM INT
trap revert_to_entry_strategy EXIT

SKIP_CLONE=0
if [ "$INCLUDE_CLONE" != "1" ] && clone_dependent_profile "$PROFILE"; then
  SKIP_CLONE=1
  echo "Профиль $PROFILE: пропускаю стратегии, зависящие от непрогретого clone-блоба ($CLONE_DEPENDENT_STRATEGIES) — --include-clone-strategies, чтобы всё же включить их."
fi

echo "=== rank_strategies.sh: старт $(date) ==="
if [ "$FUNNEL" = "1" ]; then
  echo "Профиль=$PROFILE ($TITLE), стратегии=1..$max_strat, режим=funnel (до $PASSES проходов, отсеивание нерабочих), попыток на стратегию=$ATTEMPTS_PER_STRATEGY"
  echo "Максимум запросов (если ничего не отсеется): $((max_strat * PASSES * ATTEMPTS_PER_STRATEGY)) — реально будет меньше"
else
  echo "Профиль=$PROFILE ($TITLE), стратегии=1..$max_strat, проходов=$PASSES, попыток на стратегию=$ATTEMPTS_PER_STRATEGY"
  echo "Итого запросов: $((max_strat * PASSES * ATTEMPTS_PER_STRATEGY))"
fi
echo ""

if [ "$FUNNEL" = "1" ]; then
  # Воронка: проход 1 гоняет все стратегии, дальше — только тех, кто хоть
  # раз сработал в предыдущем проходе. Дешевле по числу запросов, чем
  # честный повтор всех стратегий на каждом проходе, а итоговая агрегация
  # (см. ниже) сама учитывает, до какого прохода стратегия дожила.
  candidates=""
  for ((s=1; s<=max_strat; s++)); do
    if [ "$SKIP_CLONE" = "1" ] && is_clone_dependent_strategy "$s"; then continue; fi
    candidates="$candidates$s "
  done

  for ((pass=1; pass<=PASSES; pass++)); do
    if [ "$GV_ROTATE" = "1" ] && [ "$pass" -gt 1 ]; then
      URL="$(get_gv_test_url "$(gv_pick_video_id "$pass")")"
      echo "  (видео на этот проход: $(gv_pick_video_id "$pass") -> новый эдж)"
    fi
    ncand=$(echo "$candidates" | wc -w)
    if [ "$ncand" -eq 0 ]; then
      echo "--- Проход $pass/$PASSES пропущен: не осталось кандидатов ---"
      break
    fi
    echo "--- Проход $pass/$PASSES (кандидатов: $ncand) ---"
    step=0
    next_candidates=""
    for s in $candidates; do
      for p in $PROTO; do
        set_strategy "$PROFILE" "$p" "$s"
      done
      sleep "$SETTLE_SECONDS"

      pass_ok=0
      pass_bytes=0
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
        # см. PROFILE_EXTRA_URL/extra_check_ok в z2r_autobench_lib.sh —
        # основной $URL профиля может пройти, а второстепенный, но реально
        # нужный клиенту домен (напр. youtubei.googleapis.com для профиля 1)
        # под той же стратегией — нет (живой инцидент 2026-08-23).
        [ "$success" = "1" ] && ! extra_check_ok "$PROFILE" && success=0
        printf '%s\t%s\t%s\t%s\t%s\n' "$pass" "$s" "$attempt" "$success" "$bytes" >> "$RAW_FILE"
        if [ "$success" = "1" ]; then
          pass_ok=1
          [ "$bytes" -gt "$pass_bytes" ] && pass_bytes=$bytes
        fi
      done
      # Строка на stdout (не только в RAW_FILE) — специально для панели
      # (z0r-panel/funnel_runner.py парсит именно это), чтобы показывать
      # рабочие кандидаты по мере появления, не дожидаясь конца всего
      # прохода/прогона. Раньше единственным сигналом о ходе воронки была
      # строка прогресс-бара (в stderr, только "X/Y strategy=N", без
      # исхода) — сработавший кандидат становился виден только в самом
      # конце прохода через RAW_FILE.
      if [ "$pass_ok" = "1" ]; then
        echo "  strategy=$s -> OK (${pass_bytes} bytes, проход $pass/$PASSES)"
        next_candidates="$next_candidates$s "
      fi
      step=$((step + 1))
      print_progress "$step" "$ncand" "проход=$pass strategy=$s"
    done
    print_progress_done
    candidates="$next_candidates"
    echo "  проход $pass завершён, выжило кандидатов: $(echo "$candidates" | wc -w)"
  done
else
  total_steps=$((max_strat * PASSES))
  current_step=0

  for ((pass=1; pass<=PASSES; pass++)); do
    if [ "$GV_ROTATE" = "1" ] && [ "$pass" -gt 1 ]; then
      URL="$(get_gv_test_url "$(gv_pick_video_id "$pass")")"
      echo "  (видео на этот проход: $(gv_pick_video_id "$pass") -> новый эдж)"
    fi
    echo "--- Проход $pass/$PASSES ---"
    for ((s=1; s<=max_strat; s++)); do
      if [ "$SKIP_CLONE" = "1" ] && is_clone_dependent_strategy "$s"; then
        current_step=$((current_step + 1))
        continue
      fi
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
        # см. PROFILE_EXTRA_URL/extra_check_ok в z2r_autobench_lib.sh —
        # основной $URL профиля может пройти, а второстепенный, но реально
        # нужный клиенту домен (напр. youtubei.googleapis.com для профиля 1)
        # под той же стратегией — нет (живой инцидент 2026-08-23).
        [ "$success" = "1" ] && ! extra_check_ok "$PROFILE" && success=0
        printf '%s\t%s\t%s\t%s\t%s\n' "$pass" "$s" "$attempt" "$success" "$bytes" >> "$RAW_FILE"
      done
      current_step=$((current_step + 1))
      print_progress "$current_step" "$total_steps" "проход=$pass strategy=$s"
    done
    print_progress_done
    echo "  проход $pass завершён"
  done
fi

echo ""
echo "Возврат к исходной стратегии (скрипт только измеряет, решение — за тобой):"
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
    # сортировка: сначала кто дольше пережил воронку (при --funnel; в
    # обычном режиме maxpass у всех одинаков и не влияет), затем по
    # надёжности убыв., затем по среднему байту убыв.
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
echo "Сырые данные (все попытки всех проходов): $RAW_FILE"
