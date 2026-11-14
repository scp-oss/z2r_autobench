#!/usr/bin/env bash
# voice_region_sweep.sh — периодический прогон ЖИВОЙ стратегии VOICE_UDP
# (профиль 6, из locked.tsv) по всем 13 голосовым каналам «CDN <регион>»
# Discord через z2r_test-voice-bot /probe (rank_voice_regions.sh --json).
#
# Зачем: autotune-daemon и раунды Zenith проверяют голос только в «CDN Auto»,
# регионы раньше смотрел лишь zenith-promoter при продвижении (он выключен).
# Этот прогон ничего не ретюнит и не продвигает — только показывает, где
# живая стратегия работает:
#   logs/voice_regions.json            — последний прогон (его читает бот для 6ч-сводки)
#   logs/voice_regions_history.jsonl   — история, по строке на прогон
#   центральная БД, таблица voice_region_checks (через Zenith db.py:
#   docker -> MySQL, api -> панель), если Zenith установлен.
#
# Запускается таймером voice-region-sweep.timer (раз в 6 ч); вручную:
#   sudo /opt/z2r_autobench/voice_region_sweep.sh [--strategy N]
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
OUT="$LOG_DIR/voice_regions.json"
HIST="$LOG_DIR/voice_regions_history.jsonl"
ZENITH_ORCH="${ZENITH_ORCH:-$SCRIPT_DIR/Zenith/orchestrator}"

mkdir -p "$LOG_DIR"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

"$SCRIPT_DIR/rank_voice_regions.sh" --json "$tmp" "$@" || { echo "voice_region_sweep: rank_voice_regions.sh завершился с ошибкой" >&2; exit 1; }

# Если бот недоступен, все регионы будут "?" -- такой прогон не пишем,
# иначе в сводке/БД появится ложное «0 из 13».
known="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for r in d["results"] if r["success"] is not None))' "$tmp" 2>/dev/null || echo 0)"
if [ "${known:-0}" -eq 0 ]; then
  echo "voice_region_sweep: ни одного ответа от /probe (бот не запущен?) -- результат не сохраняю" >&2
  exit 1
fi

install -m 644 "$tmp" "$OUT"
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), ensure_ascii=False))' "$OUT" >> "$HIST"
python3 - "$OUT" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1])); r = d["results"]
ok = [x["region"] for x in r if x["success"]]
bad = [x["region"] for x in r if x["success"] is False]
print("voice_region_sweep: strategy=%s ok %d/%d; падают: %s" % (d.get("strategy"), len(ok), len(r), ", ".join(bad) or "-"))
PYEOF

if [ -x "$ZENITH_ORCH/venv/bin/python" ]; then
  ( cd "$ZENITH_ORCH" && venv/bin/python record_voice_regions.py "$OUT" ) \
    || echo "voice_region_sweep: запись в БД не удалась (результат есть в $OUT)" >&2
else
  echo "voice_region_sweep: Zenith не установлен -- в БД не пишу (результат в $OUT)"
fi
