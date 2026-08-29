#!/usr/bin/env bash
# z2r_autobench_lib.sh — общие функции для night_tune.sh и blob_tune.sh.
# Не содержит точки входа, только подключается через `source`.
#
# НЕ трогает lua-ядро и /opt/zapret2/z2r_lib/*.sh — только сорсит их как
# библиотеки (config.sh, orchestra_state.sh, netcheck.sh), как это делает
# сам z2r.sh.

# Живой факт, подтверждённый 2026-08-23 на ДВУХ разных серверах (Server A
# после восстановления и Server B на абсолютно свежей, только что
# развёрнутой установке): апстрим-установщик z2r кладёт z2r_lib/
# extra_strats НЕ в /opt/zapret2, а в /opt/zator — это штатная раскладка
# инсталлятора (z2r.sh), не повреждение конкретного сервера. Раньше
# LIB_DIR/ORCH_DIR были жёстко зашиты на /opt/zapret2/..., и КАЖДАЯ
# свежая установка спотыкалась об "Не найден .../z2r_lib/config.sh —
# прерываю", пока кто-то не проставит symlink вручную. Теперь
# автоопределяем базу по тому, где реально лежит z2r_lib — если он есть
# под /opt/zapret2 (как на серверах, где symlink уже когда-то поставили
# вручную), используем её, иначе — /opt/zator. Если не нашли ни там, ни
# там, оставляем дефолт /opt/zapret2, чтобы ниже сработала явная,
# понятная ошибка "не найден", а не тихий неправильный путь.
_z2r_detect_base() {
  if [ -d "/opt/zapret2/z2r_lib" ]; then
    echo "/opt/zapret2"
  elif [ -d "/opt/zator/z2r_lib" ]; then
    echo "/opt/zator"
  else
    echo "/opt/zapret2"
  fi
}
Z2R_BASE="${Z2R_BASE:-$(_z2r_detect_base)}"

LIB_DIR="${LIB_DIR:-$Z2R_BASE/z2r_lib}"
ORCH_DIR="${ORCH_DIR:-$Z2R_BASE/extra_strats/cache/orchestra}"

# --- общий лок на "кто сейчас крутит стратегии" ---
# Ретюн (свой или демона) переключает locked.tsv десятки раз за один прогон.
# Если параллельно запустить второй прогон (например, ручной rank_strategies.sh
# поверх работающего autotune_daemon.sh) — они будут писать поверх друг друга
# и оба получат мусорные результаты. Лок не блокирует health-check (он не
# трогает locked.tsv), только сам перебор.
TUNE_LOCK_FILE="${TUNE_LOCK_FILE:-$ORCH_DIR/.tune.lock}"

# Захватывает лок на текущий процесс (держится до выхода процесса/exec).
# Использование: acquire_tune_lock "название" [таймаут_сек] || exit 1
acquire_tune_lock() {
  local who="${1:-tune}" timeout="${2:-10}"
  mkdir -p "$(dirname "$TUNE_LOCK_FILE")"
  # shellcheck disable=SC2034
  exec {TUNE_LOCK_FD}>"$TUNE_LOCK_FILE"
  if ! flock -w "$timeout" "$TUNE_LOCK_FD"; then
    echo "Не удалось захватить $TUNE_LOCK_FILE за ${timeout}s — кто-то ещё сейчас крутит стратегии ($who подождёт до следующего раза)." >&2
    return 1
  fi
  return 0
}

# netcheck.sh (и другие lib-файлы z2r) не рассчитаны на `set -u` и
# ссылаются на переменные цвета до объявления. Задаём дефолты заранее.
plain='\033[0m'
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'

for _lib in config.sh orchestra_state.sh netcheck.sh; do
  if [ ! -f "$LIB_DIR/$_lib" ]; then
    echo "Не найден $LIB_DIR/$_lib — прерываю." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$LIB_DIR/$_lib"
done
unset _lib

