#!/usr/bin/env bash
# rkn_external_sync.sh — сравнивает боевой RKN-хостлист
# (TCP_RKN_list.txt + TCP_Custom.txt, см. rkn_list_cli.sh) с внешним,
# независимо поддерживаемым списком заблокированных в РФ доменов и
# показывает/добавляет то, чего в боевом списке ещё нет.
#
# Зачем внешний источник вместо ручного добавления по одному домену:
# TCP_RKN_list.txt заявлен как "официальный, поддерживается установщиком
# z2r" (см. rkn_list_cli.sh), но на практике может отставать/не покрывать
# домен, который реально попадает под RKN-блокировку прямо сейчас —
# ручное добавление через test_custom_domain.sh --add-to-rkn/
# rkn_list_cli.sh add требует уже ЗНАТЬ, какой домен добавить. Этот
# скрипт вместо этого тянет уже курируемый, регулярно обновляемый список
# (по умолчанию 1andrevich/Re-filter-lists — community-проект, отдельный
# от z2r, читает тот же класс данных, что и apkbol-van/zapret сам
# использует через zapret-info/z-i, см. CLAUDE.md за полным разбором
# источников, которые были проверены живьём перед выбором этого).
#
# ПРИНЦИПЫ, те же, что у rkn_list_cli.sh/custom_domain_cli.sh в этом репо:
#   - TCP_RKN_list.txt НИКОГДА не трогается отсюда — официальный список,
#     read-only, как и везде в этом репо (см. rkn_list_cli.sh докстринг).
#   - Все добавления идут ТОЛЬКО в TCP_Custom.txt, тем же путём, что
#     ручной rkn_list_cli.sh add.
#   - Запись в TCP_Custom.txt требует явного --yes (см. custom_domain_cli.sh
#     "add требует явного --yes" за тем же обоснованием) — без него это
#     чистый предпросмотр, ничего не трогает.
#   - Внешний список может быть большим (десятки тысяч доменов) — счётчик
#     "новых" печатается ДО --yes, чтобы человек видел масштаб перед тем,
#     как соглашаться дописать их все разом.
#
# Использование:
#   rkn_external_sync.sh diff             # только показать: сколько новых, куда записан предпросмотр
#   rkn_external_sync.sh add [--yes]      # без --yes = тот же предпросмотр; с --yes = дописывает в TCP_Custom.txt
#   rkn_external_sync.sh diff --source-url URL   # использовать другой источник вместо дефолтного
#
# Код возврата: 0 при успехе (включая "новых доменов нет"), 1 при ошибке
# сети/аргументов.

set -uo pipefail

# Та же инлайн-копия _z2r_detect_base(), что rkn_list_cli.sh уже
# использует — держать в синхроне при правках оригинала в
# z2r_autobench_lib.sh (см. CLAUDE.md "/opt/zapret2 vs /opt/zator").
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

RKN_LIST="$Z2R_BASE/extra_strats/TCP_RKN_list.txt"
CUSTOM_LIST="$Z2R_BASE/extra_strats/TCP_Custom.txt"
REVIEW_FILE="$Z2R_BASE/extra_strats/rkn_sync_candidates.txt"

# Проверено живьём перед выбором дефолта (2026-09-09, см. CLAUDE.md):
# plain-текст, один домен на строку, без комментариев/заголовка,
# ~81 тыс. строк на момент проверки. НЕ дамп zapret-info/z-i напрямую
# (dump.csv) — тот больше 10МБ на один шард и требует парсинга
# домен;IP;... формата без задокументированной схемы, тогда как этот
# список уже в готовом для --hostlist= виде.
DEFAULT_SOURCE_URL="https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/domains_all.lst"
SOURCE_URL="$DEFAULT_SOURCE_URL"

usage() {
  echo "Использование: $0 diff [--source-url URL]" >&2
  echo "            или $0 add [--yes] [--source-url URL]" >&2
  exit 1
}

[ $# -ge 1 ] || usage
action="$1"; shift
YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --source-url) SOURCE_URL="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage ;;
  esac
done
case "$action" in
  diff|add) ;;
  *) usage ;;
esac

command -v curl >/dev/null 2>&1 || { echo "curl не найден — нечем скачать внешний список" >&2; exit 1; }

