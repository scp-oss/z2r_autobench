#!/usr/bin/env bash
# telegram_calls_cli.sh — отдельный независимый UDP-профиль zapret2 для
# голосовых/видео-звонков Telegram. Тот же класс проблемы, что уже решён
# для Discord (VOICE_UDP, профиль 6): звонки используют СВОЙ UDP-трафик,
# для которого TCP-механизмы (MTProto-сигнализация + web.telegram.org
# через Zenith-WS relay) не помогают вообще — ни один из них не трогает
# UDP. Подтверждено живым тестом: звонок Telegram не устанавливается
# через VLESS+zapret2, но работает через полностью другой обходной путь
# (см. z2r_autobench/CLAUDE.md, секция про этот скрипт).
#
# КАК добавляется новый профиль: НЕ пишем nfqws2-синтаксис с нуля (никто
# в этом репозитории живой /opt/zapret2/config не видел — тот же принцип,
# что уже задокументирован в custom_domain_cli.sh, читай его докстринг
# как основной референс, этот скрипт — прямая адаптация того же приёма
# под UDP/IP-адресацию вместо TCP/домена). Клонируем УЖЕ РАБОЧИЙ блок
# VOICE_UDP (circular_locked:key=6 — нумерация профилей 1-9 однозначно
# соответствует их key=N, см. autotune_daemon.sh PROFILE_TITLE[6]) и
# патчим в копии ровно две вещи: адресацию (текущий IP/hostlist-таргет
# Discord → официальные подсети Telegram) и circular_locked:key=6 → новый
# свободный номер. Всё остальное (--qnum, тип --lua-desync=, любые
# порты) переносится КАК ЕСТЬ, не трогаем и не гадаем.
#
# Адресация ищется как --ipset= В ПЕРВУЮ очередь (не --hostlist=, как у
# custom_domain_cli.sh) — у UDP-трафика звонков нет domain/SNI, донор
# почти наверняка матчит по IP/CIDR тем же способом, что уже описан для
# zenith-ws/zapret2/TG_MTPROTO.block.conf (--ipset=.../telegram_ipv4.txt).
# Если --ipset= не найден — fallback на --hostlist=, иначе явный отказ.
#
# CIDR-файл — СОБСТВЕННАЯ копия официального списка Telegram
# (core.telegram.org/resources/cidr.txt), независимая от zenith-ws:
# z2r_autobench не должен зависеть от того, установлен ли zenith-ws на
# этом сервере. Тот же формат/источник, что zenith-ws/cidr/
# fetch_telegram_cidr.sh уже использует, просто отдельная копия под
# $Z2R_BASE/extra_strats/cidr/.
#
# НИКАКОГО автотеста здесь нет и не будет — в отличие от Discord
# (z2r_test-voice-bot, реальный клиент, умеющий зайти в голосовой канал
# самостоятельно), для звонков Telegram нет аналога: понадобился бы
# полноценный MTProto-клиент, умеющий инициировать/принимать звонок —
# на порядок сложнее всего остального в этом репозитории, и без
# live-доступа к серверу для отладки делать это вслепую нереалистично.
# Подбор стратегии — РУЧНОЙ: set_strategy_cli.sh set <профиль> udp <N>
# по очереди, после каждого — реальный звонок с телефона, смотрим,
# устанавливается ли. rank_strategies.sh --funnel тут неприменим — его
# probe требует HTTP(S) (probe_url), а здесь нет ни HTTP, ни домена.
#
# Использование:
#   telegram_calls_cli.sh status
#   telegram_calls_cli.sh add [--template-profile N] [--refresh-cidr] [--yes]
#   telegram_calls_cli.sh remove
#
# Код возврата: 0 при успехе, 1 при ошибке/отказе.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" != "0" ]; then
  echo "Нужен root." >&2
  exit 1
fi

# Инлайновая копия _z2r_detect_base() — та же идиома, что rkn_list_cli.sh/
# domain_list_sync.sh/z0r уже используют (см. CLAUDE.md "/opt/zapret2 vs
# /opt/zator") — этому скрипту не нужен весь z2r_autobench_lib.sh, только
# сам путь $Z2R_BASE. Держать в синхроне при правках оригинала.
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

# config САМ по себе НЕ участвует в сплите /opt/zapret2 vs /opt/zator
# (см. custom_domain_cli.sh, тот же аргумент) — путь к нему всегда
# буквально /opt/zapret2/config, не через $Z2R_BASE.
CONFIG_FILE="/opt/zapret2/config"
REGISTRY="$Z2R_BASE/extra_strats/cache/orchestra/telegram_calls.tsv"
CIDR_FILE="$Z2R_BASE/extra_strats/cidr/telegram_calls_ipv4.txt"
CIDR_SOURCE_URL="https://core.telegram.org/resources/cidr.txt"
TEMPLATE_PROFILE=6          # VOICE_UDP по умолчанию — единственный реальный UDP-донор в проекте; --template-profile N переопределяет
CUSTOM_PROFILE_BASE=20      # тот же пул, что custom_domain_cli.sh — оба читают максимум из живого конфига, коллизия исключена без явной связи между реестрами