# --- бэкап locked.tsv/locked.manual.tsv ---
autobench_backup_locks() {
  local run_ts="$1"
  local backup_dir="$ORCH_DIR/backups"
  mkdir -p "$backup_dir"
  local f
  for f in locked.tsv locked.manual.tsv; do
    if [ -f "$ORCH_DIR/$f" ]; then
      cp -p "$ORCH_DIR/$f" "$backup_dir/${f}.${run_ts}.bak"
    fi
  done
  echo "Бэкап локов сохранён в $backup_dir (суффикс .${run_ts}.bak)" >&2
}

# --- проверка: реальная закачка N байт, а не голый handshake ---
MIN_BYTES_THRESHOLD="${MIN_BYTES_THRESHOLD:-65536}"

# Прогресс-бар в реальном времени — ВСЕГДА в stderr, никогда в stdout, чтобы
# не ломать никакие $(...) захваты (мы уже дважды обжигались на смешивании
# диагностики со значением, которое кто-то пытается захватить через
# command substitution — см. историю с score_blob() и show_menu()).
print_progress() {
  local current="$1" total="$2" label="$3"
  local percent=$((current * 100 / total))
  local bar_len=30
  local filled=$((percent * bar_len / 100))
  local bar
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $((bar_len - filled)) '' | tr ' ' '-')"
  # \r — в начало строки, \033[K — стереть всё до конца строки (иначе
  # огрызки более длинного предыдущего вывода остаются видны и создают
  # впечатление, что бар печатается на нескольких строках подряд).
  printf '\r\033[K[%s] %3d%% (%d/%d) %s' "$bar" "$percent" "$current" "$total" "$label" >&2
}

print_progress_done() {
  # Перевод строки после последнего \r-обновления, иначе следующий echo
  # налезет на хвост бара.
  echo "" >&2
}

# Определяет, через какой РЕАЛЬНЫЙ числовой профиль маршрутизируется
# произвольный домен (по хостлистам) — общая логика для
# test_custom_domain.sh и rank_strategies.sh --domain (перенесена сюда
# 2026-08-29, до этого была продублирована только в test_custom_domain.sh;
# см. CLAUDE.md "/opt/zapret2 vs /opt/zator" про то, чем кончается
# копипаста одной и той же логики путей по нескольким файлам). Печатает
# "профиль proto title" через пробел.
# $1 = домен, УЖЕ нормализованный (без протокола/пути, в нижнем регистре)
# $2 = 1, чтобы при отсутствии домена во всех списках зарегистрировать
#      его в TCP_Custom.txt и вернуть профиль 3 (RKN_TLS) вместо
#      fallback-профиля 8; по умолчанию (0/не указан) — старое поведение,
#      ничего не регистрирует.
z2r_detect_governing_profile() {
  local d="$1" add_to_rkn="${2:-0}"
  local custom_registry="$ORCH_DIR/custom_domains.tsv"
  if grep -qxi "$d" "$Z2R_BASE/extra_strats/TCP_YT_list.txt" 2>/dev/null; then
    echo "1 tls YT_TLS"
  elif grep -qxi "$d" "$Z2R_BASE/extra_strats/TCP_Discord.txt" 2>/dev/null; then
    echo "4 tls DS_TLS"
  elif grep -qxi "$d" "$Z2R_BASE/extra_strats/TCP_RKN_list.txt" 2>/dev/null \
    || grep -qxi "$d" "$Z2R_BASE/extra_strats/TCP_Custom.txt" 2>/dev/null; then
    echo "3 tls RKN_TLS"
  elif [ -f "$custom_registry" ] && awk -F'\t' -v d="$d" 'tolower($1)==d {found=1; exit} END{exit !found}' "$custom_registry" 2>/dev/null; then
    # Экзотический домен со СВОИМ отдельным профилем (см.
    # custom_domain_cli.sh, 2026-08-29) -- у него уже есть независимая
    # стратегия, отдельная от RKN_TLS/фолбэка, роутить его дальше по
    # старой логике (fallback/add_to_rkn) было бы неверно. awk, не grep
    # -- поле разделено табом, а не "^d\t" буквальным паттерном (grep не
    # везде переносимо интерпретирует \t в паттерне).
    local custom_profile
    custom_profile="$(awk -F'\t' -v d="$d" 'tolower($1)==d {print $2; exit}' "$custom_registry")"
    echo "$custom_profile tls CUSTOM_${custom_profile}"
  else
    if [ "$add_to_rkn" = "1" ]; then
      local cf="$Z2R_BASE/extra_strats/TCP_Custom.txt"
      mkdir -p "$(dirname "$cf")"; touch "$cf"
      if ! grep -qxi "$d" "$cf" 2>/dev/null; then
        echo "$d" >> "$cf"
      fi
      echo "3 tls RKN_TLS"
    else
      echo "8 tls Fallback_TLS"
    fi
  fi
}
THROUGHPUT_TIMEOUT="${THROUGHPUT_TIMEOUT:-4}"