TMP_EXTERNAL="$(mktemp)"
trap 'rm -f "$TMP_EXTERNAL"' EXIT

if ! curl -fsS --max-time 30 -o "$TMP_EXTERNAL" "$SOURCE_URL"; then
  echo "Не удалось скачать $SOURCE_URL (сеть недоступна или источник переехал)" >&2
  exit 1
fi
[ -s "$TMP_EXTERNAL" ] || { echo "Скачанный список пуст — источник, похоже, сломан, ничего не делаю" >&2; exit 1; }

# Нормализация внешнего списка: нижний регистр, без пустых строк/
# комментариев — тот же приём, что rkn_list_cli.sh add делает для
# ОДНОГО домена, здесь просто построчно на весь файл.
NORMALIZED_EXTERNAL="$(mktemp)"
trap 'rm -f "$TMP_EXTERNAL" "$NORMALIZED_EXTERNAL"' EXIT
tr '[:upper:]' '[:lower:]' < "$TMP_EXTERNAL" \
  | sed -E 's/^https?:\/\///; s/\/.*$//; s/[[:space:]]+$//' \
  | grep -vE '^\s*#|^\s*$' \
  | sort -u > "$NORMALIZED_EXTERNAL"

external_count="$(wc -l < "$NORMALIZED_EXTERNAL" | tr -d ' ')"

# Объединённый боевой список (официальный + ручной), та же нормализация,
# для честного сравнения по строке целиком.
COMBINED_LOCAL="$(mktemp)"
trap 'rm -f "$TMP_EXTERNAL" "$NORMALIZED_EXTERNAL" "$COMBINED_LOCAL"' EXIT
{
  [ -f "$RKN_LIST" ] && cat "$RKN_LIST"
  [ -f "$CUSTOM_LIST" ] && cat "$CUSTOM_LIST"
} 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -vE '^\s*#|^\s*$' | sort -u > "$COMBINED_LOCAL"

local_count="$(wc -l < "$COMBINED_LOCAL" | tr -d ' ')"

# comm -23: строки, которые есть ТОЛЬКО в первом (внешнем) файле —
# то есть домены из внешнего списка, которых ещё нет ни в
# TCP_RKN_list.txt, ни в TCP_Custom.txt. Оба входа уже отсортированы
# (sort -u выше), comm этого и требует.
comm -23 "$NORMALIZED_EXTERNAL" "$COMBINED_LOCAL" > "$REVIEW_FILE"
new_count="$(wc -l < "$REVIEW_FILE" | tr -d ' ')"

echo "Внешний список: $external_count доменов ($SOURCE_URL)" >&2
echo "Боевой список сейчас: $local_count доменов (TCP_RKN_list.txt + TCP_Custom.txt)" >&2
echo "Новых (есть во внешнем, нет в боевом): $new_count" >&2
echo "Полный список новых доменов записан в: $REVIEW_FILE" >&2

if [ "$action" = "diff" ]; then
  exit 0
fi

# action=add
if [ "$new_count" -eq 0 ]; then
  echo "Добавлять нечего — боевой список уже покрывает всё из внешнего." >&2
  exit 0
fi

if [ "$YES" -ne 1 ]; then
  echo "Предпросмотр (--yes не передан) — TCP_Custom.txt НЕ тронут. Посмотри $REVIEW_FILE" >&2
  echo "и повтори с --yes, если хочешь дописать все $new_count доменов в TCP_Custom.txt." >&2
  exit 0
fi

mkdir -p "$(dirname "$CUSTOM_LIST")"
touch "$CUSTOM_LIST"
cat "$REVIEW_FILE" >> "$CUSTOM_LIST"
echo "Дописано $new_count доменов в $CUSTOM_LIST." >&2
echo "Неизвестно, перечитывает ли живой nfqws2 хостлист без рестарта — этот" >&2
echo "репо нигде не утверждает такое про --hostlist= (см. CLAUDE.md, принцип" >&2
echo "'не изобретаем поведение nfqws2'). Если новые домены не заработали сразу," >&2
echo "попробуй перезапустить zapret2.service вручную (тот же шаг, что" >&2
echo "custom_domain_cli.sh печатает после своей записи в конфиг)." >&2
