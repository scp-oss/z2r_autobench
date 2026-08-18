#!/usr/bin/env bash
# autotune_daemon.sh — фоновая служба автоподстройки стратегий z2r.
#
# ФИЛОСОФИЯ (важно понимать, прежде чем менять параметры): мы эмпирически
# установили за сессию, что среди "рабочих" стратегий разброс в байтах —
# статистический шум (<1-3%), не значимое различие. Полный перебор,
# запускаемый по расписанию и переключающий профиль на "текущего лидера",
# будет дребезжать между статистически неотличимыми вариантами без
# реальной причины (см. пример: 3 дня назад лидер=3, сегодня лидер=7 —
# для одного и того же реального состояния DPI).
#
# Поэтому: НЕ трогаем ничего, пока текущая применённая стратегия проходит
# лёгкий health-check. Полный (дорогой) re-tune запускаем ТОЛЬКО когда
# health-check проваливается N раз ПОДРЯД (защита от единичного сетевого
# блипа) — это прямой аналог automate_failure_counter/standard_failure_detector
# из родного zapret-auto.lua (fails=3 по умолчанию), только на внешнем
# уровне вместо lua.
#
# Профили: 1 YT_TLS, 2 GV_TLS, 3 RKN_TLS, 4 DS_TLS, 5 YT_QUIC_UDP, 6 VOICE_UDP,
# 8 FB_TLS, 9 FB_HTTP. Профиль 7 сюда не входит — нет надёжного автотеста в
# этой топологии сети.
#
# ДВА РЕЖИМА ЗАПУСКА (с 2026-08-18):
#   1) Легаси — без --profile, один процесс по кругу проверяет ВСЕ профили
#      своего набора за один цикл (см. autotune-daemon.service). Раньше это
#      был единственный режим для всех 1/2/3/4/5/8/9 — теперь оставлен ТОЛЬКО
#      для 8/9 (FB_TLS/FB_HTTP, постоянный SKIP_PROFILES) — их и так почти
#      всегда пропускают (см. комментарий у SKIP_PROFILES), возиться с
#      отдельными процессами под них смысла нет. НЕДОСТАТОК этого режима и
#      причина завести второй: дорогой ретюн одного профиля (перебор
#      десятков стратегий, минуты) блокирует health-check ОСТАЛЬНЫХ профилей
#      того же цикла — живой случай 2026-08-18, зависший ретюн GV_TLS не
#      давал вовремя проверяться DS_TLS/RKN_TLS в том же процессе.
#   2) Per-profile — `autotune_daemon.sh --profile N` (N=1..6), поднимается
#      как systemd template-unit `autotune-profile@N.service` — отдельный
#      процесс, отдельный health-check таймер, отдельный лог
#      (autotune_state/daemon_profile_N.log), отдельный файл статуса
#      (autotune_state/status_profile_N.txt). Сам РЕТЮН (перебор стратегий)
#      по-прежнему сериализован через общий TUNE_LOCK_FILE (z2r_autobench_lib.sh)
#      — locked.tsv один файл на все профили, параллельная запись в разные
#      строки всё равно рискует гонкой на уровне файла, поэтому эту часть
#      специально НЕ параллелим, только health-check-цикл.
#      ВАЖНО: GV_TLS (профиль 2) резолвит тестовый URL через yt-dlp против
#      youtube.com — если YT_TLS (профиль 1) сейчас в провале, GV-тест
#      обречён провалиться независимо от собственной стратегии профиля 2.
#      В per-profile режиме процесс профиля 2 перед своим циклом читает
#      failcount_profile_1 (общий, читается напрямую с диска, координации не
#      требует) и пропускает цикл, если у YT_TLS есть непогашенные провалы —
#      чтобы не тратить дорогие ретюны и не путать причину со следствием.
#      VOICE_UDP (профиль 6) тестируется не health-check-запросом к сайту, а
#      через HTTP /probe отдельного z2r_test-voice-bot (песочница Zenith, не
#      боевой /opt/zapret2 — см. z2r_test-voice-bot/README.md), см.
#      check_profile_voice() и rank_voice.sh.
#
# Запуск (напрямую, для отладки):
#   sudo bash autotune_daemon.sh                # легаси, все профили набора
#   sudo bash autotune_daemon.sh --profile 4     # только DS_TLS
# Запуск как служба — см. autotune-daemon.service / autotune-profile@.service.
#
# Настройки через переменные окружения:
#   CHECK_INTERVAL=300       — пауза между циклами health-check, сек
#   FAIL_THRESHOLD=3         — провалов подряд до запуска re-tune
#   RETUNE_PASSES=2          — проходов rank_strategies.sh при re-tune
#   QUIC_CHECK_EVERY=3       — проверять профиль 5 раз в N циклов (дороже TLS)
#   RETUNE_BACKOFF=1800      — после ретюна, который не нашёл НИ ОДНОЙ рабочей
#                              стратегии, не пытаться снова этот профиль
#                              раньше чем через столько секунд (защита от
#                              бесконечного дорогого перебора впустую —
#                              см. историю сессии с FB_TLS/rutracker.org:
#                              тест бил не в тот профиль и молотил вхолостую
#                              каждые несколько минут, пока не заметили)
#   DEPCHECK_EVERY=6         — как часто (в циклах) перепроверять внешние
#                              зависимости (yt-dlp, aioquic) — если появятся
#                              позже, профиль сам вернётся из пропущенных
#   DAEMON_LOG_MAX_BYTES=10485760 — ротация daemon.log при превышении
#   VOICE_PROBE_URL=http://127.0.0.1:8765/probe — HTTP-эндпоинт
#                              z2r_test-voice-bot для health-check/ретюна
#                              профиля 6 (см. check_profile_voice/rank_voice.sh)
#   VOICE_PROBE_TIMEOUT=25    — таймаут на один /probe (connect+hold 5с в
#                              песочнице + запас)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/opt/z2r_autobench/autotune_state"
LOG_DIR="/opt/z2r_autobench/logs"

