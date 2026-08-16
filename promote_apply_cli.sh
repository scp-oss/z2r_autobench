#!/usr/bin/env bash
# promote_apply_cli.sh -- узкий мост для автопродвижения Zenith-геномов в
# /opt/zapret2/config БЕЗ участия человека (см. z0r-panel/promoter.py).
# Отдельно от set_strategy_cli.sh -- тот только ПЕРЕКЛЮЧАЕТ уже
# существующий strategy=N (circular_locked/locked.tsv), этот -- ДОБАВЛЯЕТ
# НОВЫЙ strategy=N блок в конец уже существующего блока профиля. Самая
# рискованная операция во всей цепочке (правит боевой файл без
# присмотра человека), поэтому:
#
#   - блок находится ОДНИМ из двух способов, вызывающий выбирает
#     явно (см. формат spec ниже) -- НЕ по имени профиля, НЕ по позиции
#     в файле:
#       HEADER -- точное построчное совпадение заголовка (--filter-tcp=/
#         --hostlist=/... -- для профилей с САМОДОСТАТОЧНЫМ блоком,
#         strategy=N лежат прямо в нём);
#       TEMPLATE -- точное совпадение одной строки "--template=<имя>" --
#         для профилей, которые сами лишь --import=<имя> общий шаблон
#         (несколько профилей могут делить один и тот же шаблон, см.
#         живой пример 2026-08-16: YT_TLS и RKN_TLS оба --import=
#         z2r_tcp_tls_common -- их strategy=N физически лежат В ШАБЛОНЕ,
#         не в собственном маленьком блоке-диспетчере профиля, у
#         которого там только circular_locked:key=N + --import=, ни
#         одной строки strategy= -- HEADER-режим на таком блоке
#         корректно откажет ("нет ни одной строки strategy="), но
#         писать всё равно нужно в шаблон, не в диспетчер);
#   - конец блока -- первая строка "--new" ПОСЛЕ найденного заголовка
#     (--new разделяет НЕЗАВИСИМЫЕ блоки профилей, см. CLAUDE.md z2r_autobench
#     "zapret1 vs zapret2 -- do not mix syntax");
#   - максимум strategy=N ищется СТРОГО внутри границ этого блока, не по
#     всему файлу -- номера НЕ уникальны глобально, разные профили
#     переиспользуют одни и те же числа (живой пример: profile=2
#     strategy=1 и profile=5 strategy=1 одновременно, см.
#     /opt/etc/z2r/profile.lock);
#   - вызывающий обязан передать ОЖИДАЕМЫЙ текущий максимум
#     (after_strategy) -- если он разошёлся с реально найденным в
#     блоке, скрипт ОТКАЗЫВАЕТСЯ писать (защита от гонки/устаревших
#     данных, не от невнимательности -- вызывающий обязан сам
#     перечитать max перед вызовом);
#   - backup ВСЕГДА делается перед записью, путь печатается в stderr --
#     это единственный путь отката, если что-то пойдёт не так на
#     следующих шагах (set/restart/health-check -- уже вне этого
#     скрипта, см. promoter.py);
#   - restart НЕ делается здесь -- это отдельный явный шаг у
#     вызывающего, тот же принцип разделения, что везде в проекте
#     (set_strategy_cli.sh set тоже не рестартует сам).
#
# Использование:
#   promote_apply_cli.sh apply <after_strategy> <config_path> <backup_dir> < spec
#   promote_apply_cli.sh restore <backup_path> <config_path>
#
# apply -- spec (stdin), простой построчный формат, ДВА варианта:
#   HEADER                              |  TEMPLATE
#   <строка заголовка блока 1>          |  <имя шаблона, напр. z2r_tcp_tls_common>
#   <строка заголовка блока 2>          |  BODY
#   ...                                 |  <строка тела 1>
#   BODY                                |  ...
#   <строка тела 1 -- БЕЗ :strategy=, скрипт сам допишет>
#   <строка тела 2, если геном многострочный>
#   ...
# stdout при успехе: одна строка -- присвоенный strategy=N.
# stderr: путь к backup при успехе, диагностика при ошибке.
#
# restore -- откат, если после apply+set+restart health-check не прошёл
# (см. promoter.py): копирует backup_path обратно на config_path. ПЕРЕД
# перезаписью САМ делает ещё один backup текущего (сломанного)
# config_path -- откат отката тоже должен быть возможен. backup_path
# обязан существовать и быть обычным непустым файлом -- больше никакой
# привязки к backup_dir не требуется (тот же процесс, что писал apply,
# и есть единственный источник backup_path, отдельная валидация пути
# ничего не добавляет к уже данному этому скрипту доверию).
#
# Код возврата (обе команды): 0 успех, 1 отказ/ошибка.

