#!/usr/bin/env bash
# debug_capture.sh -- временная запись трафика клиента для отладки обхода
# («у телефона не грузится YouTube/Instagram» -- что именно не открывается).
#
#   debug_capture.sh start [--client IP] [--iface IF] [--port N] [--minutes M] [--name NAME]
#                          [--cgroup PATH]   трафик ОДНОГО сервиса ДО zapret (напр.
#                          system.slice/x-ui.service -- клиенты Xray/3x-ui): копия
#                          пакетов процесса (TEE в mangle OUTPUT на dummy-интерфейс;
#                          nfqws2 стоит позже -- фейков/дезинхронизации в записи нет),
#                          ответы -- по метке соединения 0x80000000.
#   debug_capture.sh stop [ID]          остановить (по умолчанию все)
#   debug_capture.sh status | list      активные записи / сохранённые файлы
#   debug_capture.sh analyze FILE|ID    сводка: SNI (TCP и QUIC), время рукопожатия,
#                                       без ответа сервера, RST, повторы -- по каждому хосту
#   debug_capture.sh purge [--days D]   удалить старые записи (по умолчанию старше 3 суток)
#
# Ограничения «по умолчанию безопасно»: автостоп через --minutes (по умолчанию 10,
# максимум 60); кольцевой буфер (5 файлов x 50 МБ); snaplen 2048 -- хватает на
# заголовки и рукопожатия TLS/QUIC, полезная нагрузка (и так зашифрованная) не
# нужна. Записи хранятся в $DEBUG_DIR (только root), старше 3 суток удаляются.
# Это трафик пользователей сервера -- держите записи короткими и удаляйте.
set -uo pipefail
export LC_ALL=C   # awk с русской локалью считал время с запятой (0,00)
DEBUG_DIR="${DEBUG_DIR:-/var/lib/z2r-debug}"
MAX_MIN=60
mkdir -p "$DEBUG_DIR" && chmod 700 "$DEBUG_DIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ставлю $2..."; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2" >/dev/null 2>&1 || opkg install "$2" >/dev/null 2>&1; }; command -v "$1" >/dev/null 2>&1 || { echo "!!! нет $1" >&2; exit 1; }; }
default_iface() { if ip link show amn0 >/dev/null 2>&1; then echo amn0; else ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'; fi; }

cmd_start() {
  local client="" iface="" port="" minutes=10 name="" filter cgroup=""
  while [ $# -gt 0 ]; do case "$1" in
    --client) client="$2"; shift 2 ;; --iface) iface="$2"; shift 2 ;; --port) port="$2"; shift 2 ;;
    --minutes) minutes="$2"; shift 2 ;; --name) name="$2"; shift 2 ;; --cgroup) cgroup="$2"; shift 2 ;;
    *) echo "неизвестно: $1" >&2; exit 1 ;; esac; done
  need tcpdump tcpdump
  case "$minutes" in ''|*[!0-9]*) minutes=10 ;; esac; [ "$minutes" -gt $MAX_MIN ] && minutes=$MAX_MIN
  iface="${iface:-$(default_iface)}"
  filter="(tcp or udp)"
  [ -n "$client" ] && filter="$filter and host $client"
  [ -n "$port" ] && filter="$filter and port $port"
  local id; id="$(date +%Y%m%d-%H%M%S)${name:+-$name}${client:+-${client//[^0-9a-zA-Z.]/_}}"
  local unit="z2r-debug-capture-$id"; local -a extra=()
  if [ -n "$cgroup" ]; then
    # Копия пакетов сервиса ДО zapret: TEE в mangle OUTPUT (nfqws2 стоит позже,
    # в postrouting) на отдельный dummy-интерфейс, ответы -- по метке
    # соединения 0x80000000. (NFLOG пробовали: libpcap замолкал через ~2 с.)
    local n=$(( RANDOM % 200 + 20 )) mk=0x80000000; local dev="z2rdbg$n" gw="10.255.$n.2"
    local add="ip link add $dev type dummy && ip link set $dev up && ip addr add 10.255.$n.1/30 dev $dev && ip neigh replace $gw lladdr 02:00:00:00:00:02 dev $dev && iptables -t mangle -I OUTPUT 1 -m cgroup --path $cgroup -j CONNMARK --set-xmark $mk/$mk && iptables -t mangle -I OUTPUT 1 -m cgroup --path $cgroup -j TEE --gateway $gw && iptables -t mangle -I INPUT 1 -m connmark --mark $mk/$mk -j TEE --gateway $gw"
    printf '%s\n' "iptables -t mangle -D OUTPUT -m cgroup --path $cgroup -j TEE --gateway $gw" \
      "iptables -t mangle -D OUTPUT -m cgroup --path $cgroup -j CONNMARK --set-xmark $mk/$mk" \
      "iptables -t mangle -D INPUT -m connmark --mark $mk/$mk -j TEE --gateway $gw" "ip link del $dev" > "$DEBUG_DIR/$id.cleanup.sh"
    bash -c "$add" 2>/dev/null || { echo "!!! не смог поставить TEE для cgroup $cgroup" >&2; bash "$DEBUG_DIR/$id.cleanup.sh" 2>/dev/null; exit 1; }
    iface="$dev"; extra=(--property="ExecStopPost=/bin/bash $DEBUG_DIR/$id.cleanup.sh")
  fi
  systemd-run --unit "$unit" --collect --property=RuntimeMaxSec=$((minutes*60)) "${extra[@]}" \
    tcpdump -Z root -i "$iface" -s 2048 -n -C 50 -W 5 -w "$DEBUG_DIR/$id.pcap" ${filter:+"$filter"} >/dev/null 2>&1 \
    || { echo "!!! не смог запустить tcpdump" >&2; [ -f "$DEBUG_DIR/$id.cleanup.sh" ] && bash "$DEBUG_DIR/$id.cleanup.sh" 2>/dev/null; exit 1; }
  sleep 1
  if ! systemctl is-active --quiet "$unit"; then
    [ -f "$DEBUG_DIR/$id.cleanup.sh" ] && bash "$DEBUG_DIR/$id.cleanup.sh" 2>/dev/null
    echo "!!! tcpdump сразу завершился:" >&2; journalctl -u "$unit" -n 3 --no-pager -o cat >&2; exit 1
  fi
  echo "$iface|$filter|$minutes" > "$DEBUG_DIR/$id.meta"
  echo "Запись $id: iface=$iface фильтр='$filter', автостоп через $minutes мин."
  echo "Остановить: $0 stop $id   Сводка: $0 analyze $id"
}
cmd_stop() {
  local id="${1:-}"
  for u in $(systemctl list-units --plain --no-legend 'z2r-debug-capture-*' 2>/dev/null | awk '{print $1}'); do
    [ -n "$id" ] && [[ "$u" != *"$id"* ]] && continue
    systemctl stop "$u" && echo "остановлено: ${u#z2r-debug-capture-}"
  done
}
cmd_status() { systemctl list-units --plain --no-legend 'z2r-debug-capture-*' 2>/dev/null | awk '{print "идёт: " $1}' | sed 's/z2r-debug-capture-//; s/\.service//' ; true; }
cmd_list() { ls -lh --time-style=+%F_%T "$DEBUG_DIR"/*.pcap* 2>/dev/null | awk '{print $5, $6, $7}' || echo "записей нет"; }
cmd_purge() { local days=3; [ "${1:-}" = "--days" ] && days="$2"; find "$DEBUG_DIR" -type f -mtime +"$days" -print -delete; }

cmd_analyze() {
  local arg="${1:?укажи файл или ID}" files
  need tshark tshark
  if [ -f "$arg" ]; then files="$arg"; else files="$(ls "$DEBUG_DIR/$arg".pcap* 2>/dev/null | tr '\n' ' ')"; fi
  [ -n "$files" ] || { echo "нет записи $arg" >&2; exit 1; }
  local merged; merged="$(mktemp --suffix=.pcap)"; mergecap -w "$merged" $files 2>/dev/null || cp "$(echo $files | awk '{print $1}')" "$merged"
  echo "=== TCP/TLS: SNI -> сервер, время ClientHello->ServerHello, без ответа, RST, повторы ==="
  tshark -r "$merged" -n -Y 'tls.handshake.type==1 or tls.handshake.type==2 or tcp.flags.reset==1 or tcp.analysis.retransmission' \
    -T fields -e frame.time_epoch -e tcp.stream -e ip.dst -e ip.src -e tls.handshake.type -e tls.handshake.extensions_server_name -e tcp.flags.reset -e tcp.analysis.retransmission 2>/dev/null \
  | awk -F'\t' '
    { st=$2 }
    $5=="1" && $6!="" { sni[st]=$6; dst[st]=$3; t1[st]=$1 }
    $5=="2" && (st in t1) && !(st in t2) { t2[st]=$1 }
    $7=="1" { rst[st]++ } $8!="" { rtx[st]++ }
    END {
      for (s in sni) { h=sni[s]; n[h]++; ips[h]=ips[h] (index(ips[h],dst[s]) ? "" : dst[s]" ")
        if (s in t2) { d=t2[s]-t1[s]; ok[h]++; sum[h]+=d; if (d>1) slow[h]++ } else nores[h]++
        r[h]+=rst[s]; x[h]+=rtx[s] }
      printf "%-42s %5s %5s %6s %6s %5s %5s  %s\n","SNI","conn","ok","avg_s",">1s","noSH","RST","IP"
      for (h in n) printf "%-42s %5d %5d %6.2f %6d %5d %5d  %s\n", h, n[h], ok[h], ok[h]?sum[h]/ok[h]:0, slow[h], nores[h], r[h], ips[h]
    }' | sort -k5,5nr -k6,6nr | head -60
  echo; echo "=== QUIC: SNI в Initial (если клиент ходит по UDP/443) ==="
  tshark -r "$merged" -n -Y 'quic && tls.handshake.extensions_server_name' -T fields -e ip.dst -e tls.handshake.extensions_server_name 2>/dev/null | sort | uniq -c | sort -rn | head -30
  echo; echo "=== TCP без единого ответа (SYN без SYN-ACK), по адресам ==="
  tshark -r "$merged" -n -Y 'tcp.flags.syn==1 && tcp.flags.ack==0' -T fields -e tcp.stream -e ip.dst -e tcp.dstport 2>/dev/null | sort -u > "$merged.syn"
  tshark -r "$merged" -n -Y 'tcp.flags.syn==1 && tcp.flags.ack==1' -T fields -e tcp.stream 2>/dev/null | sort -u > "$merged.synack"
  awk 'NR==FNR{a[$1]=1; next} !($1 in a){print $2":"$3}' "$merged.synack" "$merged.syn" | sort | uniq -c | sort -rn | head -20
  rm -f "$merged" "$merged.syn" "$merged.synack"
  echo; echo "Колонки: conn -- соединений, ok -- дошло до ServerHello, avg_s -- среднее время рукопожатия,"
  echo ">1s -- медленных, noSH -- без ответа сервера (обрыв/блок), RST -- сбросов. Файл для Wireshark: $files"
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;; stop) shift; cmd_stop "$@" ;; status) cmd_status ;; list) cmd_list ;;
  analyze) shift; cmd_analyze "$@" ;; purge) shift; cmd_purge "$@" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
