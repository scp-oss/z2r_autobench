#!/usr/bin/env bash
# voice_best_select.sh — выбрать и закрепить стратегию VOICE_UDP (профиль 6), которая работает
# во ВСЕХ голосовых регионах Discord и подключается быстрее остальных.
#
# Зачем: пользователь может зайти в любой голосовой канал, а значит попасть на любой регион;
# стратегия, которая работает только в «CDN Auto», для него не годится.
#
#   1) кандидаты — стратегии, прошедшие последнюю автопроверку бота (logs/voice_bot_raw.tsv,
#      последний непрерывный прогон: записи с промежутками меньше 15 мин), по возрастанию
#      времени подключения;
#      если профиль 6 сейчас не закреплён (zator по кругу) — сразу закрепляем самую быструю,
#      чтобы голос работал, пока идёт проверка регионов;
#   2) первые VOICE_SELECT_CANDIDATES кандидатов (+ текущая закреплённая) гоняем по 13 регионам
#      через rank_voice_regions.sh (бот /probe, песочница — боевой трафик не трогается);
#   3) лучшая = больше рабочих регионов, при равенстве — меньше среднее время подключения;
#      закрепляем её (set_strategy_cli.sh set 6 udp N);
#   4) результат лучшей кладём как обычный прогон регионов: logs/voice_regions.json (его читает
#      бот для сводки), logs/voice_regions_history.jsonl, БД Zenith; полный отчёт выбора —
#      logs/voice_select.json, история — logs/voice_select_history.jsonl.
#
# Запуск: из voice_region_sweep.sh (когда профиль не закреплён или закреплённая стратегия
# работает не во всех регионах) или вручную: sudo ./voice_best_select.sh
# Коды: 0 — выбрано/закреплено или выбирать не из чего (автопроверка ещё не прошла), 1 — ошибка.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
RAW="$LOG_DIR/voice_bot_raw.tsv"
OUT="$LOG_DIR/voice_regions.json"
HIST="$LOG_DIR/voice_regions_history.jsonl"
SEL="$LOG_DIR/voice_select.json"
SEL_HIST="$LOG_DIR/voice_select_history.jsonl"
ZENITH_ORCH="${ZENITH_ORCH:-$SCRIPT_DIR/Zenith/orchestrator}"
CANDIDATES="${VOICE_SELECT_CANDIDATES:-6}"
SETCLI="$SCRIPT_DIR/set_strategy_cli.sh"

mkdir -p "$LOG_DIR"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

cur="$("$SETCLI" get 6 udp 2>/dev/null | tr -dc 0-9)"; [ "${cur:-0}" = 0 ] && cur=""

# 1) кандидаты из последней автопроверки: стратегии без единого провала, быстрые первыми
mapfile -t cands < <(python3 - "$RAW" <<'PY'
import csv, sys, datetime as dt
path = sys.argv[1]
rows = []
try:
    for r in csv.reader(open(path, encoding="utf-8", errors="replace"), delimiter="\t"):
        if len(r) < 6 or not r[2].startswith("voice_"): continue
        try: rows.append((dt.datetime.fromisoformat(r[0]), int(r[2][6:]), r[4] == "1", int(r[5] or 0)))
        except ValueError: continue
except OSError: pass
if not rows: sys.exit(0)
rows.sort(key=lambda x: x[0])
# последний непрерывный прогон: от конца назад, пока между записями < 15 мин
start = len(rows) - 1
while start > 0 and rows[start][0] - rows[start - 1][0] < dt.timedelta(minutes=15): start -= 1
agg = {}
for ts, n, ok, ms in rows[start:]:
    a = agg.setdefault(n, [0, 0, []]); a[0] += 1; a[1] += ok
    if ok: a[2].append(ms)
good = [(n, sum(a[2]) / len(a[2])) for n, a in agg.items() if a[1] == a[0] and a[2]]
for n, ms in sorted(good, key=lambda x: x[1]): print(n)
PY
)

if [ "${#cands[@]}" -eq 0 ]; then
  echo "voice_best_select: в последней автопроверке нет стратегий без провалов — выбирать не из чего (бот не проверял? нет прав на канал?)"
  exit 0
