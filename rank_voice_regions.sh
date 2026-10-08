#!/usr/bin/env bash
# rank_voice_regions.sh — проверяет ОДНУ заданную стратегию профиля 6
# (VOICE_UDP) по очереди во ВСЕХ голосовых регионах Discord, через тот же
# POST /probe, что и rank_voice.sh, только с новым полем "region" (см.
# handle_probe в z2r_test-voice-bot/bot.py, добавлено 2026-10-08).
#
# ПОЧЕМУ ОТДЕЛЬНЫЙ СКРИПТ, А НЕ ещё одно измерение в rank_voice.sh:
# rank_voice.sh уже гоняет 41 стратегию x 2 прохода x 2 попытки — полный
# кросс по 12 регионам (41 x 12 x 2 = 984 проб по ~30s каждая) занял бы
# ~8 часов за один ретюн, это нереально для автотюна (и в разы дороже
# текущего "дорогого ретюна", которого и так стараются избегать — см.
# zenith-promoter логи). Вместо этого здесь проверяется ОДНА стратегия
# (обычно текущая боевая/живая, см. --strategy) по всем регионам — дёшево
# (12 проб, ~6 минут) и отвечает именно на вопрос "работает ли живая
# стратегия во всех регионах или только в части из них".
#
# НЕ запускается автоматически из autotune_daemon.sh — это ручной
# диагностический инструмент. Если по его результатам окажется, что
# регион специфично ломается, тогда уже отдельный разговор — либо
# добавлять per-region профиль, либо чинить общую стратегию под худший
# регион.
#
# Запуск: ./rank_voice_regions.sh [--strategy N] [--probe-url URL]
#         [--probe-timeout SEC]
#   --strategy N        какую стратегию профиля 6 проверять (по умолчанию
#                        — текущая боевая, из locked.tsv key=6)
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROBE_URL="${PROBE_URL:-http://127.0.0.1:8765/probe}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-45}"
STRATEGY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --strategy) STRATEGY="$2"; shift 2 ;;
    --probe-url) PROBE_URL="$2"; shift 2 ;;
    --probe-timeout) PROBE_TIMEOUT="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$STRATEGY" ]; then
  LOCKED_TSV="/opt/zator/extra_strats/cache/orchestra/locked.tsv"
  STRATEGY="$(awk -F'\t' '$1=="6" && $2=="udp" {print $3}' "$LOCKED_TSV" 2>/dev/null)"
  if [ -z "$STRATEGY" ]; then
    echo "Не удалось определить текущую боевую стратегию профиля 6 из $LOCKED_TSV — укажи --strategy N вручную." >&2
    exit 1
  fi
  echo "Стратегия не задана явно -- беру текущую боевую: strategy=$STRATEGY (из $LOCKED_TSV)"
fi

REGIONS="auto brazil hongkong india japan rotterdam singapore southafrica sydney us-central us-east us-south us-west"

printf '%-14s %-8s %-10s %s\n' "region" "success" "connect_ms" "note"
printf '%-14s %-8s %-10s %s\n' "------" "-------" "----------" "----"

for region in $REGIONS; do
  resp="$(curl -s -m "$PROBE_TIMEOUT" -X POST "$PROBE_URL" -H 'Content-Type: application/json' \
    -d "{\"strategy_n\": $STRATEGY, \"region\": \"$region\"}")"
  if [ -z "$resp" ]; then
    printf '%-14s %-8s %-10s %s\n' "$region" "?" "?" "пустой ответ / таймаут curl (${PROBE_TIMEOUT}s)"
    continue
  fi
  printf '%s' "$resp" | REGION="$region" python3 -c "
import json, os, sys
region = os.environ['REGION']
try:
    d = json.loads(sys.stdin.read())
except Exception as e:
    print(f'{region:<14} ?        ?          не распарсился ответ: {e}')
    sys.exit(0)
ok = 'true' if d.get('success') else 'false'
ms = d.get('connect_ms', '?')
note = d.get('note', '')
print(f'{region:<14} {ok:<8} {ms!s:<10} {note}')
"
  sleep 1
done
