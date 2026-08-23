#!/usr/bin/env bash
# quic_tune.sh — перебор стратегий для профиля 5 (UDP 443, YouTube QUIC).
# БЕЗ рестарта nfqws2 (тот же TSV-механизм locked.lua, что и у TCP-профилей).
# Использует quic_probe.py (aioquic) вместо curl, т.к. обычная сборка curl
# не поддерживает HTTP/3.
#
# ПЕРЕД ПЕРВЫМ ЗАПУСКОМ ОБЯЗАТЕЛЬНО СДЕЛАЙ SELF-TEST (см. ниже в выводе) —
# скрипт не был протестирован против реального YouTube/googlevideo.
#
# Запуск: sudo ./quic_tune.sh [--budget SEC] [--settle SEC] [--range-bytes N] [--timeout SEC]

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/opt/z2r_autobench/logs"
NIGHT_BUDGET_SECONDS="${NIGHT_BUDGET_SECONDS:-600}"
SETTLE_SECONDS="${SETTLE_SECONDS:-3}"
RANGE_BYTES="${RANGE_BYTES:-524288}"
QUIC_TIMEOUT="${QUIC_TIMEOUT:-4}"

while [ $# -gt 0 ]; do
  case "$1" in
    --budget) NIGHT_BUDGET_SECONDS="$2"; shift 2 ;;
    --settle) SETTLE_SECONDS="$2"; shift 2 ;;
    --range-bytes) RANGE_BYTES="$2"; shift 2 ;;
    --timeout) QUIC_TIMEOUT="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root." >&2
  exit 1
fi

if ! python3 -c "import aioquic" >/dev/null 2>&1; then
  echo "Не найден пакет aioquic. Установи: pip install aioquic --break-system-packages" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

if ! zapret2_running; then
  echo "zapret2 (nfqws2) не запущен." >&2
  exit 1
fi

acquire_tune_lock "quic_tune.sh" 10 || exit 1

echo "=== SELF-TEST: проверка, что quic_probe.py вообще способен провести QUIC/HTTP-3 handshake ==="
echo "Пробуем публичный HTTP/3-сайт (cloudflare-quic.com), НЕ через zapret2-фильтруемый профиль —"
echo "это только проверка механики скрипта, а не обхода DPI."
self_test_bytes="$(python3 "$SCRIPT_DIR/quic_probe.py" cloudflare-quic.com / --range-bytes 8192 --timeout 5 2>&1)"
self_test_rc=$?
echo "$self_test_bytes"
if [ "$self_test_rc" -ne 0 ]; then
  echo ""
  echo "ВНИМАНИЕ: self-test не прошёл. Это может означать:"
  echo "  - на сервере нет исходящего UDP/443 вообще (файрвол?)"
  echo "  - сам cloudflare-quic.com недоступен из твоей сети"
  echo "  - баг в quic_probe.py (сверься со stderr выше)"
  echo "Прежде чем продолжать тюнинг профиля 5, разберись с этим — иначе результаты тюнинга"
  echo "будут ложноотрицательными независимо от реальных стратегий z2r."
  read -re -p "Продолжить всё равно? (не рекомендуется) [y/N]: " force_continue
  [ "$force_continue" = "y" ] || exit 1
fi
echo "=== self-test пройден, продолжаю ==="
echo ""

mkdir -p "$LOG_DIR"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/quic_tune_${RUN_TS}.tsv"
echo -e "ts\tprofile\tstrategy\tattempt\tbytes\tsuccess\tnote" > "$LOG_FILE"

autobench_backup_locks "$RUN_TS"

echo "Резолвлю реальный googlevideo videoplayback URL через yt-dlp..."
GV_URL="$(resolve_googlevideo_url)"
if [ -z "$GV_URL" ]; then
  echo "Не удалось получить URL через yt-dlp (см. предыдущее обсуждение — нужен установленный yt-dlp)." >&2
  exit 1
fi
GV_HOST="$(python3 -c "from urllib.parse import urlsplit; import sys; print(urlsplit(sys.argv[1]).hostname)" "$GV_URL")"
GV_PATH="$(python3 -c "
from urllib.parse import urlsplit
import sys
u = urlsplit(sys.argv[1])
p = u.path
if u.query:
    p += '?' + u.query
print(p)
" "$GV_URL")"
echo "Хост: $GV_HOST"
echo "Путь: ${GV_PATH:0:80}..."

PROFILE="5"
PROTO="udp"

max_strat="$(config_profile_max_strategy "$PROFILE" "")"
if [ -z "$max_strat" ] || [ "$max_strat" -le 0 ]; then
  echo "Не удалось определить число стратегий для профиля $PROFILE." >&2
  exit 1
fi

prev_strategy="$(orch_locked_get "$PROFILE" "$PROTO")"
echo "Текущая стратегия профиля $PROFILE (proto=$PROTO): ${prev_strategy:-auto}"
echo "Перебор: 1..$max_strat"

start_ts=$(date +%s)
found=0
for ((s=1; s<=max_strat; s++)); do
  now=$(date +%s)
  if [ $((now - start_ts)) -gt "$NIGHT_BUDGET_SECONDS" ]; then
    echo "Исчерпан бюджет времени, останавливаюсь на strategy=$s"
    break
  fi

  orch_locked_set "$PROFILE" "$PROTO" "$s"
  sleep "$SETTLE_SECONDS"

  bytes_received="$(python3 "$SCRIPT_DIR/quic_probe.py" "$GV_HOST" "$GV_PATH" \
      --range-bytes "$RANGE_BYTES" --timeout "$QUIC_TIMEOUT" 2>>"$LOG_DIR/quic_tune_${RUN_TS}.stderr.log")"
  rc=$?
  success=0
  if [ "$rc" -eq 0 ] && [ "${bytes_received:-0}" -ge "$RANGE_BYTES" ] 2>/dev/null; then
    success=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds)" "$PROFILE" "$s" "1" "${bytes_received:-0}" "$success" "-" >> "$LOG_FILE"

  echo "strategy=$s bytes=${bytes_received:-0} success=$success"

  if [ "$success" -eq 1 ]; then
    echo "Рабочая стратегия найдена: $s"
    found=1
    break
  fi
done

if [ "$found" -eq 0 ]; then
  echo "Рабочая стратегия не найдена за 1..$max_strat, откатываюсь на предыдущую (${prev_strategy:-auto})"
  if [ -n "$prev_strategy" ] && [ "$prev_strategy" != "0" ]; then
    orch_locked_set "$PROFILE" "$PROTO" "$prev_strategy"
  else
    orch_locked_clear "$PROFILE" "$PROTO"
  fi
fi

echo ""
echo "=== Итог ==="
echo "locked.tsv (профиль 5):"
grep -P "^5\t" "$ORCH_DIR/locked.tsv" 2>/dev/null || echo "(нет записи — auto)"
echo "Лог попыток: $LOG_FILE"
echo "Лог ошибок quic_probe.py (если были): $LOG_DIR/quic_tune_${RUN_TS}.stderr.log"