# Раньше probe_url() засчитывала успех, если прошёл ХОТЯ БЫ ОДИН из
# TLS 1.2/1.3 (расчёт был на случаи, когда блокировка бьёт по конкретной
# версии протокола). Живой случай на Server A, 2026-08-18: DS_TLS
# strategy=29 — TLS 1.3 отвечал нормально, TLS 1.2 стабильно давал таймаут
# 2с (видно в собственном тесте z2r), а OR-логика считала профиль здоровым
# (autotune_daemon.sh 6+ часов подряд видел 0 провалов), пока настоящий
# десктопный клиент Discord (которому, похоже, нужен именно TLS 1.2-путь)
# не грузился вообще. PROBE_REQUIRE_BOTH_TLS=1 (по умолчанию) — требовать
# успеха ОБОИХ версий, чтобы такие наполовину рабочие стратегии больше не
# проходили тихо ни в health-check (autotune_daemon.sh), ни при ранжировании
# кандидатов (rank_strategies.sh). Единственный легитимный повод вернуть
# старую OR-логику — если реальный сервер профиля сам физически не
# обслуживает TLS 1.2 (не блокировка, а его собственный отказ от старого
# протокола) — тогда AND будет ложно проваливать профиль целиком; в этом
# случае поставь PROBE_REQUIRE_BOTH_TLS=0 в окружении конкретного запуска.
PROBE_REQUIRE_BOTH_TLS="${PROBE_REQUIRE_BOTH_TLS:-1}"

probe_url() {
  local url="$1"
  local ok12=0 ok13=0
  local bytes12=0 bytes13=0

  bytes12="$(curl --tls-max 1.2 --range "0-${MIN_BYTES_THRESHOLD}" \
      --connect-timeout 3 --max-time "$THROUGHPUT_TIMEOUT" \
      -s -o /dev/null -w '%{size_download}' "$url" 2>/dev/null || echo 0)"
  bytes13="$(curl --tlsv1.3 --range "0-${MIN_BYTES_THRESHOLD}" \
      --connect-timeout 3 --max-time "$THROUGHPUT_TIMEOUT" \
      -s -o /dev/null -w '%{size_download}' "$url" 2>/dev/null || echo 0)"

  [ "${bytes12:-0}" -ge "$MIN_BYTES_THRESHOLD" ] 2>/dev/null && ok12=1
  [ "${bytes13:-0}" -ge "$MIN_BYTES_THRESHOLD" ] 2>/dev/null && ok13=1

  TLS12_OK=$ok12
  TLS13_OK=$ok13
  TLS12_BYTES=$bytes12
  TLS13_BYTES=$bytes13

  if [ "$PROBE_REQUIRE_BOTH_TLS" = "1" ]; then
    if [ "$ok12" -eq 1 ] && [ "$ok13" -eq 1 ]; then
      return 0
    fi
    if [ "$ok12" -ne "$ok13" ]; then
      local which="TLS1.3, TLS1.2 провалился"
      [ "$ok12" -eq 1 ] && which="TLS1.2, TLS1.3 провалился"
      echo "probe_url: $url — прошёл только $which (строгий режим PROBE_REQUIRE_BOTH_TLS=1 считает это провалом)" >&2
    fi
    return 1
  fi

  [ "$ok12" -eq 1 ] || [ "$ok13" -eq 1 ]
}