PROFILE_MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE_MODE="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1 (доступно: --profile N, N=1..6)" >&2; exit 1 ;;
  esac
done
if [ -n "$PROFILE_MODE" ]; then
  case "$PROFILE_MODE" in
    1|2|3|4|5|6) ;;
    *) echo "--profile должен быть 1..6 (7/8/9 — на старом общем демоне без --profile, см. autotune-daemon.service)" >&2; exit 1 ;;
  esac
fi

CHECK_INTERVAL="${CHECK_INTERVAL:-300}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
RETUNE_PASSES="${RETUNE_PASSES:-2}"
QUIC_CHECK_EVERY="${QUIC_CHECK_EVERY:-3}"
RETUNE_BACKOFF="${RETUNE_BACKOFF:-1800}"
DEPCHECK_EVERY="${DEPCHECK_EVERY:-6}"
DAEMON_LOG_MAX_BYTES="${DAEMON_LOG_MAX_BYTES:-10485760}"
VOICE_PROBE_URL="${VOICE_PROBE_URL:-http://127.0.0.1:8765/probe}"
VOICE_PROBE_TIMEOUT="${VOICE_PROBE_TIMEOUT:-25}"
# Профили, которые демон НЕ проверяет и НЕ ретюнит. Актуально ТОЛЬКО для
# легаси-режима (без --profile) — per-profile процессы (--profile N) не
# читают эту переменную вообще, у них включённость решается тем, какие
# systemd-инстансы autotune-profile@N.service вообще запущены. По умолчанию
# 8 и 9 (FB_TLS/FB_HTTP) — их тестовый домен (rutracker.org) уже входит в
# TCP_RKN_list.txt, поэтому тест всегда бьёт не в тот профиль (реальным
# трафиком к rutracker.org управляет профиль 3, а не 8) — до тех пор,
# пока не найдётся домен, не покрытый ни одним курируемым списком, гонять
# ретюн для 8/9 — трата времени и ложные тревоги. Убери из SKIP_PROFILES,
# когда решишь эту проблему (см. test_custom_domain.sh --add-to-rkn как
# альтернативу, или просто новый тестовый домен для case-блока в
# rank_strategies.sh). С переездом 1-6 на per-profile процессы легаси-демону
# следует давать SKIP_PROFILES="1 2 3 4 5 6" (постоянно, через override
# systemd-юнита) — иначе он и per-profile процессы будут дублировать друг
# друга на тех же профилях.
SKIP_PROFILES="${SKIP_PROFILES:-8 9}"

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root." >&2
  exit 1
fi

mkdir -p "$STATE_DIR" "$LOG_DIR"

