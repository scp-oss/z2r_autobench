#!/usr/bin/env bash
# gen_strategies_yaml.sh — генерирует config/strategies.yaml для
# zapret-voice-bot на основе реального числа стратегий профиля (через
# ту же config_profile_max_strategy(), что использует остальная автоматика),
# вместо ручного перечисления.
#
# Использование:
#   ./gen_strategies_yaml.sh > config/strategies.yaml            # только VOICE_UDP (профиль 6)
#   ./gen_strategies_yaml.sh --with-discord > config/strategies.yaml  # + DS_TLS (профиль 4) комбинациями
#
# apply_cmd в каждой записи вызывает set_strategy_cli.sh — единую точку
# правды для переключения стратегий, ту же, что используют rank_*.sh.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/set_strategy_cli.sh"
WITH_DISCORD=0

[ "${1:-}" = "--with-discord" ] && WITH_DISCORD=1

# shellcheck disable=SC1091
source "$SCRIPT_DIR/z2r_autobench_lib.sh" >/dev/null 2>&1

max_voice="$(config_profile_max_strategy "6" "")"
max_ds="$(config_profile_max_strategy "4" "")"

echo "# Автосгенерировано gen_strategies_yaml.sh — не редактировать руками,"
echo "# перегенерировать при изменении числа стратегий в /opt/zapret2/config."
echo "strategies:"

for ((s=1; s<=max_voice; s++)); do
  cat << EOF
  - name: voice_${s}
    description: "VOICE_UDP=${s}"
    apply_cmd: "sudo bash ${CLI} set 6 udp ${s}"
EOF
done

if [ "$WITH_DISCORD" = "1" ]; then
  for ((s=1; s<=max_ds; s++)); do
    cat << EOF
  - name: discord_tls_${s}
    description: "DS_TLS=${s} (только TCP-сигналинг, не голос)"
    apply_cmd: "sudo bash ${CLI} set 4 tls ${s}"
EOF
  done
fi
