#!/usr/bin/env python3
"""Idempotent local fix for zator googlevideo-fix (beta.15) lib/googlevideo_ips.sh.

Upstream bugs fixed (googlevideo_observe_local):
  1. On "already_reported" / "already_queued" the function returned BEFORE the
     kernel-set insert, so a cache IP seen once was never re-added after a
     zapret2 restart or after its set entry expired.
  2. config_get_var is not defined in the listener process, so FWTYPE was empty
     and the nft/ipset insert silently failed every time (non-OpenWrt hosts).
Also: DNS TTLs are minutes; the kernel entry gets a floor (Z2R_GV_MIN_KERNEL_TTL,
default 3600 s) so long video flows keep the ramp.

usage: patch_googlevideo_ips.py /opt/zator/z2r_lib/googlevideo_ips.sh
"""
import sys

MARK = "# z2r-local fix: always (re)insert into the kernel set"
p = sys.argv[1] if len(sys.argv) > 1 else "/opt/zator/z2r_lib/googlevideo_ips.sh"
s = open(p).read()
if MARK in s:
    print("already patched:", p)
    sys.exit(0)

# 1) cut the kernel-insert block out of googlevideo_observe_local
start = s.index('  fwtype="${GOOGLEVIDEO_KERNEL_FWTYPE:-')
end_pat = '  else\n    return 1\n  fi\n'
end = s.index(end_pat, start) + len(end_pat)
block = s[start:end]
s = s[:start] + s[end:]
old_tail = '  [ "$central" = 0 ] || return 0\n}\n'
assert old_tail in s, "unexpected upstream layout (central guard)"
s = s.replace(old_tail, '}\n', 1)

# 2) FWTYPE fallback + TTL floor, inserted right after the fwtype= line
fw_line = block.split("\n", 1)[0] + "\n"
fallback = (
    '  # z2r-local fix: DNS TTLs are minutes; keep the ramp for at least an hour.\n'
    '  [ "$ttl" -ge "${Z2R_GV_MIN_KERNEL_TTL:-3600}" ] 2>/dev/null || ttl="${Z2R_GV_MIN_KERNEL_TTL:-3600}"\n'
    '  # z2r-local fix: config_get_var is not defined in the listener process.\n'
    r'''  [ -n "$fwtype" ] || fwtype="$(sed -n 's/^FWTYPE=["'\'']\{0,1\}\([a-z]*\).*/\1/p' "${ZAPRET2_ROOT:-/opt/zapret2}/config" 2>/dev/null | tail -n1)"''' '\n'
    '  if [ -z "$fwtype" ]; then\n'
    '    if command -v nft >/dev/null 2>&1 && nft list set inet "$(googlevideo_nft_table_name)" z2r_googlevideo4 >/dev/null 2>&1; then fwtype=nftables\n'
    '    elif command -v ipset >/dev/null 2>&1; then fwtype=iptables; fi\n'
    '  fi\n'
)
block = fw_line + fallback + block.split("\n", 1)[1]
func = ('googlevideo_kernel_add() {\n  ' + MARK + ', independent of\n'
        '  # telemetry dedup (already_reported/already_queued used to skip this).\n'
        '  local ip="$1" ttl="$2" fwtype table\n' + block + '}\n\n')
s = s.replace('googlevideo_observe_local() {', func + 'googlevideo_observe_local() {', 1)

# 3) call it right after the local observation file is written
anchor = '  tail -n 8192 "$tmp" > "${tmp}.bounded" && mv -f "${tmp}.bounded" "$tmp" && mv -f "$tmp" "$GOOGLEVIDEO_LOCAL_FILE"\n'
assert anchor in s, "unexpected upstream layout (local file write)"
s = s.replace(anchor, anchor + '  if [ "$central" = 0 ]; then\n'
              '    googlevideo_kernel_add "$ip" "$ttl" || googlevideo_log "kernel_add_error host=$host ip=$ip"\n'
              '  fi\n', 1)
open(p, "w").write(s)
print("patched:", p)
