#!/usr/bin/env bash
# blob_tune.sh — цикл B: перебор TLS ClientHello blob'ов + подбор стратегий
# на каждом. ДОРОГОЙ цикл: каждая смена blob требует рестарта nfqws2
# (в отличие от locked.tsv, blob зашит в аргументы запуска процесса).
# Гонять редко (раз в несколько дней / по требованию), не каждую ночь,
# и не в моменты, когда кто-то реально смотрит видео — рестарт рвёт
# активные соединения на 1-2 сек.
#
# Логика смены blob скопирована (не изменена) из menu_action_set_tls_blob()
# в /opt/zapret2/z2r_lib/actions.sh — просто без интерактивного read.
#
# Запуск: sudo ./blob_tune.sh [--candidates "file1.bin,file2.bin,..."]
#                              [--profiles 1,2] [--per-blob-budget SEC]

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/z2r_autobench/logs"
FAKE_DIR="/opt/zapret2/files/fake"
CFG="/opt/zapret2/config"
ZAPRET2_INIT="/opt/zapret2/init.d/sysv/zapret2"
RESTART_SETTLE_SECONDS="${RESTART_SETTLE_SECONDS:-8}"
PER_BLOB_BUDGET="${PER_BLOB_BUDGET:-300}"     # бюджет NIGHT_BUDGET_SECONDS на подбор стратегий для одного blob
PROFILES_FILTER="1,2"                          # по умолчанию тестируем только самые blob-чувствительные

# Курируемый список кандидатов — НЕ все 111 файлов. Сознательно ограничен,
# т.к. каждый кандидат стоит одного рестарта nfqws2. Правь под себя.
DEFAULT_CANDIDATES="tls_clienthello_www_google_com.bin,tls_clienthello_max_ru.bin,tls_clienthello_chat_deepseek_com.bin,fake_tls_1.bin,fake_tls_4.bin,tls_clienthello_vk_com.bin"
CANDIDATES="$DEFAULT_CANDIDATES"

while [ $# -gt 0 ]; do
  case "$1" in
    --candidates) CANDIDATES="$2"; shift 2 ;;
    --profiles) PROFILES_FILTER="$2"; shift 2 ;;
    --per-blob-budget) PER_BLOB_BUDGET="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

# blob_tune.sh рестартует nfqws2 и параллельно крутит стратегии через
# tune_profile() — если в этот момент демон или другой ручной прогон тоже
# полезет менять locked.tsv/config, результат будет мусорным. Держим лок
# на весь прогон (он и так редкий/ручной, ждать 10с не страшно).
acquire_tune_lock "blob_tune.sh" 10 || exit 1

mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/blob_tune_${RUN_TS}.tsv"
SUMMARY_FILE="$LOG_DIR/blob_tune_${RUN_TS}.summary.tsv"
echo -e "ts\tprofile\ttitle\tproto\tstrategy\tattempt\ttls12_ok\ttls13_ok\tsuccess\tnote" > "$LOG_FILE"
echo -e "blob\tprofile\tsuccess\tstrategy\tbytes" > "$SUMMARY_FILE"

# --- бэкап конфига целиком (не только locked.tsv — тут меняется сам config) ---
CFG_BACKUP_DIR="/opt/zapret2/extra_strats/cache/orchestra/config_backups"
mkdir -p "$CFG_BACKUP_DIR"
cp -p "$CFG" "$CFG_BACKUP_DIR/config.${RUN_TS}.bak"
echo "Бэкап config сохранён: $CFG_BACKUP_DIR/config.${RUN_TS}.bak"
autobench_backup_locks "$RUN_TS"

CURRENT_BLOB_FILE="$(sed -n -E 's#.*--blob=maxru:@/opt/zapret2/files/fake/([^[:space:]]+).*#\1#p' "$CFG" | head -n1)"
echo "Исходный blob: ${CURRENT_BLOB_FILE:-неизвестен}"

sed_ereg="$(config_sed_ereg)"

