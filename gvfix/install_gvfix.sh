#!/bin/bash
# gvfix: install zator "googlevideo-fix" wssize_ramp (upstream AloofLibra/zator, tag $GVFIX_REF)
# on top of an existing zator + zapret2 >= 1.0.7, plus the local collector fix
# (patch_googlevideo_ips.py). Idempotent; makes a backup before touching anything.
#
#   install_gvfix.sh            install / update
#   install_gvfix.sh --status   show what is installed and whether it works
#   install_gvfix.sh --restore [BACKUP.tgz]   roll back to a backup (default: latest)
set -euo pipefail

REF="${GVFIX_REF:-googlevideo-fix-beta.15}"
RAW="https://raw.githubusercontent.com/AloofLibra/zator/$REF"
REL="https://github.com/AloofLibra/zator/releases/download/$REF"
ZATOR=/opt/zator
ZAPRET=/opt/zapret2
CONFIG=$ZAPRET/config
HOOK=$ZAPRET/init.d/sysv/custom.d/90-z2r-wssize-ramp.sh
LISTENER=$ZATOR/tools/googlevideo-dns-listener.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKUPS="${GVFIX_BACKUPS:-/opt/z2r_autobench/backups/gvfix}"
SET=z2r_googlevideo4

log() { printf '[gvfix] %s\n' "$*"; }
die() { printf '[gvfix] ERROR: %s\n' "$*" >&2; exit 1; }

status() {
	local n
	echo "ref:        $(cat $ZATOR/.gvfix_ref 2>/dev/null || echo '-')"
	echo "ramp cfg:   $(grep -E '^Z2R_WSSIZE_RAMP_ENABLE=' $CONFIG 2>/dev/null || echo 'not configured')"
	echo "hook:       $([ -x $HOOK ] && echo present || echo missing)"
	echo "lib fix:    $(grep -q 'z2r-local fix: always (re)insert' $ZATOR/z2r_lib/googlevideo_ips.sh 2>/dev/null && echo applied || echo MISSING)"
	echo "listener:   $(pgrep -f 'googlevideo-dns-listener.sh run' >/dev/null && echo running || echo stopped)"
	n=$(nft list set inet zapret2 $SET 2>/dev/null | tr ',' '\n' | grep -c expires || true)
	echo "kernel set: $n IPs"
	echo "zapret2:    $(systemctl is-active zapret2 2>/dev/null || true)"
}

restore() {
	local b="${1:-$(ls -t $BACKUPS/*.tgz 2>/dev/null | head -1)}"
	[ -s "$b" ] || die "no backup found"
	log "restoring $b"
	[ -x $LISTENER ] && $LISTENER stop || true
	rm -f $HOOK
	tar -C / -xzf "$b"
	systemctl restart zapret2
	log "restored; zapret2: $(systemctl is-active zapret2)"
}

case "${1:-}" in
	--status) status; exit 0 ;;
	--restore) restore "${2:-}"; exit 0 ;;
	""|--install) ;;
	*) die "unknown option $1" ;;
esac

[ "$(id -u)" = 0 ] || die "run as root"
[ -f $CONFIG ] && [ -d $ZATOR ] || die "zator/zapret2 not installed"
NFQ_HELP="$($ZAPRET/nfq2/nfqws2 --help 2>&1 || true)"   # no pipe: grep -q + pipefail = SIGPIPE false negative
case "$NFQ_HELP" in *--filter-mark*) ;; *) die "nfqws2 has no --filter-mark (need zapret2 >= 1.0.7)" ;; esac
grep -q '^#Z2R_AUTO_STANDARD_BEGIN' $CONFIG || die "config has no #Z2R_AUTO_STANDARD_BEGIN"
grep -q -- '--lua-init=@/opt/zator/lua/fake-adapt.lua' $CONFIG || die "config has no fake-adapt.lua lua-init"
case "$(uname -m)" in
	x86_64) ARCH=x86_64 ;; i?86) ARCH=x86 ;; aarch64) ARCH=arm64 ;; armv*) ARCH=arm ;;
	*) die "unsupported arch $(uname -m)" ;;
esac

# 1) backup everything we touch
mkdir -p "$BACKUPS"; TS=$(date +%Y%m%d_%H%M%S)
B="$BACKUPS/gvfix_before_$TS.tgz"
tar -C / -czf "$B" --ignore-failed-read \
	"${CONFIG#/}" "${ZATOR#/}/z2r_lib" "${ZATOR#/}/lua" "${ZATOR#/}/tools" "${ZATOR#/}/lists" \
	$( [ -e $HOOK ] && echo "${HOOK#/}" ) 2>/dev/null
log "backup: $B"

# 2) fetch upstream files into a staging dir (nothing is replaced if a download fails)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fetch() { curl -fsSL --retry 3 -m 60 "$1" -o "$2" || die "download failed: $1"; }
fetch "$RAW/lib/googlevideo_ips.sh"              "$T/googlevideo_ips.sh"
fetch "$RAW/lua/wssize-ramp.lua"                 "$T/wssize-ramp.lua"
fetch "$RAW/tools/googlevideo-dns-listener.sh"   "$T/googlevideo-dns-listener.sh"
fetch "$RAW/tools/wssize-ramp-firewall.sh"       "$T/wssize-ramp-firewall.sh"
fetch "$RAW/lists/googlevideo-ipv4.txt"          "$T/googlevideo-ipv4.txt"
fetch "$REL/z2r-googlevideo-dns-sniffer-linux-$ARCH.gz" "$T/sniffer.gz"
gzip -dc "$T/sniffer.gz" > "$T/googlevideo-dns-sniffer"
for f in googlevideo_ips.sh googlevideo-dns-listener.sh wssize-ramp-firewall.sh; do bash -n "$T/$f" || die "syntax: $f"; done
python3 -I "$HERE/patch_googlevideo_ips.py" "$T/googlevideo_ips.sh"
bash -n "$T/googlevideo_ips.sh" || die "patched lib has syntax errors"

# 3) install
[ -x $LISTENER ] && $LISTENER stop >/dev/null 2>&1 || true
install -D -m 644 "$T/googlevideo_ips.sh"          $ZATOR/z2r_lib/googlevideo_ips.sh
install -D -m 644 "$T/wssize-ramp.lua"             $ZATOR/lua/wssize-ramp.lua
install -D -m 755 "$T/googlevideo-dns-listener.sh" $LISTENER
install -D -m 755 "$T/googlevideo-dns-sniffer"     $ZATOR/tools/bin/googlevideo-dns-sniffer
install -D -m 644 "$T/googlevideo-ipv4.txt"        $ZATOR/lists/googlevideo-ipv4.txt
install -D -m 755 "$T/wssize-ramp-firewall.sh"     $HOOK
python3 -I "$HERE/apply_ramp_config.py" $CONFIG
echo "$REF" > $ZATOR/.gvfix_ref

# 4) restart and verify
systemctl restart zapret2
sleep 3
systemctl is-active --quiet zapret2 || { log "zapret2 failed to start -> rolling back"; restore "$B"; die "rolled back"; }
pgrep -f 'googlevideo-dns-listener.sh run' >/dev/null || $LISTENER start >/dev/null 2>&1 || true
sleep 2
status
nft list set inet zapret2 $SET >/dev/null 2>&1 || die "kernel set $SET missing after restart"
log "done"