# Лог и singleton-лок — отдельные на каждый per-profile процесс (иначе 6
# параллельных процессов дерутся за один и тот же daemon.log/лок, и второй
# всегда проигрывает захват). Легаси-режим (без --profile) не меняется.
if [ -n "$PROFILE_MODE" ]; then
  DAEMON_LOG_FILE="$STATE_DIR/daemon_profile_${PROFILE_MODE}.log"
  SINGLETON_LOCK_FILE="$STATE_DIR/daemon.singleton.lock.profile_${PROFILE_MODE}"
else
  DAEMON_LOG_FILE="$STATE_DIR/daemon.log"
  SINGLETON_LOCK_FILE="$STATE_DIR/daemon.singleton.lock"
fi

# --- защита от двух одновременно запущенных демонов ЭТОГО ЖЕ типа/профиля ---
# systemd Restart=on-failure + случайный ручной `bash autotune_daemon.sh`
# поверх уже работающей службы — оба будут независимо считать провалы и
# независимо запускать ретюны, и будут перебивать стратегии друг у друга.
# Неблокирующий захват: если лок уже занят — второй экземпляр сразу выходит,
# а не встаёт в очередь (тут не нужно ждать, тут нужно не запускаться).
exec {DAEMON_LOCK_FD}>"$SINGLETON_LOCK_FILE"
if ! flock -n "$DAEMON_LOCK_FD"; then
  echo "Другой экземпляр autotune_daemon.sh (${PROFILE_MODE:+profile=$PROFILE_MODE, }лок $SINGLETON_LOCK_FILE) уже запущен — выхожу." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

declare -A PROFILE_TITLE=( [1]="YT_TLS" [2]="GV_TLS" [3]="RKN_TLS" [4]="DS_TLS" [5]="YT_QUIC_UDP" [6]="VOICE_UDP" [8]="FB_TLS" [9]="FB_HTTP" )
declare -A PROFILE_PROTO=( [1]="tls http" [2]="tls" [3]="tls" [4]="tls" [5]="udp" [6]="udp" [8]="tls" [9]="http" )
declare -A PROFILE_URL=(
  [1]="https://www.youtube.com/"
  [3]="https://meduza.io"
  [4]="https://discord.com/"
  [8]="https://rutracker.org"
  [9]="http://rutracker.org"
)
# профиль 2 (GV) резолвится динамически через yt-dlp — см. check_profile_tls
# профили 5 (QUIC) и 6 (VOICE_UDP, через z2r_test-voice-bot) — свои функции
# check_profile_quic()/check_profile_voice(), URL им не нужен.

log() {
  local ts
  ts="$(date -Iseconds)"
  echo "[$ts] $*" >> "$DAEMON_LOG_FILE"
  echo "[$ts] $*" >&2
}

# Ротация daemon.log — иначе демон, работающий месяцами, съедает диск сам
# себя, как когда-то было с --debug логом nfqws2 в докер-варианте проекта.
# Простое обрезание хвоста, без logrotate — не хотим тянуть внешнюю
# зависимость ради одного файла.
rotate_daemon_log() {
  local f="$DAEMON_LOG_FILE"
  [ -f "$f" ] || return 0
  local size
  size="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  if [ "$size" -gt "$DAEMON_LOG_MAX_BYTES" ]; then
    tail -c "$((DAEMON_LOG_MAX_BYTES / 2))" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    log "daemon.log превысил ${DAEMON_LOG_MAX_BYTES} байт, обрезан до последней половины лимита"
  fi
}

fail_count_file() { echo "$STATE_DIR/failcount_profile_$1"; }
get_fail_count() { cat "$(fail_count_file "$1")" 2>/dev/null || echo 0; }
set_fail_count() { echo "$2" > "$(fail_count_file "$1")"; }

# --- backoff после ретюна, который не нашёл рабочую стратегию ---
# Если полный перебор (дорогой — десятки запросов, минуты работы) не находит
# НИ ОДНОЙ рабочей стратегии, это почти никогда не "провайдер заблокировал
# всё" — гораздо вероятнее сломан сам тест (см. историю FB_TLS/rutracker.org:
# домен был уже в другом хостлисте, тест бил не туда, 30/30 провалов были
# методологическим артефактом, не реальностью). Без backoff демон честно
# запускал бы тот же дорогой холостой перебор снова через FAIL_THRESHOLD
# циклов — навсегда. Backoff даёт паузу и явно оставляет след в status.txt,
# что этот профиль требует ручного разбора, а не тихо жрёт ресурсы по кругу.
backoff_file() { echo "$STATE_DIR/backoff_until_profile_$1"; }
get_backoff_until() { cat "$(backoff_file "$1")" 2>/dev/null || echo 0; }
set_backoff_until() { echo "$2" > "$(backoff_file "$1")"; }
clear_backoff() { rm -f "$(backoff_file "$1")"; }
in_backoff() { [ "$(get_backoff_until "$1")" -gt "$(date +%s)" ]; }

