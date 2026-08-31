#!/usr/bin/env bash
# custom_domain_cli.sh — отдельный список "экзотических" доменов, каждый
# со СВОЕЙ независимой стратегией, в отличие от RKN-списка (rkn_list_cli.sh),
# где у ВСЕХ доменов под TCP_RKN_list.txt/TCP_Custom.txt ОДНА общая
# стратегия профиля RKN_TLS. Живой сценарий: домен не подпадает ни под
# один существующий профиль (YT_TLS/RKN_TLS/Discord/...) и общая
# fallback-стратегия (профиль 8/9) ему не подходит — единственный способ
# дать ему РЕАЛЬНО независимую стратегию в архитектуре z2r (один хостлист
# -> один circular_locked-замок) — завести под него отдельный маленький
# профиль-диспетчер в /opt/zapret2/config.
#
# Если домен УЖЕ входит в какой-то существующий список (TCP_YT_list.txt/
# TCP_Discord.txt/TCP_RKN_list.txt/TCP_Custom.txt) — add ОТКАЗЫВАЕТ с
# предупреждением, а не молча заводит второй, конфликтующий профиль для
# уже управляемого домена (прямой запрос при проектировании этой фичи).
#
# КАК добавляется новый профиль: НЕ пишем nfqws2-синтаксис с нуля (никто
# в этом репозитории живой /opt/zapret2/config не видел, придумывать
# формат вручную — верный способ сломать nfqws2 на следующем restart).
# Вместо этого клонируем УЖЕ РАБОЧИЙ блок-диспетчер профиля YT_TLS
# (circular_locked:key=1, см. promote_apply_cli.sh докстринг — у
# профилей типа YT_TLS/RKN_TLS сам блок-диспетчер маленький, --import=
# на общий шаблон, ни одной строки strategy= в нём самом) и патчим В НЁМ
# только ДВЕ вещи текстовой заменой: путь --hostlist= (на новый,
# однострочный, только для этого домена) и circular_locked:key=N (на
# новый свободный номер). Новый профиль автоматически наследует ВЕСЬ
# каталог стратегий из общего шаблона (z2r_tcp_tls_common) с СОБСТВЕННЫМ
# независимым замком — то же самое, для чего rank_strategies.sh --funnel
# уже работает с любым числовым профилем через config_profile_max_strategy.
#
# ПОЧЕМУ key=1 (YT_TLS), а не key=3 (RKN_TLS, как было изначально до
# 2026-08-29): на живом сервере проверено, что `circular_locked:key=3`
# встречается в конфиге ДВАЖДЫ — основной блок RKN_TLS по хостлисту И
# отдельный блок с тем же ключом, matching по подстроке
# (`include_substrings=`, делит замок с основным намеренно), плюс ещё
# профиль 8 с `route_key=3` (ссылается на чужой замок). `_find_block_by_key()`
# требует РОВНО одно совпадение и откажет на key=3. `key=1` подтверждён
# единственным и самодостаточным (обычный хостлист-блок, без
# route_key/include_substrings) — используем его по умолчанию.
# `--template-profile N` — ручное переопределение, если на каком-то
# другом сервере key=1 тоже окажется неоднозначным.
#
# add БЕЗ --yes — только ПРЕВЬЮ (что было бы записано), ничего не пишет.
# add --yes — реально дописывает блок в конец конфига (backup
# ОБЯЗАТЕЛЕН перед записью) и регистрирует домен. Restart zapret2 ПОСЛЕ
# add --yes — ручной шаг (см. вывод команды), не автоматический — тот же
# принцип, что и у set_strategy_cli.sh set.
#
# Использование:
#   custom_domain_cli.sh list
#   custom_domain_cli.sh add <домен> [--template-profile N] [--yes]
#   custom_domain_cli.sh remove <домен>
#
# Код возврата: 0 при успехе, 1 при ошибке/отказе.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh"

# config САМ по себе НЕ участвует в сплите /opt/zapret2 vs /opt/zator
# (см. CLAUDE.md "/opt/zapret2 vs /opt/zator" — только z2r_lib/
# extra_strats/files) — путь к нему всегда буквально /opt/zapret2/config
# на любой раскладке, поэтому не через $Z2R_BASE.
CONFIG_FILE="/opt/zapret2/config"
REGISTRY="$ORCH_DIR/custom_domains.tsv"
TEMPLATE_PROFILE=1          # YT_TLS по умолчанию — подтверждено единственным, самодостаточным блоком (см. докстринг выше); --template-profile N переопределяет
CUSTOM_PROFILE_BASE=20      # никогда не пересекается с реальными 1-9

