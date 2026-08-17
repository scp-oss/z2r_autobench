#!/usr/bin/env bash
# autoupdate.sh -- периодическое автообновление всей экосистемы
# z2r_autobench (сам z2r_autobench + Zenith + z0r-panel + Zenith-TG).
#
# Запускается по таймеру (z2r-autoupdate.timer -> z2r-autoupdate.service,
# см. соседние .service/.timer файлы), но можно и вручную:
#   sudo /opt/z2r_autobench/autoupdate.sh [--project NAME]
#
# Конфиг -- /etc/z2r_autobench/autoupdate.conf, простые строки вида
# AUTOUPDATE_<PROJECT>=1 (включено) / =0 или отсутствие строки
# (выключено). Общий для z0r (пункт меню) и z0r-panel (веб) -- оба
# читают/пишут ОДИН И ТОТ ЖЕ файл, чтобы состояние не расходилось.
#
# Отслеживает default-ветку (main) каждого репозитория, НЕ ту feature-
# ветку, с которой сам разрабатывался этот функционал -- автообновление
# продакшена должно идти от того, что реально смержено в main, не от
# чьей-то текущей experimental-работы.
#
# На каждый проект -- отдельный лог (logs/autoupdate/<project>.log) и
# файл последнего успешного обновления (<project>.last_update, формат
# "ISO8601 <было> <стало>") -- z0r/z0r-panel читают ИМЕННО его для
# отображения статуса, не парсят общий лог.

set -uo pipefail

INSTALL_DIR="/opt/z2r_autobench"
ZENITH_DIR="$INSTALL_DIR/Zenith"
PANEL_DIR="$INSTALL_DIR/z0r-panel"
TGRELAY_DIR="$INSTALL_DIR/Zenith-TG"

CONF_DIR="/etc/z2r_autobench"
CONF="$CONF_DIR/autoupdate.conf"
LOG_DIR="$INSTALL_DIR/logs/autoupdate"
mkdir -p "$LOG_DIR"

SET_PROJECT=""
SET_VALUE=""
ONLY_PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) ONLY_PROJECT="$2"; shift 2 ;;
    # --set пишет флаг и выходит, не запускает сам прогон обновления --
    # используется z0r-panel (см. daemon_ctl.py-подобный sudo -n wrapper)
    # для переключения через веб, тем же файлом, что читает/пишет и z0r
    # (пункт меню 26), состояние не расходится.
    --set)
      SET_PROJECT="$2"; SET_VALUE="$3"; shift 3 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$SET_PROJECT" ]; then
  case "$SET_VALUE" in
    0|1) ;;
    *) echo "Значение должно быть 0 или 1, получено: '$SET_VALUE'" >&2; exit 1 ;;
  esac
  case "$SET_PROJECT" in
    z2r_autobench|zenith|panel|tgrelay) ;;
    *) echo "Неизвестный проект: '$SET_PROJECT' (ожидается z2r_autobench|zenith|panel|tgrelay)" >&2; exit 1 ;;
  esac
  mkdir -p "$CONF_DIR"
  touch "$CONF"
  chmod 644 "$CONF"
  local_key="AUTOUPDATE_$(echo "$SET_PROJECT" | tr '[:lower:]' '[:upper:]')"
  if grep -qE "^${local_key}=" "$CONF" 2>/dev/null; then
    sed -i "s/^${local_key}=.*/${local_key}=${SET_VALUE}/" "$CONF"
  else
    echo "${local_key}=${SET_VALUE}" >> "$CONF"
  fi
  echo "$SET_PROJECT: $([ "$SET_VALUE" = "1" ] && echo включено || echo выключено)"
  exit 0
fi

# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

_log() {
  local project="$1"; shift
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG_DIR/${project}.log"
}

