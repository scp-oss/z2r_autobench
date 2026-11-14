#!/usr/bin/env python3
# Вносит блоки wssize_ramp из zator googlevideo-fix-beta.15 в /opt/zapret2/config (идемпотентно)
import sys, re
p = sys.argv[1] if len(sys.argv) > 1 else "/opt/zapret2/config"
s = open(p).read()
if "Z2R_WSSIZE_RAMP_ENABLE" in s:
    print("already patched"); sys.exit(0)
VARS = """# Experimental Googlevideo-list wssize_ramp settings (zator googlevideo-fix-beta.15).
Z2R_WSSIZE_RAMP_ENABLE=1
Z2R_WSSIZE_MARK=0x04000000
Z2R_WSSIZE_RAMP_IPSET=/opt/zator/lists/googlevideo-ipv4.txt
Z2R_WSSIZE_RAMP_MODE=full
Z2R_WSSIZE_RAMP_WSIZE=1
Z2R_WSSIZE_RAMP_SCALE=1
Z2R_WSSIZE_RAMP_OPEN=1
Z2R_WSSIZE_RAMP_ARGS=
Z2R_WSSIZE_RAMP_SKIP=--skip
if [ "$Z2R_WSSIZE_RAMP_ENABLE" = 1 ]; then
  Z2R_WSSIZE_RAMP_ARGS=":mode=$Z2R_WSSIZE_RAMP_MODE:wsize=$Z2R_WSSIZE_RAMP_WSIZE:scale=$Z2R_WSSIZE_RAMP_SCALE:open=$Z2R_WSSIZE_RAMP_OPEN"
  Z2R_WSSIZE_RAMP_SKIP=
fi
"""
PROFILE = """# Googlevideo-list profile must precede hostlist profiles, which otherwise win first.
${Z2R_WSSIZE_RAMP_SKIP} --filter-l3=ipv4 --filter-tcp=443 --filter-mark=${Z2R_WSSIZE_MARK}/${Z2R_WSSIZE_MARK}
--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello
--out-range=-s34228
--out-range=a
--in-range=a
--payload=all,empty
--lua-desync=wssize_ramp${Z2R_WSSIZE_RAMP_ARGS}
--in-range=-s32768 --lua-desync=rst_guard_locked:key=2:exclude_substrings=/opt/zator/lists/netrogat_substrings.txt:payload=tls_client_hello
--import=z2r_tcp_tls_common

--new
"""
lines = s.split("\n")
i = next(k for k,l in enumerate(lines) if l.startswith("NFQWS2_TCP_PKT_IN="))
lines.insert(i+1, VARS.rstrip("\n"))
i = next(k for k,l in enumerate(lines) if l.strip() == "--lua-init=@/opt/zator/lua/fake-adapt.lua")
lines.insert(i+1, "--lua-init=@/opt/zator/lua/wssize-ramp.lua")
i = [k for k,l in enumerate(lines) if l == "#Z2R_AUTO_STANDARD_BEGIN"]
assert len(i) == 1, "need exactly one #Z2R_AUTO_STANDARD_BEGIN"
lines.insert(i[0]+1, PROFILE.rstrip("\n"))
open(p, "w").write("\n".join(lines))
print("patched", p)