probe_http_url() {
  local url="$1"
  local bytes
  # Голая connectivity-проверка ("curl вернул 0") недостаточна: страница
  # может отдать пустой/усечённый/редиректный ответ и всё равно вернуть
  # код успеха, как встроенный check_access в самом z2r — именно так
  # profile=9/strategy=4 показал "Есть ответ по HTTP", хотя страница не
  # открывалась в браузере. Поэтому требуем реальной закачки байт, как и
  # для TLS-профилей.
  bytes="$(curl --range "0-${MIN_BYTES_THRESHOLD}" \
      --connect-timeout 3 --max-time "${THROUGHPUT_TIMEOUT:-4}" \
      -s -o /dev/null -w '%{size_download}' "$url" 2>/dev/null || echo 0)"
  HTTP_BYTES="$bytes"
  [ "${bytes:-0}" -ge "$MIN_BYTES_THRESHOLD" ] 2>/dev/null
}

# Лёгкая проверка достижимости — просто что TLS+HTTP реально дошли и
# вернули осмысленный код ответа (не 000/таймаут), без байтового порога
# probe_url/probe_http_url. Нужна для доменов вроде youtubei.googleapis.com,
# у которых нет большой статической страницы, чтобы пройти MIN_BYTES_THRESHOLD,
# но которые реально нужны клиенту.
#
# Живой инцидент 2026-08-23 на Server A: rank_strategies.sh тестировал
# профиль 1 (YT_TLS) только через https://www.youtube.com/ (голая HTML-
# обёртка сайта) и выбрал strategy=19 — она честно проходила по этому URL,
# но youtubei.googleapis.com (InnerTube API, через который реальные клиенты
# — включая мобильное приложение и ТВ — тянут фид/поиск/данные интерфейса)
# под той же strategy=19 стабильно давал TCP/TLS-таймаут. Итог: "сайт
# открывается", а сам YouTube-клиент не грузится, и ни health-check, ни
# ретюн этого не ловили, потому что оба смотрели только на www.youtube.com.
probe_reachable() {
  local url="$1"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout 3 --max-time "${THROUGHPUT_TIMEOUT:-4}" "$url" 2>/dev/null)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

# Профили, для которых один URL недостаточно представителен для реального
# клиента (см. probe_reachable() выше) — дополнительный домен, который
# ОБЯЗАН быть достижим (не байтовый порог, просто не 000), иначе кандидат
# считается проваленным, даже если основной test_url профиля прошёл.
declare -A PROFILE_EXTRA_URL=(
  [1]="https://youtubei.googleapis.com/"
)

# Использование: после успешного probe_url/probe_http_url по основному URL
# профиля — extra_check_ok "$profile" должен тоже пройти, иначе кандидат не
# засчитывается. Профили без записи в PROFILE_EXTRA_URL всегда проходят
# (return 0) — не меняет поведение для профилей, которым это не нужно.
extra_check_ok() {
  local profile="$1"
  local url="${PROFILE_EXTRA_URL[$profile]:-}"
  [ -z "$url" ] && return 0
  probe_reachable "$url"
}

# --- обёртка над orch_locked_set/get с учётом профилей 8/9 (fallback -> locked.manual.tsv) ---
set_strategy() {
  local profile="$1" proto="$2" strategy="$3"
  if [ "$profile" = "8" ] || [ "$profile" = "9" ]; then
    ORCH_LOCK_FILE="$ORCH_DIR/locked.manual.tsv" orch_locked_set "$profile" "$proto" "$strategy"
  else
    orch_locked_set "$profile" "$proto" "$strategy"
  fi
}

get_strategy() {
  local profile="$1" proto="$2"
  if [ "$profile" = "8" ] || [ "$profile" = "9" ]; then
    ORCH_LOCK_FILE="$ORCH_DIR/locked.manual.tsv" orch_locked_get "$profile" "$proto"
  else
    orch_locked_get "$profile" "$proto"
  fi
}