usage() {
  echo "Использование: $0 status" >&2
  echo "            или $0 add [--template-profile N] [--refresh-cidr] [--yes]" >&2
  echo "            или $0 remove" >&2
  exit 1
}

# Скачивает официальный список подсетей Telegram в $CIDR_FILE — та же
# логика/формат, что zenith-ws/cidr/fetch_telegram_cidr.sh уже проверил
# (curl -> фильтр IPv4 CIDR-строк -> sort -V), отдельная копия, не
# symlink/reference на чужой репозиторий.
_fetch_telegram_cidr() {
  local raw v4_lines
  raw="$(curl -fsS --max-time 15 "$CIDR_SOURCE_URL")" || {
    echo "Не удалось скачать $CIDR_SOURCE_URL" >&2
    return 1
  }
  [ -n "$raw" ] || { echo "Пустой ответ от $CIDR_SOURCE_URL — отказ, не буду перезаписывать $CIDR_FILE." >&2; return 1; }
  v4_lines="$(printf '%s\n' "$raw" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | sort -V)"
  [ -n "$v4_lines" ] || { echo "В ответе не нашлось ни одной IPv4 CIDR-строки — формат источника изменился? Отказ." >&2; return 1; }
  mkdir -p "$(dirname "$CIDR_FILE")"
  {
    echo "# Источник: $CIDR_SOURCE_URL"
    echo "# Обновлено: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# IPv4-подсети официальных Telegram DC — своя копия для"
    echo "# telegram_calls_cli.sh, независимая от zenith-ws. Диапазоны"
    echo "# МЕНЯЮТСЯ со временем — обновлять через --refresh-cidr, не"
    echo "# считать разово скачанный файл вечным."
    printf '%s\n' "$v4_lines"
  } > "$CIDR_FILE"
  echo "OK: $(printf '%s\n' "$v4_lines" | wc -l) IPv4-подсетей -> $CIDR_FILE" >&2
  return 0
}

# Копия _find_block_by_key() из custom_domain_cli.sh — границы блока по
# ближайшим --new вокруг строки с circular_locked:key=N, ровно один матч
# или отказ (см. тот файл за полным докстрингом рассуждения).
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

# Следующий свободный номер профиля — читает максимум ИЗ ЖИВОГО КОНФИГА
# (не только из своего реестра), тот же приём, что custom_domain_cli.sh
# уже использует — так оба инструмента остаются согласованными через
# общий источник истины без явной связи между их TSV-реестрами.
_next_free_profile() {
  local max_in_config max_in_registry max_found
  max_in_config="$(grep -oE 'circular_locked:key=[0-9]+' "$CONFIG_FILE" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)"
  max_in_registry=0
  if [ -f "$REGISTRY" ]; then
    max_in_registry="$(awk -F'\t' '{print $1}' "$REGISTRY" | sort -n | tail -1)"
  fi
  max_found="${max_in_config:-0}"
  [ "${max_in_registry:-0}" -gt "$max_found" ] && max_found="$max_in_registry"
  if [ "$max_found" -lt "$CUSTOM_PROFILE_BASE" ]; then
    echo "$CUSTOM_PROFILE_BASE"
  else
    echo "$((max_found + 1))"
  fi
}

_registered_profile() {
  [ -f "$REGISTRY" ] && [ -s "$REGISTRY" ] || return 1
  tail -n1 "$REGISTRY" | cut -f1
}