set -uo pipefail

mode="${1:?Использование: $0 apply|restore ...}"
shift

if [ "$mode" = "restore" ]; then
  backup_path="${1:?Использование: $0 restore <backup_path> <config_path>}"
  config_path="${2:?config_path обязателен}"
  [ -f "$backup_path" ] || { echo "backup не найден: $backup_path" >&2; exit 1; }
  [ -s "$backup_path" ] || { echo "backup пуст: $backup_path -- отказ, не буду откатывать на пустой файл." >&2; exit 1; }
  [ -f "$config_path" ] || { echo "Конфиг не найден: $config_path" >&2; exit 1; }

  pre_restore_backup="${backup_path%.bak}.pre-restore-$(date +%Y%m%d-%H%M%S).bak"
  cp -p "$config_path" "$pre_restore_backup" || { echo "Не удалось сделать pre-restore backup в $pre_restore_backup -- отказ, ничего не менял." >&2; exit 1; }

  if ! cp -p "$backup_path" "$config_path"; then
    echo "Не удалось восстановить $config_path из $backup_path (сломанный конфиг сохранён отдельно: $pre_restore_backup)" >&2
    exit 1
  fi
  echo "restored: $config_path <- $backup_path (сломанная версия сохранена: $pre_restore_backup)" >&2
  exit 0
fi

if [ "$mode" != "apply" ]; then
  echo "Неизвестная команда: '$mode' (ожидался apply или restore)" >&2
  exit 1
fi

after_strategy="${1:?Использование: $0 apply <after_strategy> <config_path> <backup_dir> < spec}"
config_path="${2:?config_path обязателен}"
backup_dir="${3:?backup_dir обязателен}"

if ! printf '%s' "$after_strategy" | grep -Eq '^[0-9]+$'; then
  echo "after_strategy должен быть неотрицательным числом, получено: '$after_strategy'" >&2
  exit 1
fi

[ -f "$config_path" ] || { echo "Конфиг не найден: $config_path" >&2; exit 1; }

header=()
body=()
template_name=""
spec_mode=""
section=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    HEADER) spec_mode="header"; section=header; continue ;;
    TEMPLATE) spec_mode="template"; section=template; continue ;;
    BODY) section=body; continue ;;
  esac
  case "$section" in
    header) header+=("$line") ;;
    template)
      if [ -n "$template_name" ]; then
        echo "TEMPLATE-секция ожидает РОВНО одну строку (имя шаблона), получена вторая: '$line'" >&2
        exit 1
      fi
      template_name="$line"
      ;;
    body) body+=("$line") ;;
    *) echo "Строка до маркера HEADER/TEMPLATE: '$line' -- неверный формат stdin" >&2; exit 1 ;;
  esac
done

if [ "$spec_mode" != "header" ] && [ "$spec_mode" != "template" ]; then
  echo "spec должен начинаться с HEADER или TEMPLATE" >&2
  exit 1
fi
if [ "$spec_mode" = "header" ] && [ "${#header[@]}" -eq 0 ]; then
  echo "Пустой HEADER -- нечем искать блок профиля" >&2
  exit 1
fi
if [ "$spec_mode" = "template" ] && [ -z "$template_name" ]; then
  echo "Пустой TEMPLATE -- не указано имя шаблона" >&2
  exit 1
fi
if [ "${#body[@]}" -eq 0 ]; then
  echo "Пустой BODY -- нечего добавлять" >&2
  exit 1
fi

mapfile -t config_lines < "$config_path"
total_lines="${#config_lines[@]}"