fi
echo "voice_best_select: кандидаты по автопроверке (быстрые первыми): ${cands[*]}; закреплена сейчас: ${cur:-нет (по кругу)}"

if [ -z "$cur" ]; then
  if "$SETCLI" set 6 udp "${cands[0]}"; then
    echo "voice_best_select: профиль 6 не был закреплён — временно закрепил самую быструю: ${cands[0]}"
    cur="${cands[0]}"
  else
    echo "voice_best_select: не удалось закрепить ${cands[0]}" >&2
  fi
fi

# 2) прогон по регионам: первые N кандидатов + текущая закреплённая
test_list=("${cands[@]:0:$CANDIDATES}")
[ -n "$cur" ] && [[ " ${test_list[*]} " != *" $cur "* ]] && test_list+=("$cur")
for n in "${test_list[@]}"; do
  echo "voice_best_select: strategy=$n — проверка по регионам..."
  "$SCRIPT_DIR/rank_voice_regions.sh" --strategy "$n" --json "$work/$n.json" >/dev/null 2>&1 \
    || echo "voice_best_select: strategy=$n — rank_voice_regions.sh завершился с ошибкой" >&2
done

# 3) выбор
best="$(python3 - "$work" "$cur" "$SEL" <<'PY'
import glob, json, os, sys, time
work, cur, sel = sys.argv[1], sys.argv[2], sys.argv[3]
res = []
for f in glob.glob(os.path.join(work, "*.json")):
    d = json.load(open(f)); r = d.get("results", [])
    known = [x for x in r if x.get("success") is not None]
    okl = [x for x in r if x.get("success")]
    ms = [x["connect_ms"] for x in okl if isinstance(x.get("connect_ms"), (int, float))]
    res.append({"strategy": d.get("strategy"), "ok": len(okl), "known": len(known), "total": len(r),
                "avg_ms": round(sum(ms) / len(ms)) if ms else None,
                "failed": [x["region"] for x in r if x.get("success") is False], "file": f})
if not res or all(x["known"] == 0 for x in res):
    print(""); sys.exit(0)
res.sort(key=lambda x: (-x["ok"], x["avg_ms"] if x["avg_ms"] is not None else 1e9))
b = res[0]
json.dump({"ts": int(time.time()), "previous": int(cur) if cur.isdigit() else None, "chosen": b["strategy"],
           "candidates": [{k: v for k, v in x.items() if k != "file"} for x in res]},
          open(sel, "w"), ensure_ascii=False, indent=1)
print(f'{b["strategy"]} {b["file"]} {b["ok"]} {b["total"]} {b["avg_ms"]}')
PY
)"
if [ -z "$best" ]; then
  echo "voice_best_select: ни одного ответа от /probe (бот не запущен?) — ничего не меняю" >&2
  exit 1
fi
read -r bn bfile bok btotal bms <<<"$best"
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), ensure_ascii=False))' "$SEL" >> "$SEL_HIST"

# 4) закрепить и сохранить как обычный прогон регионов
if [ "$bn" != "$cur" ]; then
  if "$SETCLI" set 6 udp "$bn"; then echo "voice_best_select: закрепил strategy=$bn (было: ${cur:-нет})"
  else echo "voice_best_select: не удалось закрепить strategy=$bn" >&2; exit 1; fi
else
  echo "voice_best_select: лучшая — уже закреплённая strategy=$bn, без изменений"
fi
install -m 644 "$bfile" "$OUT"
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), ensure_ascii=False))' "$OUT" >> "$HIST"
if [ -x "$ZENITH_ORCH/venv/bin/python" ]; then
  ( cd "$ZENITH_ORCH" && venv/bin/python record_voice_regions.py "$OUT" ) >/dev/null 2>&1 \
    || echo "voice_best_select: запись в БД не удалась (результат есть в $OUT)" >&2
fi
python3 - "$SEL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("voice_best_select: итог —", "; ".join(
    f'{c["strategy"]}: {c["ok"]}/{c["total"]}' + (f' {c["avg_ms"]}мс' if c["avg_ms"] else "") + (f' (не работает: {", ".join(c["failed"])})' if c["failed"] else "")
    for c in d["candidates"]))
print(f'voice_best_select: выбрана strategy={d["chosen"]}')
PY
exit 0