# Профили, отключённые ВРЕМЕННО из-за отсутствующей внешней зависимости
# (yt-dlp/aioquic), а не по воле оператора. Отдельно от SKIP_PROFILES, чтобы
# в status.txt/логах было видно причину, и чтобы профиль сам вернулся в
# работу, как только зависимость появится — без перезапуска демона.
DEP_SKIP_PROFILES=""

is_user_skipped() {
  case " $SKIP_PROFILES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

is_dep_skipped() {
  case " $DEP_SKIP_PROFILES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

is_skipped() {
  is_user_skipped "$1" || is_dep_skipped "$1"
}

# Проверяет внешние зависимости, от которых зависят тесты профилей 2 (GV_TLS,
# через yt-dlp -> реальный videoplayback URL) и 5 (YT_QUIC_UDP, тот же yt-dlp
# для URL + aioquic для самого QUIC/HTTP-3 запроса). Без yt-dlp get_gv_test_url()
# молча откатывается на голый googlevideo.com/ (404 на 1.5КБ, см. комментарий
# в z2r_autobench_lib.sh) — health-check профиля 2 будет проваливаться ВСЕГДА,
# что бы ни стояло в locked.tsv, демон будет считать это "провайдер блокирует"
# и молотить дорогие ретюны бесконечно вхолостую. Та же ловушка, что была с
# FB_TLS/rutracker.org в этой сессии — только теперь ловим её на старте,
# а не постфактум по логам.
check_dependencies() {
  local new_skip=""

  if ! command -v yt-dlp >/dev/null 2>&1; then
    new_skip="$new_skip 2 5"
    if ! is_dep_skipped "2"; then
      log "ЗАВИСИМОСТЬ: yt-dlp не найден — профили 2 (GV_TLS) и 5 (YT_QUIC_UDP) временно пропускаются (их тест не может резолвить реальный googlevideo URL, без него результат всегда ложно-отрицательный). Установи: pip install yt-dlp --break-system-packages"
    fi
  elif ! python3 -c "import aioquic" >/dev/null 2>&1; then
    new_skip="$new_skip 5"
    if ! is_dep_skipped "5"; then
      log "ЗАВИСИМОСТЬ: пакет aioquic не найден — профиль 5 (YT_QUIC_UDP) временно пропускается. Установи: pip install aioquic --break-system-packages"
    fi
  fi

  # Обратный переход: зависимость появилась — молча возвращаем профиль в
  # работу (следующий health-check сам покажет, реально ли он работает).
  if [ -z "$new_skip" ] && [ -n "$DEP_SKIP_PROFILES" ]; then
    log "ЗАВИСИМОСТИ: yt-dlp/aioquic теперь на месте — возвращаю профили 2/5 в обычную проверку"
  fi

  DEP_SKIP_PROFILES="$new_skip"
}

write_status() {
  # человекочитаемый снимок состояния — можно смотреть `cat status.txt`
  {
    echo "autotune_daemon status @ $(date -Iseconds)"
    echo ""
    for pid in 1 2 3 4 5 8 9; do
      local title="${PROFILE_TITLE[$pid]:-YT_QUIC_UDP}"
      local fc
      fc="$(get_fail_count "$pid")"
      local proto
      if [ "$pid" = "5" ]; then
        proto="udp"
      else
        proto="${PROFILE_PROTO[$pid]%% *}"
      fi
      local cur
      cur="$(orch_locked_get "$pid" "$proto" 2>/dev/null || echo "?")"
      local skip_marker=""
      if is_dep_skipped "$pid"; then
        skip_marker=" (ПРОПУЩЕН: нет зависимости yt-dlp/aioquic)"
      elif is_user_skipped "$pid"; then
        skip_marker=" (ПРОПУЩЕН: SKIP_PROFILES)"
      fi
      local backoff_marker=""
      local until_ts
      until_ts="$(get_backoff_until "$pid")"
      if [ "$until_ts" -gt "$(date +%s)" ]; then
        backoff_marker=" [backoff до $(date -d "@$until_ts" -Iseconds 2>/dev/null || echo "$until_ts")]"
      fi
      echo "  $pid $title: текущая стратегия=$cur, провалов подряд=$fc/$FAIL_THRESHOLD$skip_marker$backoff_marker"
    done
  } > "$STATE_DIR/status.txt"
}

# Аналог write_status(), но на один профиль — для per-profile процессов
# (--profile N), которые ничего не знают о состоянии остальных профилей и
# не должны пытаться писать общий status.txt (гонка между несколькими
# независимыми процессами при записи одного файла). Смотреть все сразу:
# `cat /opt/z2r_autobench/autotune_state/status_profile_*.txt`.
write_status_single() {
  local pid="$1"
  local title="${PROFILE_TITLE[$pid]}"
  local fc
  fc="$(get_fail_count "$pid")"
  local proto="${PROFILE_PROTO[$pid]%% *}"
  local cur
  cur="$(orch_locked_get "$pid" "$proto" 2>/dev/null || echo "?")"
  local backoff_marker=""
  local until_ts
  until_ts="$(get_backoff_until "$pid")"
  if [ "$until_ts" -gt "$(date +%s)" ]; then
    backoff_marker=" [backoff до $(date -d "@$until_ts" -Iseconds 2>/dev/null || echo "$until_ts")]"
  fi
  {
    echo "autotune-profile@$pid ($title) status @ $(date -Iseconds)"
    echo "  $pid $title: текущая стратегия=$cur, провалов подряд=$fc/$FAIL_THRESHOLD$backoff_marker"
  } > "$STATE_DIR/status_profile_$pid.txt"
}

check_profile_tls() {
  local pid="$1"
  local url="${PROFILE_URL[$pid]:-}"
  if [ "$pid" = "2" ]; then
    url="$(get_gv_test_url 2>/dev/null)"
    [ -z "$url" ] && return 1
  fi
  if [ "$pid" = "9" ]; then
    probe_http_url "$url"
  else
    probe_url "$url"
  fi
}

check_profile_quic() {
  local gv_url
  gv_url="$(resolve_googlevideo_url 2>/dev/null)"
  [ -z "$gv_url" ] && return 1
  local host path
  host="$(python3 -c "from urllib.parse import urlsplit; import sys; print(urlsplit(sys.argv[1]).hostname)" "$gv_url")"
  path="$(python3 -c "
from urllib.parse import urlsplit
import sys
u = urlsplit(sys.argv[1])
p = u.path
if u.query:
    p += '?' + u.query
print(p)
" "$gv_url")"
  local bytes
  bytes="$(python3 "$SCRIPT_DIR/quic_probe.py" "$host" "$path" --range-bytes 524288 --timeout 4 2>/dev/null)"
  [ "${bytes:-0}" -ge 524288 ] 2>/dev/null
}

# Профиль 6 (VOICE_UDP) не тестируется curl-запросом к сайту — реальная
# метрика "работает/не работает" это подключение к голосовому каналу
# Discord. z2r_test-voice-bot держит HTTP /probe {"strategy_n": N} именно
# для таких внешних вызовов (изначально сделан для Zenith, см.
# z2r_test-voice-bot/bot.py::handle_probe) — сам достаёт lua-строки текущей
# стратегии из живого /opt/zapret2/config и применяет их ТОЛЬКО в
# изолированной песочнице Zenith (боевой конфиг бот не трогает), заходит в
# тестовый голосовой канал, держит соединение и возвращает {"success",
# "connect_ms"}. Проверяем ИМЕННО ТЕКУЩУЮ закреплённую стратегию профиля 6
# (не перебор) — это и есть health-check, а не ранжирование (для ранжирования
# см. rank_voice.sh, вызывается из retune_profile()).
check_profile_voice() {
  local strategy
  strategy="$(orch_locked_get "6" "udp" 2>/dev/null)"
  if [ -z "$strategy" ] || [ "$strategy" = "0" ]; then
    return 1
  fi
  local resp
  resp="$(curl -sS -X POST "$VOICE_PROBE_URL" -H 'Content-Type: application/json' \
      --max-time "$VOICE_PROBE_TIMEOUT" \
      -d "{\"strategy_n\": $strategy}" 2>/dev/null)"
  [ -z "$resp" ] && return 1
  python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
sys.exit(0 if d.get('success') else 1)
" "$resp"
}

retune_profile() {
  local pid="$1"
  local title="${PROFILE_TITLE[$pid]:-YT_QUIC_UDP}"

  if in_backoff "$pid"; then
    log "RETUNE: profile=$pid ($title) в backoff'е ещё $(( $(get_backoff_until "$pid") - $(date +%s) ))s (прошлый полный перебор не нашёл рабочую стратегию) — пропускаю дорогой ретюн, жду"
    return
  fi

  log "RETUNE: запускаю точечный подбор для профиля $pid ($title), $RETUNE_PASSES проход(ов)"

  local rc=0
  local ordered_file="$LOG_DIR/last_ordered_profile_$pid.txt"
  # Убираем возможный устаревший файл от прошлого прогона — если этот запуск
  # не сможет захватить общий лок (кто-то другой сейчас крутит стратегии) и
  # завершится ошибкой, не хотим по ошибке применить чужой/старый результат.
  rm -f "$ordered_file"

  if [ "$pid" = "5" ]; then
    RETUNE_PASSES_ENV="$RETUNE_PASSES" bash "$SCRIPT_DIR/rank_quic.sh" --passes "$RETUNE_PASSES" --funnel >> "$DAEMON_LOG_FILE" 2>&1 || rc=$?
  elif [ "$pid" = "6" ]; then
    bash "$SCRIPT_DIR/rank_voice.sh" --passes "$RETUNE_PASSES" --funnel >> "$DAEMON_LOG_FILE" 2>&1 || rc=$?
  else
    bash "$SCRIPT_DIR/rank_strategies.sh" --profile "$pid" --passes "$RETUNE_PASSES" --funnel >> "$DAEMON_LOG_FILE" 2>&1 || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    log "RETUNE: profile=$pid ($title) прогон завершился с ошибкой (код=$rc, возможно не смог захватить лок — кто-то другой крутил стратегии) — пробую в следующем цикле, счётчик провалов не сбрасываю"
    return
  fi

  local best
  best="$(awk '{print $1; exit}' "$ordered_file" 2>/dev/null)"

  if [ -n "$best" ]; then
    # rank_strategies.sh сам возвращает locked.tsv на ПРЕЖНЮЮ стратегию в
    # своём конце ("Возврат к исходной стратегии — скрипт только измеряет")
    # ДО того, как мы тут применяем "best" -- живой замер именно этой
    # стратегии мог быть уже несколько минут назад (весь --funnel проход
    # по остальным кандидатам). Не доверяем ранжированию вслепую -- сразу
    # после применения перепроверяем ЖИВЫМ трафиком тем же probe_url/
    # probe_http_url, что и обычный health-check, и откатываем на
    # прежнюю стратегию, если реальная проверка не прошла (найдено при
    # аудите перед деплоем на МТС 2026-08-17 -- тот же класс бага, что
    # уже поймали и починили в Zenith auto_promoter.py: "прошло ранжирование,
    # но не работает вживую" тихо считалось успехом).
    local proto_for_check prev_locked
    if [ "$pid" = "5" ]; then
      proto_for_check="udp"
    else
      proto_for_check="${PROFILE_PROTO[$pid]%% *}"
    fi
    prev_locked="$(orch_locked_get "$pid" "$proto_for_check" 2>/dev/null || echo "")"

    if [ "$pid" = "5" ]; then
      orch_locked_set "5" "udp" "$best"
      if type profile_state_set >/dev/null 2>&1; then
        profile_state_set "5" "udp" "$best" 2>/dev/null || true
      fi
    else
      for p in ${PROFILE_PROTO[$pid]}; do
        set_strategy "$pid" "$p" "$best"
        # Синхронизируем profile.lock (то, что показывает шапка меню z2r) —
        # иначе locked.tsv (реальное поведение) и меню разойдутся, как уже
        # было в этой сессии, и человек будет путаться, глядя на "старую"
        # цифру в меню, хотя реально применена другая, новая стратегия.
        if type profile_state_set >/dev/null 2>&1; then
          profile_state_set "$pid" "$p" "$best" 2>/dev/null || true
        fi
      done
    fi

    local verify_ok=1
    if [ "$pid" = "5" ]; then
      check_profile_quic || verify_ok=0
    elif [ "$pid" = "6" ]; then
      check_profile_voice || verify_ok=0
    else
      check_profile_tls "$pid" || verify_ok=0
    fi

    if [ "$verify_ok" -eq 1 ]; then
      log "RETUNE: применена новая стратегия profile=$pid ($title) strategy=$best (locked.tsv + profile.lock), живая проверка ПОСЛЕ применения пройдена"
      clear_backoff "$pid"
    else
      log "RETUNE: !!! strategy=$best для profile=$pid ($title) прошла funnel-ранжирование, но живая проверка СРАЗУ ПОСЛЕ применения провалилась — откатываю на прежнюю ($prev_locked), ухожу в backoff (не долблю тем же результатом каждый цикл)"
      if [ -n "$prev_locked" ] && [ "$prev_locked" != "?" ]; then
        if [ "$pid" = "5" ]; then
          orch_locked_set "5" "udp" "$prev_locked"
        else
          for p in ${PROFILE_PROTO[$pid]}; do
            set_strategy "$pid" "$p" "$prev_locked"
          done
        fi
      fi
      local until_ts=$(( $(date +%s) + RETUNE_BACKOFF ))
      set_backoff_until "$pid" "$until_ts"
    fi
  else
    # Полный перебор не нашёл НИ ОДНОЙ рабочей стратегии. Почти всегда это
    # означает "тест бьёт не в тот канал/сломан", а не "провайдер заблокировал
    # вообще всё" (см. историю FB_TLS/rutracker.org). Не долбим это дорогим
    # перебором каждые несколько минут — уходим в backoff и явно просим
    # разобраться руками.
    local until_ts=$(( $(date +%s) + RETUNE_BACKOFF ))
    set_backoff_until "$pid" "$until_ts"
    log "RETUNE: !!! не нашлось НИ ОДНОЙ рабочей стратегии для profile=$pid ($title) — уходим в backoff на ${RETUNE_BACKOFF}s, требуется ручной разбор (см. $LOG_DIR/rank_${pid}_*.raw.tsv за этот запуск; частая причина — тестовый URL профиля бьёт не в тот канал, см. z2r_autobench_lib.sh/rank_strategies.sh)"
  fi
  set_fail_count "$pid" 0
}

startup_stability_check() {
  # Лёгкая проверка стабильности на старте — не блокирует запуск, только
  # предупреждает. В сессии был случай, когда процесс падал/пересоздавался
  # каждые ~10с из-за гонки ручных systemctl-команд во время отладки — если
  # это происходит НЕ по нашей вине, лучше узнать сразу в логе, чем гадать
  # постфактум по чужим health-check провалам.
  if ! zapret2_running; then
    log "zapret2 (nfqws2) не запущен на старте — жду и буду перепроверять в цикле."
    return
  fi
  local pid1 pid2
  pid1="$(pidof nfqws2 2>/dev/null | awk '{print $1}')"
  sleep 5
  pid2="$(pidof nfqws2 2>/dev/null | awk '{print $1}')"
  if [ -z "$pid2" ] || [ "$pid1" != "$pid2" ]; then
    log "ВНИМАНИЕ: PID nfqws2 изменился/пропал за 5с на старте ($pid1 -> $pid2) — сервис нестабилен прямо сейчас (не наша операция). Здоровые проверки ниже могут ложно проваливаться, пока это не уляжется."
  fi
}

run_legacy_daemon() {
  startup_stability_check
  check_dependencies

  log "autotune_daemon.sh запущен. Профили: 1 2 3 4 5 8 9 (кроме user-skip=$SKIP_PROFILES, dep-skip=${DEP_SKIP_PROFILES:-нет}). CHECK_INTERVAL=${CHECK_INTERVAL}s FAIL_THRESHOLD=${FAIL_THRESHOLD} RETUNE_BACKOFF=${RETUNE_BACKOFF}s"

  local cycle=0
  while true; do
    cycle=$((cycle + 1))

    rotate_daemon_log
    if (( cycle % DEPCHECK_EVERY == 0 )); then
      check_dependencies
    fi

    if ! zapret2_running; then
      log "zapret2 не запущен, пропускаю цикл проверки."
      sleep "$CHECK_INTERVAL"
      continue
    fi

    for pid in 1 2 3 4 8 9; do
      is_skipped "$pid" && continue
      local fc
      if check_profile_tls "$pid"; then
        if [ "$(get_fail_count "$pid")" != "0" ]; then
          log "OK: profile=$pid (${PROFILE_TITLE[$pid]}) снова работает, сбрасываю счётчик провалов"
        fi
        set_fail_count "$pid" 0
      else
        fc=$(( $(get_fail_count "$pid") + 1 ))
        set_fail_count "$pid" "$fc"
        log "PROBLEM: profile=$pid (${PROFILE_TITLE[$pid]}) провал health-check ($fc/$FAIL_THRESHOLD)"
        if [ "$fc" -ge "$FAIL_THRESHOLD" ]; then
          retune_profile "$pid"
        fi
      fi
    done

    if (( cycle % QUIC_CHECK_EVERY == 0 )) && ! is_skipped "5"; then
      local fc5
      if check_profile_quic; then
        if [ "$(get_fail_count "5")" != "0" ]; then
          log "OK: profile=5 (YT_QUIC_UDP) снова работает, сбрасываю счётчик провалов"
        fi
        set_fail_count "5" 0
      else
        fc5=$(( $(get_fail_count "5") + 1 ))
        set_fail_count "5" "$fc5"
        log "PROBLEM: profile=5 (YT_QUIC_UDP) провал health-check ($fc5/$FAIL_THRESHOLD)"
        if [ "$fc5" -ge "$FAIL_THRESHOLD" ]; then
          retune_profile "5"
        fi
      fi
    fi

    write_status
    sleep "$CHECK_INTERVAL"
  done
}

# Per-profile режим (--profile N, N=1..6) — см. докстринг файла. Каждый
# профиль в своём процессе, свой health-check таймер; ретюн (перебор
# стратегий) по-прежнему сериализован через общий TUNE_LOCK_FILE внутри
# rank_strategies.sh/rank_quic.sh/rank_voice.sh, тут отдельно ничего не
# синхронизируем.
run_profile_daemon() {
  local pid="$1"
  local title="${PROFILE_TITLE[$pid]}"

  startup_stability_check
  check_dependencies

  log "autotune_daemon.sh --profile $pid ($title) запущен. CHECK_INTERVAL=${CHECK_INTERVAL}s FAIL_THRESHOLD=${FAIL_THRESHOLD} RETUNE_BACKOFF=${RETUNE_BACKOFF}s"

  local cycle=0
  while true; do
    cycle=$((cycle + 1))

    rotate_daemon_log
    if (( cycle % DEPCHECK_EVERY == 0 )); then
      check_dependencies
    fi

    if ! zapret2_running; then
      log "zapret2 не запущен, пропускаю цикл проверки."
      sleep "$CHECK_INTERVAL"
      continue
    fi

    if is_dep_skipped "$pid"; then
      sleep "$CHECK_INTERVAL"
      continue
    fi

    # GV_TLS зависит от YT_TLS: get_gv_test_url()/resolve_googlevideo_url()
    # резолвят реальный videoplayback URL через yt-dlp против youtube.com —
    # если сам YT_TLS (профиль 1) сейчас в провале, GV-тест обречён
    # провалиться независимо от собственной стратегии профиля 2. Не хотим
    # тратить дорогие ретюны и ложно винить GV_TLS, пока не восстановится
    # YT_TLS — читаем его failcount напрямую (файл общий, координации не
    # требует, независимо от того, каким процессом он поддерживается).
    if [ "$pid" = "2" ] && [ "$(get_fail_count "1")" != "0" ]; then
      log "PROPUSK: profile=2 (GV_TLS) — у YT_TLS (профиль 1) есть непогашенные провалы, GV-тест от него зависит — жду восстановления YT_TLS"
      write_status_single "$pid"
      sleep "$CHECK_INTERVAL"
      continue
    fi

    local ok=1
    case "$pid" in
      5) check_profile_quic || ok=0 ;;
      6) check_profile_voice || ok=0 ;;
      *) check_profile_tls "$pid" || ok=0 ;;
    esac

    if [ "$ok" = "1" ]; then
      if [ "$(get_fail_count "$pid")" != "0" ]; then
        log "OK: profile=$pid ($title) снова работает, сбрасываю счётчик провалов"
      fi
      set_fail_count "$pid" 0
    else
      local fc
      fc=$(( $(get_fail_count "$pid") + 1 ))
      set_fail_count "$pid" "$fc"
      log "PROBLEM: profile=$pid ($title) провал health-check ($fc/$FAIL_THRESHOLD)"
      if [ "$fc" -ge "$FAIL_THRESHOLD" ]; then
        retune_profile "$pid"
      fi
    fi

    write_status_single "$pid"
    sleep "$CHECK_INTERVAL"
  done
}

if [ -n "$PROFILE_MODE" ]; then
  run_profile_daemon "$PROFILE_MODE"
else
  run_legacy_daemon
fi
