#!/usr/bin/env bash
# rkn_list_cli.sh — тонкий CLI поверх боевых хостлистов профиля RKN_TLS
# (см. detect_governing_profile() в test_custom_domain.sh — та же логика
# разделения на TCP_RKN_list.txt/TCP_Custom.txt, независимо
# воспроизведена здесь ради отдельной точки входа для z0r-panel, sudoers
# грантует именно на этот файл, не на весь test_custom_domain.sh с его
# многопроходным тестированием).
#
# TCP_RKN_list.txt — официальный список (обновляется установщиком z2r/
# внешним источником), сюда НИЧЕГО не дописываем отсюда, только читаем.
# TCP_Custom.txt — ручные добавления поверх официального списка, тот же
# файл, что append'ит test_custom_domain.sh --add-to-rkn.
#
# Использование:
#   rkn_list_cli.sh list                 # обе строки в stdout: "SOURCE<TAB>домен"
#   rkn_list_cli.sh add <домен>          # добавить в TCP_Custom.txt (без дублей)
#   rkn_list_cli.sh remove <домен>       # убрать из TCP_Custom.txt ТОЛЬКО
#
# "remove" НЕ трогает TCP_RKN_list.txt ни при каких условиях -- это
# официальный список, управляется установщиком/внешним источником, а не
# ручным редактированием отсюда (см. комментарий у RKN_LIST/CUSTOM_LIST
# ниже). Если домен есть только там, remove откажет явной ошибкой, а не
# тихо удалит что-то из другого файла.
#
# Код возврата: 0 при успехе, 1 при ошибке аргументов/выполнения.

set -uo pipefail

# Инлайновая копия _z2r_detect_base() из z2r_autobench_lib.sh, НЕ сама
# библиотека -- та требует реального live-конфига z2r (config.sh/
# orchestra_state.sh/netcheck.sh под z2r_lib/, см. её же docstring),
# который этому скрипту не нужен, только сам путь $Z2R_BASE. Тот же
# приём, что z0r (главное меню) уже использует для этой же причины (см.
# z2r_autobench/CLAUDE.md "/opt/zapret2 vs /opt/zator") -- держать в
# синхроне при правках оригинала в z2r_autobench_lib.sh.
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

usage() {
  echo "Использование: $0 list" >&2
  echo "            или $0 add <домен>" >&2
  echo "            или $0 remove <домен>" >&2
  exit 1
}

[ $# -ge 1 ] || usage
action="$1"; shift

case "$action" in
  list)
    [ -f "$RKN_LIST" ] && sed -e 's/^/официальный\t/' "$RKN_LIST"
    [ -f "$CUSTOM_LIST" ] && sed -e 's/^/добавлен вручную\t/' "$CUSTOM_LIST"
    exit 0
    ;;
  add)
    [ $# -ge 1 ] || usage
    # Та же нормализация, что test_custom_domain.sh делает для доменов
    # из --domain -- убрать схему/путь, привести к нижнему регистру,
    # иначе один и тот же домен в разном регистре/с путём задублируется
    # в файле незаметно для grep -x ниже.
    d="$(printf '%s' "$1" | sed -E 's#^https?://##; s#/.*$##' | tr '[:upper:]' '[:lower:]')"
    [ -n "$d" ] || { echo "Пустой домен после нормализации" >&2; exit 1; }
    mkdir -p "$(dirname "$CUSTOM_LIST")"
    touch "$CUSTOM_LIST"
    if grep -qxi "$d" "$RKN_LIST" 2>/dev/null || grep -qxi "$d" "$CUSTOM_LIST" 2>/dev/null; then
      echo "$d уже в списке (официальном или добавленном вручную) — не дублирую" >&2
      exit 0
    fi
    echo "$d" >> "$CUSTOM_LIST"
    echo "Добавлено: $d" >&2
    exit 0
    ;;
  remove)
    [ $# -ge 1 ] || usage
    d="$(printf '%s' "$1" | sed -E 's#^https?://##; s#/.*$##' | tr '[:upper:]' '[:lower:]')"
    [ -n "$d" ] || { echo "Пустой домен после нормализации" >&2; exit 1; }
    if [ ! -f "$CUSTOM_LIST" ] || ! grep -qxi "$d" "$CUSTOM_LIST" 2>/dev/null; then
      if grep -qxi "$d" "$RKN_LIST" 2>/dev/null; then
        echo "$d — из официального TCP_RKN_list.txt, этот список только для чтения, отсюда не удаляется" >&2
      else
        echo "$d не найден ни в одном списке — нечего удалять" >&2
      fi
      exit 1
    fi
    # grep -v сохраняет остальные строки без учёта регистра совпадения --
    # временный файл + mv, не sed -i (переносимее между GNU/BSD sed, тут
    # не принципиально, но mv атомарнее in-place правки на случай сбоя
    # посреди записи). НЕ "grep ... && mv" -- grep -v возвращает код 1,
    # когда результат пустой (ровно этот случай: единственная строка в
    # файле как раз и совпадает с удаляемой), && тогда молча пропускает
    # mv и файл остаётся нетронутым -- найдено тестированием перед тем,
    # как это ушло на сервер.
    grep -vxi "$d" "$CUSTOM_LIST" > "$CUSTOM_LIST.tmp" || true
    mv "$CUSTOM_LIST.tmp" "$CUSTOM_LIST"
    echo "Удалено: $d" >&2
    exit 0
    ;;
  *)
    usage
    ;;
esac
