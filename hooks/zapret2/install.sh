#!/usr/bin/env bash
# Ставит хуки zapret2 из этого каталога в custom.d боевого zapret2 (идемпотентно).
set -euo pipefail
SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for d in /opt/zapret2/init.d/sysv/custom.d /opt/zapret2/init.d/openwrt/custom.d; do
  [ -d "$d" ] || continue
  for f in "$SRC"/[0-9][0-9]-*.sh; do install -m 644 "$f" "$d/$(basename "$f")"; echo "-> $d/$(basename "$f")"; done
done
echo "Применится при следующем перезапуске zapret2 (systemctl restart zapret2)."