[ $# -ge 1 ] || usage
action="$1"; shift

case "$action" in
  status)
    profile="$(_registered_profile)" || {
      echo "Профиль звонков Telegram ещё не зарегистрирован — запусти '$0 add' (сначала без --yes, посмотреть превью)." >&2
      exit 0
    }
    echo "Зарегистрированный профиль: $profile"
    ipset_path="$(tail -n1 "$REGISTRY" | cut -f2)"
    echo "Ipset-файл: $ipset_path ($([ -s "$ipset_path" ] 2>/dev/null && echo "непустой" || echo "ПУСТОЙ — профиль неактивен"))"
    strat="$("$SCRIPT_DIR/set_strategy_cli.sh" get "$profile" udp 2>&1)"
    max="$("$SCRIPT_DIR/set_strategy_cli.sh" max "$profile" 2>&1)"
    echo "Текущая стратегия: $strat"
    echo "Всего стратегий доступно (унаследовано от донора): $max"
    exit 0
    ;;

  add)
    do_write=0
    refresh_cidr=0
    template_profile="$TEMPLATE_PROFILE"
    while [ $# -gt 0 ]; do
      case "$1" in
        --yes) do_write=1; shift ;;
        --refresh-cidr) refresh_cidr=1; shift ;;
        --template-profile) template_profile="$2"; shift 2 ;;
        *) echo "Неизвестный аргумент: $1" >&2; usage ;;
      esac
    done

    if existing_profile="$(_registered_profile)"; then
      echo "Профиль звонков Telegram уже зарегистрирован как $existing_profile — нечего добавлять повторно ('$0 remove' сначала, если нужно пересоздать)." >&2
      exit 1
    fi

    if [ "$refresh_cidr" = "1" ] || [ ! -s "$CIDR_FILE" ]; then
      _fetch_telegram_cidr || exit 1
    fi

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

    # Адресация: --ipset= В ПЕРВУЮ очередь (UDP/IP, не domain/SNI),
    # --hostlist= как fallback (на случай, если донор на этом сервере
    # неожиданно матчит иначе) — см. докстринг наверху файла.
    new_block=()
    found_addr_line=0
    addr_directive=""
    for line in "${block_lines[@]}"; do
      case "$line" in
        --ipset=*)
          line="--ipset=$CIDR_FILE"
          found_addr_line=1
          addr_directive="--ipset="
          ;;
        --hostlist=*)
          if [ -z "$addr_directive" ]; then
            line="--hostlist=$CIDR_FILE"
            found_addr_line=1
            addr_directive="--hostlist="
          fi
          ;;
      esac
      line="$(printf '%s' "$line" | sed -E "s/circular_locked:key=${template_profile}([^0-9]|\$)/circular_locked:key=${new_num}\\1/")"
      new_block+=("$line")
    done
    if [ "$found_addr_line" != "1" ]; then
      echo "В блоке-доноре (key=$template_profile) не нашлось ни '--ipset=', ни '--hostlist=' — донор матчит как-то иначе (инлайн-значение? другая директива?), клонировать так нельзя. Попробуй другой --template-profile." >&2
      exit 1
    fi

    echo "=== Профиль-донор (key=$template_profile), строки $((start_idx+1))-$((end_idx+1)) конфига ===" >&2
    printf '%s\n' "${block_lines[@]}" >&2
    echo "" >&2
    echo "=== Новый блок для звонков Telegram (профиль $new_num) — БУДЕТ ДОПИСАН В КОНЕЦ КОНФИГА ===" >&2
    echo "--new" >&2
    printf '%s\n' "${new_block[@]}" >&2
    echo "" >&2
    echo "ВНИМАНИЕ: клон несёт ВСЕ директивы донора как есть, включая любые" >&2
    echo "специфичные для Discord-звонков порты (--filter-udp=) или --qnum," >&2
    echo "если они там есть — нет способа заранее узнать, подходят ли именно" >&2
    echo "эти значения звонкам Telegram (протокол согласования порта нигде" >&2
    echo "в этом проекте не задокументирован). Проверь блок выше глазами" >&2
    echo "перед --yes; если оно окажется проблемой — чинить руками по" >&2
    echo "результатам первого live-теста, не гадать сейчас." >&2

    if [ "$do_write" != "1" ]; then
      echo "" >&2
      echo "Это ПРЕВЬЮ — конфиг НЕ изменён. Повтори с --yes, если блок выше корректен." >&2
      exit 0
    fi

    ts="$(date +%Y%m%d_%H%M%S)"
    backup="${CONFIG_FILE}.custom_domain_backup.${ts}"
    if ! cp -p "$CONFIG_FILE" "$backup"; then
      echo "Не удалось сделать backup в $backup — отказ, ничего не менял." >&2
      exit 1
    fi

    {
      echo "--new"
      printf '%s\n' "${new_block[@]}"
    } >> "$CONFIG_FILE"

    mkdir -p "$(dirname "$REGISTRY")"
    printf '%s\t%s\t%s\n' "$new_num" "$CIDR_FILE" "$(date -Iseconds)" >> "$REGISTRY"

    echo "Записано: профиль $new_num для звонков Telegram. Backup конфига: $backup" >&2
    echo "ВАЖНО (ручной шаг, не автоматом): 'systemctl restart zapret2' и проверь 'systemctl status zapret2'." >&2
    echo "Если не стартует — откат: cp $backup $CONFIG_FILE && systemctl restart zapret2" >&2
    echo "Дальше подбор стратегии — РУЧНОЙ (автотеста для звонков Telegram нет):" >&2
    echo "  set_strategy_cli.sh max $new_num        # сколько всего стратегий унаследовано" >&2
    echo "  set_strategy_cli.sh set $new_num udp N  # применить кандидата N" >&2
    echo "  -> реальный звонок с телефона, смотреть, устанавливается ли" >&2
    exit 0
    ;;

  remove)
    profile="$(_registered_profile)" || { echo "Профиль звонков Telegram не зарегистрирован — нечего удалять." >&2; exit 1; }
    ipset_path="$(tail -n1 "$REGISTRY" | cut -f2)"
    # НЕ трогаем структуру config (тот же принцип, что custom_domain_cli.sh
    # remove) — только опустошаем ipset-файл, профиль $profile перестаёт
    # матчить хоть что-то, блок в конфиге остаётся мёртвым и безвредным.
    if [ -f "$ipset_path" ]; then
      : > "$ipset_path"
    fi
    grep -v "^${profile}	" "$REGISTRY" > "${REGISTRY}.tmp" || true
    mv "${REGISTRY}.tmp" "$REGISTRY"
    echo "Профиль $profile для звонков Telegram отключён (ipset-файл опустошён, блок в конфиге НЕ удалён — безвреден и пуст)." >&2
    exit 0
    ;;

  *)
    usage
    ;;
esac