# Возврат: 0 -- обновлено, 1 -- ошибка, 2 -- изменений не было (не ошибка).
update_git_repo() {
  local project="$1" dir="$2" branch="${3:-main}"
  if [ ! -d "$dir/.git" ]; then
    _log "$project" "$dir не найден или не git-репозиторий -- пропуск"
    return 1
  fi

  local before after
  before="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || { _log "$project" "не удалось прочитать текущий HEAD"; return 1; }

  if ! git -C "$dir" fetch origin "$branch" --quiet 2>>"$LOG_DIR/${project}.log"; then
    _log "$project" "git fetch не удался (GitHub недоступен?)"
    return 1
  fi

  after="$(git -C "$dir" rev-parse "origin/$branch" 2>/dev/null)" || { _log "$project" "не удалось прочитать origin/$branch"; return 1; }

  if [ "$before" = "$after" ]; then
    return 2
  fi

  # Незакоммиченные локальные правки -- НЕ трогаем автоматически (могут
  # быть чьи-то ручные правки на конкретном узле), просто сообщаем и
  # пропускаем этот прогон, попробуем снова на следующем цикле таймера.
  if ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
    _log "$project" "есть незакоммиченные локальные правки -- пропуск (разберитесь руками)"
    return 1
  fi

  if ! git -C "$dir" pull --ff-only origin "$branch" --quiet >>"$LOG_DIR/${project}.log" 2>&1; then
    _log "$project" "git pull --ff-only не удался (локальная история разошлась с origin?) -- пропуск"
    return 1
  fi

  _log "$project" "обновлено $before -> $after"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $before $after" > "$LOG_DIR/${project}.last_update"
  return 0
}

should_run() {
  local project="$1"
  [ -n "$ONLY_PROJECT" ] && [ "$ONLY_PROJECT" != "$project" ] && return 1
  local var="AUTOUPDATE_${project^^}"
  var="${var//-/_}"
  [ "${!var:-0}" = "1" ]
}

if should_run "z2r_autobench"; then
  if update_git_repo z2r_autobench "$INSTALL_DIR" main; then
    if systemctl is-active --quiet autotune-daemon 2>/dev/null; then
      systemctl restart autotune-daemon
      _log z2r_autobench "autotune-daemon перезапущен"
    fi
  fi
fi

if should_run "zenith"; then
  if update_git_repo zenith "$ZENITH_DIR" main; then
    if ( cd "$ZENITH_DIR" && docker compose up -d --build ) >>"$LOG_DIR/zenith.log" 2>&1; then
      _log zenith "docker compose up -d --build выполнен"
    else
      _log zenith "docker compose up -d --build НЕ удался -- разберитесь руками"
    fi
  fi
fi

if should_run "panel"; then
  if update_git_repo panel "$PANEL_DIR" main; then
    if ( cd "$PANEL_DIR" && venv/bin/pip install -q -r requirements.txt ) >>"$LOG_DIR/panel.log" 2>&1; then
      systemctl restart zenith-panel 2>>"$LOG_DIR/panel.log"
      _log panel "зависимости обновлены, zenith-panel перезапущен"
    else
      _log panel "pip install не удался -- сервис НЕ перезапущен, разберитесь руками"
    fi
  fi
fi

if should_run "tgrelay"; then
  if update_git_repo tgrelay "$TGRELAY_DIR" main; then
    if ( cd "$TGRELAY_DIR" && .venv/bin/pip install -q -r requirements.txt ) >>"$LOG_DIR/tgrelay.log" 2>&1; then
      if [ -f "$TGRELAY_DIR/relay/tg-transparent-relay.service" ]; then
        cp "$TGRELAY_DIR/relay/tg-transparent-relay.service" /etc/systemd/system/tg-transparent-relay.service
        systemctl daemon-reload
      fi
      systemctl restart tg-transparent-relay 2>>"$LOG_DIR/tgrelay.log"
      _log tgrelay "зависимости обновлены, юнит переустановлен, tg-transparent-relay перезапущен"
    else
      _log tgrelay "pip install не удался -- сервис НЕ перезапущен, разберитесь руками"
    fi
  fi
fi