# Неинтерактивный аналог orch_profile_try.
# После выполнения кладёт результат в глобальные:
#   TUNE_RESULT_SUCCESS (0/1), TUNE_RESULT_STRATEGY, TUNE_RESULT_BYTES
tune_profile() {
  local profile="$1" title="$2" proto_list="$3" test_url="$4" is_http="${5:-0}"
  local log_file="${6:-/dev/null}"
  local settle="${SETTLE_SECONDS:-3}"
  local budget="${NIGHT_BUDGET_SECONDS:-25200}"
  local attempts="${ATTEMPTS_PER_STRATEGY:-2}"
  local max_strat start_ts now
  local -A prev

  TUNE_RESULT_SUCCESS=0
  TUNE_RESULT_STRATEGY=0
  TUNE_RESULT_BYTES=0

  max_strat="$(config_profile_max_strategy "$profile" "")"
  if [ -z "$max_strat" ] || [ "$max_strat" -le 0 ]; then
    echo "[$title] не удалось определить число стратегий, пропуск."
    log_row "$log_file" "$profile" "$title" "-" "0" "0" "-" "-" "0" "no_max_strategy"
    return
  fi

  for p in $proto_list; do
    prev["$p"]="$(get_strategy "$profile" "$p")"
  done

  echo "[$title] профиль=$profile стратегии=1..$max_strat url=$test_url"
  start_ts=$(date +%s)
  local s found=0
  for ((s=1; s<=max_strat; s++)); do
    now=$(date +%s)
    if [ $((now - start_ts)) -gt "$budget" ]; then
      echo "[$title] исчерпан бюджет времени, останавливаюсь на strategy=$s"
      break
    fi

    for p in $proto_list; do
      set_strategy "$profile" "$p" "$s"
    done
    sleep "$settle"

    local attempt ok_any=0
    for ((attempt=1; attempt<=attempts; attempt++)); do
      if [ "$is_http" = "1" ]; then
        if probe_http_url "$test_url"; then
          ok_any=1
          log_row "$log_file" "$profile" "$title" "$proto_list" "$s" "$attempt" "-" "-" "1" "http_ok"
        else
          log_row "$log_file" "$profile" "$title" "$proto_list" "$s" "$attempt" "-" "-" "0" "http_fail"
        fi
      else
        if probe_url "$test_url"; then
          ok_any=1
          log_row "$log_file" "$profile" "$title" "$proto_list" "$s" "$attempt" "$TLS12_OK" "$TLS13_OK" "1" "ok"
        else
          log_row "$log_file" "$profile" "$title" "$proto_list" "$s" "$attempt" "$TLS12_OK" "$TLS13_OK" "0" "fail"
        fi
      fi
      # см. PROFILE_EXTRA_URL/extra_check_ok выше — основной $test_url может
      # пройти, а реально нужный клиенту второстепенный домен под той же
      # стратегией — нет (живой инцидент 2026-08-23, профиль 1).
      if [ "$ok_any" -eq 1 ] && ! extra_check_ok "$profile"; then
        ok_any=0
      fi
      [ "$ok_any" -eq 1 ] && break
    done

    if [ "$ok_any" -eq 1 ]; then
      echo "[$title] рабочая стратегия найдена: $s"
      found=1
      TUNE_RESULT_SUCCESS=1
      TUNE_RESULT_STRATEGY=$s
      if [ "$is_http" != "1" ]; then
        local b12=${TLS12_BYTES:-0} b13=${TLS13_BYTES:-0}
        TUNE_RESULT_BYTES=$(( b12 > b13 ? b12 : b13 ))
      fi
      break
    fi
  done

  if [ "$found" -eq 0 ]; then
    echo "[$title] рабочая стратегия не найдена за 1..$max_strat, откат к предыдущим значениям"
    for p in $proto_list; do
      if [ -n "${prev[$p]}" ] && [ "${prev[$p]}" != "0" ]; then
        set_strategy "$profile" "$p" "${prev[$p]}"
      fi
    done
    log_row "$log_file" "$profile" "$title" "$proto_list" "0" "0" "-" "-" "0" "no_working_strategy_rolled_back"
  fi
}

log_row() {
  # log_file profile title proto strategy attempt tls12 tls13 success note
  local log_file="$1"; shift
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" >> "$log_file"
}