start_idx=-1
anchor_len=1
if [ "$spec_mode" = "header" ]; then
  # Найти СТРОГО контигуальное вхождение всех строк header по порядку --
  # начало блока профиля. Якорится по первой строке заголовка, дальше
  # построчно сверяет остаток.
  anchor_len="${#header[@]}"
  first_header_line="${header[0]}"
  for ((i = 0; i < total_lines; i++)); do
    [ "${config_lines[$i]}" = "$first_header_line" ] || continue
    match=1
    for ((j = 1; j < ${#header[@]}; j++)); do
      if [ "${config_lines[$((i + j))]:-}" != "${header[$j]}" ]; then
        match=0
        break
      fi
    done
    if [ "$match" -eq 1 ]; then
      start_idx="$i"
      break
    fi
  done
  if [ "$start_idx" -lt 0 ]; then
    echo "Заголовок блока не найден в $config_path -- профиль переехал в файле или переданный HEADER разошёлся с реальным конфигом. Отказ, ничего не менял." >&2
    exit 1
  fi
else
  # TEMPLATE -- один якорь, буквальная строка "--template=<имя>".
  template_line="--template=${template_name}"
  for ((i = 0; i < total_lines; i++)); do
    if [ "${config_lines[$i]}" = "$template_line" ]; then
      start_idx="$i"
      break
    fi
  done
  if [ "$start_idx" -lt 0 ]; then
    echo "Строка '$template_line' не найдена в $config_path -- имя шаблона неверное или конфиг изменился. Отказ, ничего не менял." >&2
    exit 1
  fi
fi

block_start=$((start_idx + anchor_len))

# Конец блока -- первая строка "--new" (ровно, без хвостовых пробелов)
# после block_start, либо конец файла, если это последний блок.
block_end="$total_lines"
for ((i = block_start; i < total_lines; i++)); do
  if [ "${config_lines[$i]}" = "--new" ]; then
    block_end="$i"
    break
  fi
done

# Максимум strategy=N СТРОГО внутри [block_start, block_end).
max_found=-1
last_strategy_line_idx=-1
for ((i = block_start; i < block_end; i++)); do
  line="${config_lines[$i]}"
  if [[ "$line" =~ strategy=([0-9]+) ]]; then
    n="${BASH_REMATCH[1]}"
    if [ "$n" -ge "$max_found" ]; then
      max_found="$n"
      last_strategy_line_idx="$i"
    fi
  fi
done

if [ "$last_strategy_line_idx" -lt 0 ]; then
  echo "В найденном блоке нет ни одной строки strategy= -- вставлять после нечего. Отказ." >&2
  exit 1
fi

if [ "$max_found" -ne "$after_strategy" ]; then
  echo "Разошлись ожидания: вызывающий передал after_strategy=$after_strategy, в блоке реально max=$max_found. Отказ -- перечитай текущий max (set_strategy_cli.sh max) и попробуй снова (гонка или устаревшие данные, не гадаю)." >&2
  exit 1
fi

strategy_n=$((after_strategy + 1))

# Паранойя: strategy=$strategy_n не должен уже встречаться в этом блоке.
for ((i = block_start; i < block_end; i++)); do
  case "${config_lines[$i]}" in
    *"strategy=${strategy_n}"[!0-9]*|*"strategy=${strategy_n}")
      echo "strategy=$strategy_n уже встречается в блоке -- отказ, не буду дублировать." >&2
      exit 1
      ;;
  esac
done

mkdir -p "$backup_dir" || { echo "Не удалось создать $backup_dir" >&2; exit 1; }
backup_file="$backup_dir/config.$(date +%Y%m%d-%H%M%S).bak"
cp -p "$config_path" "$backup_file" || { echo "Не удалось сделать backup в $backup_file -- отказ, ничего не менял." >&2; exit 1; }

new_lines=()
for line in "${body[@]}"; do
  new_lines+=("${line}:strategy=${strategy_n}")
done

tmp_file="${config_path}.tmp.$$"
{
  if [ "$last_strategy_line_idx" -ge 0 ]; then
    printf '%s\n' "${config_lines[@]:0:$((last_strategy_line_idx + 1))}"
  fi
  printf '%s\n' "${new_lines[@]}"
  if [ "$((last_strategy_line_idx + 1))" -lt "$total_lines" ]; then
    printf '%s\n' "${config_lines[@]:$((last_strategy_line_idx + 1))}"
  fi
} > "$tmp_file"

if ! mv "$tmp_file" "$config_path"; then
  echo "Не удалось перезаписать $config_path (backup цел: $backup_file, конфиг НЕ тронут)" >&2
  rm -f "$tmp_file"
  exit 1
fi

echo "$strategy_n"
echo "backup: $backup_file" >&2
exit 0
