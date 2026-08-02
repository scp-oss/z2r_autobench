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
# Профили: 1 YT_TLS, 2 GV_TLS, 3 RKN_TLS, 4 DS_TLS, 5 YT_QUIC_UDP (реже,
# дороже), 8 FB_TLS, 9 FB_HTTP. Профили 6/7 сюда не входят — мы установили
# ранее, что для них нет надёжного автотеста в этой топологии сети.
#
# Запуск (напрямую, для отладки):
#   sudo bash autotune_daemon.sh
# Запуск как служба — см. autotune-daemon.service ниже в этом же комплекте.
#
# Настройки через переменные окружения:
#   CHECK_INTERVAL=300       — пауза между циклами health-check, сек
#   FAIL_THRESHOLD=3         — провалов подряд до запуска re-tune
#   RETUNE_PASSES=2          — проходов rank_strategies.sh при re-tune
#   QUIC_CHECK_EVERY=3       — проверять профиль 5 раз в N циклов (дороже TLS)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/opt/z2r_autobench/autotune_state"
LOG_DIR="/opt/z2r_autobench/logs"

CHECK_INTERVAL="${CHECK_INTERVAL:-300}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
RETUNE_PASSES="${RETUNE_PASSES:-2}"
QUIC_CHECK_EVERY="${QUIC_CHECK_EVERY:-3}"
# Профили, которые демон НЕ проверяет и НЕ ретюнит. По умолчанию 8 и 9
# (FB_TLS/FB_HTTP) — их тестовый домен (rutracker.org) уже входит в
# TCP_RKN_list.txt, поэтому тест всегда бьёт не в тот профиль (реальным
# трафиком к rutracker.org управляет профиль 3, а не 8) — до тех пор,
# пока не найдётся домен, не покрытый ни одним курируемым списком, гонять
# ретюн для 8/9 — трата времени и ложные тревоги. Убери из SKIP_PROFILES,
# когда решишь эту проблему (см. test_custom_domain.sh --add-to-rkn как
# альтернативу, или просто новый тестовый домен для case-блока в
# rank_strategies.sh).
SKIP_PROFILES="${SKIP_PROFILES:-8 9}"

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root." >&2
  exit 1
fi

mkdir -p "$STATE_DIR" "$LOG_DIR"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

declare -A PROFILE_TITLE=( [1]="YT_TLS" [2]="GV_TLS" [3]="RKN_TLS" [4]="DS_TLS" [8]="FB_TLS" [9]="FB_HTTP" )
declare -A PROFILE_PROTO=( [1]="tls http" [2]="tls" [3]="tls" [4]="tls" [8]="tls" [9]="http" )
declare -A PROFILE_URL=(
  [1]="https://www.youtube.com/"
  [3]="https://meduza.io"
  [4]="https://discord.com/"
  [8]="https://rutracker.org"
  [9]="http://rutracker.org"
)
# профиль 2 (GV) резолвится динамически через yt-dlp — см. check_profile_tls

log() {
  echo "[$(date -Iseconds)] $*" | tee -a "$STATE_DIR/daemon.log" >&2
}

fail_count_file() { echo "$STATE_DIR/failcount_profile_$1"; }
get_fail_count() { cat "$(fail_count_file "$1")" 2>/dev/null || echo 0; }
set_fail_count() { echo "$2" > "$(fail_count_file "$1")"; }

is_skipped() {
  case " $SKIP_PROFILES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
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
      is_skipped "$pid" && skip_marker=" (ПРОПУЩЕН, не проверяется)"
      echo "  $pid $title: текущая стратегия=$cur, провалов подряд=$fc/$FAIL_THRESHOLD$skip_marker"
    done
  } > "$STATE_DIR/status.txt"
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

retune_profile() {
  local pid="$1"
  local title="${PROFILE_TITLE[$pid]:-YT_QUIC_UDP}"
  log "RETUNE: запускаю точечный подбор для профиля $pid ($title), $RETUNE_PASSES проход(ов)"

  if [ "$pid" = "5" ]; then
    RETUNE_PASSES_ENV="$RETUNE_PASSES" bash "$SCRIPT_DIR/rank_quic.sh" --passes "$RETUNE_PASSES" >> "$STATE_DIR/daemon.log" 2>&1
  else
    bash "$SCRIPT_DIR/rank_strategies.sh" --profile "$pid" --passes "$RETUNE_PASSES" >> "$STATE_DIR/daemon.log" 2>&1
  fi

  local ordered_file="$LOG_DIR/last_ordered_profile_$pid.txt"
  local best
  best="$(cat "$ordered_file" 2>/dev/null | awk '{print $1}')"

  if [ -n "$best" ]; then
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
    log "RETUNE: применена новая стратегия profile=$pid ($title) strategy=$best (locked.tsv + profile.lock)"
  else
    log "RETUNE: !!! не нашлось НИ ОДНОЙ рабочей стратегии для profile=$pid ($title) — требуется ручное вмешательство"
  fi
  set_fail_count "$pid" 0
}

if ! zapret2_running; then
  log "zapret2 (nfqws2) не запущен на старте — жду и буду перепроверять в цикле."
fi

log "autotune_daemon.sh запущен. Профили: 1 2 3 4 5 8 9. CHECK_INTERVAL=${CHECK_INTERVAL}s FAIL_THRESHOLD=${FAIL_THRESHOLD}"

cycle=0
while true; do
  cycle=$((cycle + 1))

  if ! zapret2_running; then
    log "zapret2 не запущен, пропускаю цикл проверки."
    sleep "$CHECK_INTERVAL"
    continue
  fi

  for pid in 1 2 3 4 8 9; do
    is_skipped "$pid" && continue
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
    if check_profile_quic; then
      if [ "$(get_fail_count "5")" != "0" ]; then
        log "OK: profile=5 (YT_QUIC_UDP) снова работает, сбрасываю счётчик провалов"
      fi
      set_fail_count "5" 0
    else
      fc=$(( $(get_fail_count "5") + 1 ))
      set_fail_count "5" "$fc"
      log "PROBLEM: profile=5 (YT_QUIC_UDP) провал health-check ($fc/$FAIL_THRESHOLD)"
      if [ "$fc" -ge "$FAIL_THRESHOLD" ]; then
        retune_profile "5"
      fi
    fi
  fi

  write_status
  sleep "$CHECK_INTERVAL"
done