# Полный (exhaustive) перебор: НЕ останавливается на первой успешной стратегии,
# проверяет ВСЕ 1..max, меряет байты на каждой (несколько попыток, берём лучшую
# попытку на стратегию — единичный выброс/джиттер не должен решать рейтинг),
# в конце ранжирует и возвращает топ. Дороже по времени, чем tune_profile(),
# но даёт ответ на вопрос "это лучшая стратегия или просто первая рабочая".
#
# После выполнения:
#   EXHAUSTIVE_RESULTS — ассоц. массив strategy -> лучшие_байты_за_попытки (только успешные)
#   EXHAUSTIVE_BEST_STRATEGY, EXHAUSTIVE_BEST_BYTES — победитель
#   EXHAUSTIVE_RANKED — строка "strategy:bytes strategy:bytes ..." отсортированная по убыванию байт
tune_profile_exhaustive() {
  local profile="$1" title="$2" proto_list="$3" test_url="$4" is_http="${5:-0}"
  local log_file="${6:-/dev/null}"
  local settle="${SETTLE_SECONDS:-3}"
  local budget="${NIGHT_BUDGET_SECONDS:-25200}"
  local attempts="${ATTEMPTS_PER_STRATEGY:-2}"
  local max_strat start_ts now
  local -A prev

  unset EXHAUSTIVE_RESULTS
  declare -gA EXHAUSTIVE_RESULTS=()
  EXHAUSTIVE_BEST_STRATEGY=0
  EXHAUSTIVE_BEST_BYTES=0
  EXHAUSTIVE_RANKED=""

  max_strat="$(config_profile_max_strategy "$profile" "")"
  if [ -z "$max_strat" ] || [ "$max_strat" -le 0 ]; then
    echo "[$title] не удалось определить число стратегий, пропуск."
    return 1
  fi

  for p in $proto_list; do
    prev["$p"]="$(get_strategy "$profile" "$p")"
  done

  echo "[$title] EXHAUSTIVE: профиль=$profile стратегии=1..$max_strat url=$test_url"
  start_ts=$(date +%s)
  local s
  for ((s=1; s<=max_strat; s++)); do
    now=$(date +%s)
    if [ $((now - start_ts)) -gt "$budget" ]; then
      echo "[$title] исчерпан бюджет времени на strategy=$s, дальнейшие стратегии пропущены"
      break
    fi

    for p in $proto_list; do
      set_strategy "$profile" "$p" "$s"
    done
    sleep "$settle"

    local attempt best_bytes=0 any_ok=0
    for ((attempt=1; attempt<=attempts; attempt++)); do
      if [ "$is_http" = "1" ]; then
        if probe_http_url "$test_url"; then
          any_ok=1
          log_row "$log_file" "$profile" "$title" "$proto_list" "$s" "$attempt" "-" "-" "1" "http_ok"
        else
          log_row "$log_file" "$profile" "$title" "$proto_list" "$s" "$attempt" "-" "-" "0" "http_fail"
        fi
      else
        if probe_url "$test_url"; then
          any_ok=1
          local b12=${TLS12_BYTES:-0} b13=${TLS13_BYTES:-0}
          local this_bytes=$(( b12 > b13 ? b12 : b13 ))
          [ "$this_bytes" -gt "$best_bytes" ] && best_bytes="$this_bytes"
          log_row "$log_file" "$profile" "$title" "$proto_list" "$s" "$attempt" "$TLS12_OK" "$TLS13_OK" "1" "ok"
        else
          log_row "$log_file" "$profile" "$title" "$proto_list" "$s" "$attempt" "$TLS12_OK" "$TLS13_OK" "0" "fail"
        fi
      fi
    done

    # см. PROFILE_EXTRA_URL/extra_check_ok выше — основной $test_url может
    # пройти, а реально нужный клиенту второстепенный домен под той же
    # стратегией — нет (живой инцидент 2026-08-23, профиль 1).
    if [ "$any_ok" -eq 1 ] && ! extra_check_ok "$profile"; then
      any_ok=0
    fi

    if [ "$any_ok" -eq 1 ]; then
      EXHAUSTIVE_RESULTS[$s]="$best_bytes"
      echo "  strategy=$s: OK, лучшая попытка = $best_bytes байт"
      if [ "$best_bytes" -gt "$EXHAUSTIVE_BEST_BYTES" ]; then
        EXHAUSTIVE_BEST_BYTES="$best_bytes"
        EXHAUSTIVE_BEST_STRATEGY="$s"
      fi
    else
      echo "  strategy=$s: провал (0 успешных попыток из $attempts)"
    fi
  done

  # ранжирование: strategy:bytes, по убыванию байт
  if [ "${#EXHAUSTIVE_RESULTS[@]}" -gt 0 ]; then
    EXHAUSTIVE_RANKED="$(
      for s in "${!EXHAUSTIVE_RESULTS[@]}"; do
        printf '%s:%s\n' "$s" "${EXHAUSTIVE_RESULTS[$s]}"
      done | sort -t: -k2 -rn | tr '\n' ' '
    )"
  fi

  echo ""
  echo "[$title] === Рейтинг стратегий (лучшая -> худшая, только успешные) ==="
  echo "$EXHAUSTIVE_RANKED" | tr ' ' '\n' | grep -v '^$' | nl
  echo ""
  if [ "$EXHAUSTIVE_BEST_STRATEGY" -gt 0 ]; then
    echo "[$title] Победитель: strategy=$EXHAUSTIVE_BEST_STRATEGY ($EXHAUSTIVE_BEST_BYTES байт)"
    for p in $proto_list; do
      set_strategy "$profile" "$p" "$EXHAUSTIVE_BEST_STRATEGY"
    done
  else
    echo "[$title] Ни одна стратегия не прошла проверку, откат к предыдущим значениям"
    for p in $proto_list; do
      if [ -n "${prev[$p]}" ] && [ "${prev[$p]}" != "0" ]; then
        set_strategy "$profile" "$p" "${prev[$p]}"
      fi
    done
  fi
}