usage() {
  echo "Использование: $0 list" >&2
  echo "            или $0 add <домен> [--template-profile N] [--yes]" >&2
  echo "            или $0 remove <домен>" >&2
  exit 1
}

_normalize_domain() {
  printf '%s' "$1" | sed -E 's#^https?://##; s#/.*$##' | tr '[:upper:]' '[:lower:]'
}

# Если домен УЖЕ управляется существующим профилем — печатает описание
# (куда именно попадает) и возвращает 0; иначе возвращает 1. Отдельно от
# z2r_detect_governing_profile() (та регистрирует НЕ найденный домен в
# TCP_Custom.txt при add_to_rkn=1 и всегда возвращает fallback-профиль —
# здесь нужен именно факт "уже управляем/не управляем", не маршрут).
_existing_governance() {
  local d="$1"
  if grep -qxi "$d" "$Z2R_BASE/extra_strats/TCP_YT_list.txt" 2>/dev/null; then
    echo "YT_TLS (профиль 1, TCP_YT_list.txt)"; return 0
  fi
  if grep -qxi "$d" "$Z2R_BASE/extra_strats/TCP_Discord.txt" 2>/dev/null; then
    echo "DS_TLS (профиль 4, TCP_Discord.txt)"; return 0
  fi
  if grep -qxi "$d" "$Z2R_BASE/extra_strats/TCP_RKN_list.txt" 2>/dev/null; then
    echo "RKN_TLS (профиль 3, TCP_RKN_list.txt, официальный)"; return 0
  fi
  if grep -qxi "$d" "$Z2R_BASE/extra_strats/TCP_Custom.txt" 2>/dev/null; then
    echo "RKN_TLS (профиль 3, TCP_Custom.txt, добавлен вручную)"; return 0
  fi
  return 1
}

_registry_lookup() {
  local d="$1"
  [ -f "$REGISTRY" ] || return 1
  awk -F'\t' -v d="$d" 'tolower($1)==d {print; found=1} END{exit !found}' "$REGISTRY"
}

# Находит блок-диспетчер профиля по его circular_locked:key=N — по
# границам "--new" вокруг СТРОКИ с этим ключом (см. CLAUDE.md "--new
# separates independent rule blocks" + promote_apply_cli.sh докстринг
# "конец блока -- первая строка --new ПОСЛЕ найденного заголовка", здесь
# то же самое, только якорь ищем по содержимому, не по заранее известному
# заголовку). Печатает "start end" (0-based индексы строк, inclusive) на
# stdout при РОВНО одном совпадении key=N, иначе ничего + код 1.
_find_block_by_key() {
  local key="$1"
  local -a lines
  mapfile -t lines < "$CONFIG_FILE"
  local n="${#lines[@]}"
  local key_idx=-1 matches=0 i
  for ((i = 0; i < n; i++)); do
    if [[ "${lines[$i]}" =~ circular_locked:key=${key}([^0-9]|$) ]]; then
      key_idx=$i
      matches=$((matches + 1))
    fi
  done
  if [ "$matches" -ne 1 ]; then
    echo "Найдено совпадений 'circular_locked:key=$key' в $CONFIG_FILE: $matches (ожидалась ровно 1) — отказ, не трогаю конфиг." >&2
    return 1
  fi
  local start=0
  for ((i = key_idx; i >= 0; i--)); do
    if [ "${lines[$i]}" = "--new" ]; then start=$((i + 1)); break; fi
  done
  local end=$((n - 1))
  for ((i = key_idx + 1; i < n; i++)); do
    if [ "${lines[$i]}" = "--new" ]; then end=$((i - 1)); break; fi
  done
  echo "$start $end"
}

# Следующий свободный номер профиля: максимум из (а) ВСЕХ circular_locked:key=N
# реально найденных в живом конфиге и (б) уже выданных в нашем реестре,
# плюс 1 (не ниже CUSTOM_PROFILE_BASE) — само-защита от коллизии с любыми
# существующими профилями, даже если на этом сервере их больше 9 или
# кто-то уже занял часть диапазона 20+ вручную. Не нужно заранее знать,
# что реально лежит в конфиге.
_next_free_profile() {
  local max_in_config max_in_registry max_found
  max_in_config="$(grep -oE 'circular_locked:key=[0-9]+' "$CONFIG_FILE" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)"
  max_in_registry=0
  if [ -f "$REGISTRY" ]; then
    max_in_registry="$(awk -F'\t' '{print $2}' "$REGISTRY" | sort -n | tail -1)"
  fi
  max_found="${max_in_config:-0}"
  [ "${max_in_registry:-0}" -gt "$max_found" ] && max_found="$max_in_registry"
  if [ "$max_found" -lt "$CUSTOM_PROFILE_BASE" ]; then
    echo "$CUSTOM_PROFILE_BASE"
  else
    echo "$((max_found + 1))"
  fi
}