# Неинтерактивный аналог menu_action_set_tls_blob(): переключает режим на maxru
# (если сейчас fake_default_tls) и подставляет нужный файл.
apply_blob() {
  local blob_file="$1"
  local prefix="--blob=maxru:@/opt/zapret2/files/fake/"

  if [ ! -f "$FAKE_DIR/$blob_file" ]; then
    echo "Файл $FAKE_DIR/$blob_file не найден, пропуск." >&2
    return 1
  fi

  sed -i $sed_ereg '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)fake_default_tls#\1maxru#g; }' "$CFG"
  sed -i $sed_ereg "s#(${prefix})[^[:space:]]+#\\1${blob_file}#g" "$CFG"
}

restart_zapret2() {
  "$ZAPRET2_INIT" stop >/dev/null 2>&1 || true
  sleep 1
  if pidof nfqws2 >/dev/null; then
    pkill -9 nfqws2 2>/dev/null || true
    sleep 1
  fi
  "$ZAPRET2_INIT" start
  sleep "$RESTART_SETTLE_SECONDS"

  # run_daemon() в /opt/zapret2/init.d/sysv/functions форкает nfqws2 и сразу
  # считает старт успешным, не проверяя, что процесс реально пережил запуск
  # (гонка: если старый процесс ещё не освободил NFQUEUE qnum=300, новый
  # молча падает при биндинге, а pidfile всё равно пишется). Раз мы этот
  # файл не трогаем (не наш, обновляется поверх нас), подстраховываемся
  # тут: если nfqws2 не поднялся с первого раза — пробуем ещё раз.
  if ! pidof nfqws2 >/dev/null; then
    echo "restart_zapret2: nfqws2 не поднялся после start, пробую ещё раз" >&2
    "$ZAPRET2_INIT" start
    sleep "$RESTART_SETTLE_SECONDS"
    if ! pidof nfqws2 >/dev/null; then
      echo "restart_zapret2: nfqws2 не поднялся и со второй попытки" >&2
      return 1
    fi
  fi
}

# профиль_id title proto_list url is_http (подмножество PROFILE_DEFS из night_tune.sh)
declare -A PDEF_TITLE=( [1]="YT_TLS/HTTP" [2]="Googlevideo_TLS" [3]="RKN_TLS" )
declare -A PDEF_PROTO=( [1]="tls http" [2]="tls" [3]="tls" )
declare -A PDEF_HTTP=( [1]=0 [2]=0 [3]=0 )
PDEF_URL_1="https://www.youtube.com/"
PDEF_URL_2="$(get_gv_test_url)"
PDEF_URL_3="https://meduza.io"

profile_selected() {
  local pid="$1"
  case ",$PROFILES_FILTER," in
    *",$pid,"*) return 0 ;;
    *) return 1 ;;
  esac
}

score_blob() {
  # Результат кладёт в глобальную BLOB_SCORE, а не возвращает через stdout —
  # иначе весь диагностический echo из tune_profile() тоже попал бы в
  # $(...) при захвате результата, ломая арифметику.
  local total=0
  local pid
  for pid in 1 2 3; do
    profile_selected "$pid" || continue
    local url_var="PDEF_URL_${pid}"
    tune_profile "$pid" "${PDEF_TITLE[$pid]}" "${PDEF_PROTO[$pid]}" "${!url_var}" "${PDEF_HTTP[$pid]}" "$LOG_FILE"
    echo -e "${CURRENT_CANDIDATE}\t${pid}\t${TUNE_RESULT_SUCCESS}\t${TUNE_RESULT_STRATEGY}\t${TUNE_RESULT_BYTES}" >> "$SUMMARY_FILE"
    total=$(( total + TUNE_RESULT_SUCCESS * 1000000 + TUNE_RESULT_BYTES ))
  done
  BLOB_SCORE="$total"
}

echo "=== blob_tune.sh: старт $(date) ==="
echo "Кандидаты: $CANDIDATES"
echo "Профили для оценки: $PROFILES_FILTER"
echo "ВНИМАНИЕ: каждый кандидат = 1 рестарт zapret2 (обрыв активных соединений на ~1-2 сек)."
echo ""