# --- реальный URL видеосегмента для профиля Googlevideo ---
# Голый "https://rr1---sn-...googlevideo.com/" (корень, без пути) отдаёт
# страницу 404 на ~1.5КБ — она МЕНЬШЕ любого разумного MIN_BYTES_THRESHOLD
# независимо от стратегии/blob'а/DPI. Байтовый тест на таком URL всегда
# будет "провален", даже если обход работает идеально. Поэтому для профиля 2
# резолвим настоящую ссылку на видеопоток через yt-dlp (--get-url), она
# ведёт на конкретный /videoplayback?... с корректными itag/expire.
DEFAULT_TEST_VIDEO_ID="${DEFAULT_TEST_VIDEO_ID:-dQw4w9WgXcQ}"

# CDN "прилипает" к паре (video_id, наш IP) -- один и тот же ролик с одного
# и того же сервера почти всегда возвращает ОДИН И ТОТ ЖЕ эдж (проверено
# вживую, 6 проходов подряд — один и тот же rr3---sn-...). Живой случай на
# Server A, 2026-08-18: rank_strategies.sh --profile 2 резолвил один и тот же
# DEFAULT_TEST_VIDEO_ID, попал на эдж, который был забанен ещё с утра, и
# все 52 стратегии закономерно провалились разом — не потому что все
# стратегии сломаны, а потому что тест был заперт на одном мёртвом эдже.
# Список общий для TLS-пути (профиль 2, через get_gv_test_url) и
# QUIC-пути (профиль 5, rank_quic.sh) — раньше был продублирован только в
# rank_quic.sh как QUIC_TEST_VIDEO_IDS.
GV_TEST_VIDEO_IDS=(dQw4w9WgXcQ 9bZkp7q19f0 kJQP7kiw5Fk jNQXAC9IVRw 60ItHLz5WEA)

# Детерминированный выбор по индексу (1-based) — для прогонов с несколькими
# проходами, где важно менять видео МЕЖДУ проходами предсказуемо (см.
# rank_quic.sh, теперь и rank_strategies.sh для профиля 2).
gv_pick_video_id() {
  local idx="${1:-1}"
  echo "${GV_TEST_VIDEO_IDS[$(( (idx - 1) % ${#GV_TEST_VIDEO_IDS[@]} ))]}"
}

