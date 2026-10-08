#!/usr/bin/env bash
# rank_voice_universal.sh — скрининг всех стратегий профиля 6 (VOICE_UDP)
# на предмет УНИВЕРСАЛЬНОСТИ по голосовым регионам Discord, а не только
# по тому единственному региону (us-central), который сейчас держит
# боевая strategy=35 (см. разбор 2026-10-08: 1 из 12 регионов работает).
#
# Полный кросс 41 стратегия x 12 регионов нереален (~8 часов, см.
# докстринг rank_voice_regions.sh). Вместо этого -- скрининг по 3
# "сложным" регионам (us-east, rotterdam, singapore -- геогр. разнесены,
# и все трое ломаются на текущей боевой strategy=35), 1 попытка на пару
# стратегия/регион. Кандидаты, прошедшие скрининг (успех во всех трёх),
# проверяются ПОВТОРНО по этим же 3 региону + us-central для
# подтверждения перед тем как предлагать замену боевой стратегии.
#
# ВАЖНО: на время прогона должен быть остановлен
# autotune-profile@6.service (он тоже дёргает /probe каждые ~5 минут и
# будет сталкиваться с этим скриптом за один и тот же голосовой канал --
# "Already connected to a voice channel"). Скрипт сам не проверяет и не
# трогает этот сервис -- это забота вызывающего (см. README/CLAUDE.md).
#
# Запуск: ./rank_voice_universal.sh [--out FILE]
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROBE_URL="${PROBE_URL:-http://127.0.0.1:8765/probe}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-35}"
OUT="${1:-/opt/z2r_autobench/logs/voice_universal_screen_$(date +%Y%m%d_%H%M%S).tsv}"

SCREEN_REGIONS="us-east rotterdam singapore"
MAX_STRAT=41

mkdir -p "$(dirname "$OUT")"
echo -e "strategy\tregion\tsuccess\tconnect_ms\tnote" > "$OUT"

probe_one() {
  local strat="$1" region="$2"
  local resp
  resp="$(curl -s -m "$PROBE_TIMEOUT" -X POST "$PROBE_URL" -H 'Content-Type: application/json' \
    -d "{\"strategy_n\": $strat, \"region\": \"$region\"}")"
  if [ -z "$resp" ]; then
    printf '%s\t%s\tfalse\t?\tпустой ответ/таймаут curl\n' "$strat" "$region" >> "$OUT"
    return
  fi
  printf '%s' "$resp" | STRAT="$strat" REGION="$region" OUT="$OUT" python3 -c "
import json, os, sys
strat, region, out = os.environ['STRAT'], os.environ['REGION'], os.environ['OUT']
try:
    d = json.loads(sys.stdin.read())
except Exception as e:
    with open(out, 'a') as f:
        f.write(f'{strat}\t{region}\tfalse\t?\tне распарсился ответ: {e}\n')
    sys.exit(0)
ok = 'true' if d.get('success') else 'false'
ms = d.get('connect_ms', '?')
note = (d.get('note') or '').replace('\n', ' ').replace('\t', ' ')
with open(out, 'a') as f:
    f.write(f'{strat}\t{region}\t{ok}\t{ms}\t{note}\n')
"
}

echo "Скрининг strategy=1..$MAX_STRAT по регионам: $SCREEN_REGIONS"
echo "Результаты пишутся в: $OUT (можно смотреть 'tail -f' прямо по ходу)"
echo

for strat in $(seq 1 "$MAX_STRAT"); do
  for region in $SCREEN_REGIONS; do
    probe_one "$strat" "$region"
  done
  pass_count="$(awk -F'\t' -v s="$strat" '$1==s && $3=="true"' "$OUT" | wc -l)"
  echo "strategy=$strat: прошло $pass_count/3 сложных регионов"
done

echo
echo "=== Готово. Кандидаты, прошедшие ВСЕ 3 сложных региона: ==="
awk -F'\t' '$3=="true" {c[$1]++} END {for (s in c) if (c[s]==3) print "  strategy="s}' "$OUT" | sort -t= -k2 -n