# --- baseline: текущий blob (для честного сравнения "стало лучше или нет") ---
echo "--- Baseline: текущий blob (${CURRENT_BLOB_FILE:-?}) ---"
NIGHT_BUDGET_SECONDS="$PER_BLOB_BUDGET"
CURRENT_CANDIDATE="__baseline__(${CURRENT_BLOB_FILE:-unknown})"
score_blob
BASELINE_SCORE="$BLOB_SCORE"
echo "Baseline score: $BASELINE_SCORE"
BEST_SCORE="$BASELINE_SCORE"
BEST_BLOB=""   # пусто = остаться на baseline

IFS=',' read -r -a CAND_ARR <<< "$CANDIDATES"
for blob in "${CAND_ARR[@]}"; do
  [ -n "$blob" ] || continue
  if [ "$blob" = "$CURRENT_BLOB_FILE" ]; then
    echo "--- Пропуск $blob: совпадает с baseline ---"
    continue
  fi
  echo "--- Кандидат: $blob ---"
  if ! apply_blob "$blob"; then
    continue
  fi
  restart_zapret2
  if ! zapret2_running; then
    echo "zapret2 не поднялся после рестарта с blob=$blob, пропуск кандидата." >&2
    continue
  fi
  CURRENT_CANDIDATE="$blob"
  NIGHT_BUDGET_SECONDS="$PER_BLOB_BUDGET"
  score_blob
  score="$BLOB_SCORE"
  echo "Score для $blob: $score"
  if [ "$score" -gt "$BEST_SCORE" ]; then
    BEST_SCORE="$score"
    BEST_BLOB="$blob"
  fi
done

echo ""
echo "=== Итог перебора blob'ов ==="
if [ -n "$BEST_BLOB" ]; then
  echo "Лучший найден: $BEST_BLOB (score=$BEST_SCORE, baseline=$BASELINE_SCORE)"
  echo "Применяю и оставляю его."
  apply_blob "$BEST_BLOB"
  restart_zapret2
  # В отличие от основного цикла перебора выше (строки 174-178), этот
  # финальный restart раньше не проверялся вообще -- если он падал на том
  # же документированном qnum-race (см. restart_zapret2()), скрипт тихо
  # шёл дальше в score_blob() как ни в чём не бывало, оставляя прод БЕЗ
  # запущенного nfqws2 и без отката к backup, снятому в начале прогона
  # (найдено при аудите перед деплоем на МТС 2026-08-17).
  if ! zapret2_running; then
    echo "!!! zapret2 не поднялся после финального применения $BEST_BLOB -- откатываюсь на backup ($CFG_BACKUP_DIR/config.${RUN_TS}.bak)." >&2
    cp -p "$CFG_BACKUP_DIR/config.${RUN_TS}.bak" "$CFG"
    restart_zapret2
    if ! zapret2_running; then
      echo "!!! zapret2 не поднялся даже после отката на backup -- нужно вмешательство человека." >&2
    fi
  else
    # финальный дозор стратегиями уже сделан внутри score_blob() для победителя,
    # но т.к. мы перебирали кандидатов по порядку, а не переоценивали победителя
    # последним — прогоняем ещё раз для гарантии актуальных locked.tsv.
    NIGHT_BUDGET_SECONDS="$PER_BLOB_BUDGET"
    CURRENT_CANDIDATE="$BEST_BLOB(final)"
    score_blob
  fi
else
  echo "Ни один кандидат не превзошёл baseline (${CURRENT_BLOB_FILE:-?}, score=$BASELINE_SCORE). Откатываюсь."
  cp -p "$CFG_BACKUP_DIR/config.${RUN_TS}.bak" "$CFG"
  restart_zapret2
fi

echo "Итоговый blob в конфиге:"
sed -n -E 's#.*--blob=maxru:@/opt/zapret2/files/fake/([^[:space:]]+).*#\1#p' "$CFG" | head -n1
echo "Сводка по кандидатам: $SUMMARY_FILE"
echo "Полный лог попыток: $LOG_FILE"