# Живой случай на Server A, 2026-08-18: у yt-dlp тут нет своего внешнего
# таймаута -- при деградировавшей связности до YouTube (ровно то, что
# профиль 2 время от времени и ловит) внутренние ретраи yt-dlp могут
# растянуться на минуты. Раньше это просто задерживало один шаг общего
# последовательного цикла демона; теперь, когда профиль 2 -- отдельный
# процесс (autotune-profile@2), незамеченный хэнг здесь означает, что ЭТОТ
# health-check не завершится вообще, пока не повезёт с сетью. YT_RESOLVE_TIMEOUT
# ограничивает худший случай явно, вместо неопределённого ожидания.
YT_RESOLVE_TIMEOUT="${YT_RESOLVE_TIMEOUT:-25}"

# Живой инцидент 2026-08-23: yt-dlp без явного --extractor-args извлекал
# через клиент ANDROID_VR (виден в самом URL как c=ANDROID_VR) — googlevideo
# стабильно отдавал 403 именно для НЕГО с этого сервера (датацентровый IP,
# не резидентский), причём даже полноценный даунлоад самим yt-dlp (с его
# собственными, корректными заголовками под этот клиент) получал тот же
# 403 — то есть дело не в недостающих заголовках отдельного curl (это
# проверено и отдельно отклонено), а именно в клиенте. Проверены вживую:
# web/mweb не годятся (на сервере нет JS-раннера для решения sig/n-
# challenge — отдельная, не сетевая проблема), tv — "page needs to be
# reloaded", android — работает чисто (реальный файл, полная скорость).
# Из-за этого ВСЯ методика проверки профиля 2 (health-check,
# rank_strategies.sh, shorts_probe.sh) до этого коммита давала ложный
# 100%-провал независимо от активной стратегии — проблема была не в DPI,
# а в том, каким клиентом yt-dlp резолвил URL.
YT_PLAYER_CLIENT="${YT_PLAYER_CLIENT:-android}"

resolve_googlevideo_url() {
  local video_id="${1:-$DEFAULT_TEST_VIDEO_ID}"
  if ! command -v yt-dlp >/dev/null 2>&1; then
    echo ""
    return 1
  fi
  timeout "$YT_RESOLVE_TIMEOUT" yt-dlp -f 'best[height<=480]' --get-url \
    --extractor-args "youtube:player_client=${YT_PLAYER_CLIENT}" \
    "https://www.youtube.com/watch?v=${video_id}" 2>/dev/null | tail -n1
}

# Возвращает рабочий test_url для профиля 2: реальный googlevideo URL, если
# yt-dlp доступен и резолвинг прошёл успешно; иначе — старый (слабый,
# handshake-only по смыслу, но формально byte-threshold) фолбэк на домен,
# с явным предупреждением в stderr.
#
# $1 (опционально) — конкретный video_id. Без аргумента (обычный
# health-check в autotune_daemon.sh, один вызов за цикл) — выбирает
# СЛУЧАЙНОЕ видео из GV_TEST_VIDEO_IDS каждый раз, а не всегда один и тот
# же DEFAULT_TEST_VIDEO_ID, чтобы не залипать на одном эдже (см. комментарий
# у GV_TEST_VIDEO_IDS выше). Вызывающие, которым нужна предсказуемая
# ротация между несколькими проходами (rank_strategies.sh --profile 2),
# передают явный video_id через gv_pick_video_id().
get_gv_test_url() {
  local video_id="${1:-}"
  if [ -z "$video_id" ]; then
    video_id="${GV_TEST_VIDEO_IDS[RANDOM % ${#GV_TEST_VIDEO_IDS[@]}]}"
  fi
  local url
  url="$(resolve_googlevideo_url "$video_id")"
  if [ -n "$url" ]; then
    echo "$url"
    return 0
  fi
  echo "yt-dlp недоступен или резолвинг не удался (видео $video_id) — использую слабый фолбэк на домен-корень (тест профиля 2 будет ненадёжен, т.к. корень отдаёт 404 на 1.5КБ)." >&2
  echo "https://$(get_yt_cluster_domain)"
}