[ $# -ge 1 ] || usage
action="$1"; shift

case "$action" in
  list)
    if [ ! -f "$REGISTRY" ] || [ ! -s "$REGISTRY" ]; then
      echo "(пусто — ни одного кастомного домена ещё не заведено)"
      exit 0
    fi
    printf '%-30s %-10s %-12s %s\n' "ДОМЕН" "ПРОФИЛЬ" "СТРАТЕГИЯ" "ДОБАВЛЕН"
    while IFS=$'\t' read -r rdomain rprofile rhostlist rcreated; do
      [ -z "$rdomain" ] && continue
      locked="$(get_strategy "$rprofile" tls 2>/dev/null)"
      printf '%-30s %-10s %-12s %s\n' "$rdomain" "$rprofile" "${locked:-?}" "$rcreated"
    done < "$REGISTRY"
    exit 0
    ;;

  add)
    [ $# -ge 1 ] || usage
    do_write=0
    domain=""
    template_profile="$TEMPLATE_PROFILE"
    while [ $# -gt 0 ]; do
      case "$1" in
        --yes) do_write=1; shift ;;
        --template-profile) template_profile="$2"; shift 2 ;;
        *) domain="$1"; shift ;;
      esac
    done
    domain="$(_normalize_domain "$domain")"
    [ -n "$domain" ] || { echo "Пустой домен после нормализации" >&2; exit 1; }

    if governed_by="$(_existing_governance "$domain")"; then
      echo "ПРЕДУПРЕЖДЕНИЕ: $domain уже управляется существующим профилем: $governed_by" >&2
      echo "Кастомный отдельный профиль для него НЕ заводится — у него уже есть управляемая стратегия там." >&2
      echo "Если общая стратегия того профиля ему не подходит — сначала осознанно убери домен из соответствующего списка, если это точно нужно." >&2
      exit 1
    fi
    if existing_row="$(_registry_lookup "$domain")"; then
      existing_profile="$(printf '%s' "$existing_row" | cut -f2)"
      echo "$domain уже зарегистрирован как кастомный профиль $existing_profile — нечего добавлять повторно (remove сначала, если нужно пересоздать)." >&2
      exit 1
    fi

    # см. промышленную блокировку promote_apply_cli.sh — тот же
    # lock-файл, НАРОЧНО общий с ним: оба инструмента структурно
    # дописывают /opt/zapret2/config (не просто strategy=N внутри уже
    # существующего блока), гонка между ними опаснее гонки между двумя
    # обычными strategy-переключениями.
    lock_file="${CONFIG_FILE}.promote.lock"
    exec {CUSTOM_LOCK_FD}>"$lock_file" || { echo "Не удалось открыть $lock_file для блокировки" >&2; exit 1; }
    if ! flock -w 30 "$CUSTOM_LOCK_FD"; then
      echo "Не удалось захватить блокировку $lock_file за 30s — кто-то другой сейчас пишет $CONFIG_FILE. Отказ, ничего не менял." >&2
      exit 1
    fi

    read -r start_idx end_idx <<< "$(_find_block_by_key "$template_profile")" || exit 1
    mapfile -t all_lines < "$CONFIG_FILE"
    block_lines=("${all_lines[@]:$start_idx:$((end_idx - start_idx + 1))}")

    new_num="$(_next_free_profile)"
    new_hostlist="$Z2R_BASE/extra_strats/TCP_CustomProfile_${new_num}.txt"

    # Путь(и) --hostlist= в блоке-доноре ищем ДИНАМИЧЕСКИ, не хардкодим
    # конкретные имена файлов -- у разных профилей разные хостлисты
    # (TCP_YT_list.txt у key=1, TCP_RKN_list.txt+TCP_Custom.txt у key=3
    # ДВУМЯ отдельными строками, не через запятую -- проверено на живом
    # конфиге 2026-08-29), а --template-profile может указать любой из
    # них. Точный префикс "--hostlist=" (не "--hostlist-exclude="/
    # "--hostlist-domains=" -- те трогать нельзя, разный смысл).
    new_block=()
    found_hostlist_line=0
    for line in "${block_lines[@]}"; do
      case "$line" in
        --hostlist=*)
          line="--hostlist=$new_hostlist"
          found_hostlist_line=1
          ;;
      esac
      line="$(printf '%s' "$line" | sed -E "s/circular_locked:key=${template_profile}([^0-9]|\$)/circular_locked:key=${new_num}\\1/")"
      new_block+=("$line")
    done
    if [ "$found_hostlist_line" != "1" ]; then
      echo "В блоке-доноре (key=$template_profile) не нашлось ни одной строки '--hostlist=' -- возможно, этот профиль матчит по --hostlist-domains= (инлайн-домены, как у GV_TLS) или ещё как-то иначе, клонировать его так для отдельного домена нельзя. Попробуй другой --template-profile." >&2
      exit 1
    fi

    echo "=== Профиль-донор (key=$template_profile), строки $((start_idx+1))-$((end_idx+1)) конфига ===" >&2
    printf '%s\n' "${block_lines[@]}" >&2
    echo "" >&2
    echo "=== Новый блок для $domain (профиль $new_num) — БУДЕТ ДОПИСАН В КОНЕЦ КОНФИГА ===" >&2
    echo "--new" >&2
    printf '%s\n' "${new_block[@]}" >&2
    echo "" >&2

    if [ "$do_write" != "1" ]; then
      echo "Это ПРЕВЬЮ — конфиг НЕ изменён. Проверь блок выше: сравни с профилем-донором построчно, убедись, что заменились только --hostlist= и circular_locked:key=. Повтори с --yes, если всё верно." >&2
      exit 0
    fi

    ts="$(date +%Y%m%d_%H%M%S)"
    backup="${CONFIG_FILE}.custom_domain_backup.${ts}"
    if ! cp -p "$CONFIG_FILE" "$backup"; then
      echo "Не удалось сделать backup в $backup — отказ, ничего не менял." >&2
      exit 1
    fi

    mkdir -p "$(dirname "$new_hostlist")"
    printf '%s\n' "$domain" > "$new_hostlist"

    {
      echo "--new"
      printf '%s\n' "${new_block[@]}"
    } >> "$CONFIG_FILE"

    mkdir -p "$(dirname "$REGISTRY")"
    printf '%s\t%s\t%s\t%s\n' "$domain" "$new_num" "$new_hostlist" "$(date -Iseconds)" >> "$REGISTRY"

    echo "Записано: профиль $new_num для $domain. Backup конфига: $backup" >&2
    echo "ВАЖНО (ручной шаг, не автоматом): 'systemctl restart zapret2' и проверь 'systemctl status zapret2'." >&2
    echo "Если не стартует — откат: cp $backup $CONFIG_FILE && systemctl restart zapret2" >&2
    echo "Дальше подбери стратегию именно для него: rank_strategies.sh --profile $new_num --funnel --passes 3 (или --domain $domain --funnel, детектор теперь тоже находит этот профиль)." >&2
    exit 0
    ;;

  remove)
    [ $# -ge 1 ] || usage
    domain="$(_normalize_domain "$1")"
    [ -n "$domain" ] || { echo "Пустой домен после нормализации" >&2; exit 1; }
    row="$(_registry_lookup "$domain")" || { echo "$domain не зарегистрирован как кастомный профиль — нечего удалять." >&2; exit 1; }
    rprofile="$(printf '%s' "$row" | cut -f2)"
    rhostlist="$(printf '%s' "$row" | cut -f3)"

    # НЕ трогаем структуру config (никакого удаления --new-блоков "на
    # лету" из живого файла — тот же класс риска, что и создание блока,
    # только страшнее: сломанные границы блока читает уже РАБОТАЮЩИЙ
    # nfqws2). Вместо этого опустошаем однострочный hostlist этого
    # домена -- профиль $rprofile перестаёт матчить хоть что-то, трафик
    # домена просто проваливается к следующему совпадающему правилу
    # (обычно fallback), блок в конфиге остаётся (мёртвый, но безвредный
    # -- circular_locked с пустым hostlist ничего не обрабатывает).
    if [ -f "$rhostlist" ]; then
      : > "$rhostlist"
    fi
    grep -vxi "$domain" "$REGISTRY" > "${REGISTRY}.tmp" || true
    mv "${REGISTRY}.tmp" "$REGISTRY"
    echo "$domain убран из кастомного профиля $rprofile (хостлист опустошён, блок в конфиге НЕ удалён — безвреден и пуст)." >&2
    exit 0
    ;;

  *)
    usage
    ;;
esac
