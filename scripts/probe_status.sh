#!/usr/bin/env bash
# Probe RNIC / link / GID state on MS + clients → STATUS snapshot.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=setup_machine.sh
source "$SCRIPT_DIR/setup_machine.sh"

OUT="${1:-$BENCH_DIR/STATUS.md}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no}"

probe_host() {
  local role=$1 host=$2
  echo
  echo "### $role ($host)"
  echo '```'
  if [[ "$host" == "local" || "$host" == "localhost" || -z "$host" ]]; then
    hostname
    date -Iseconds
    ibdev2netdev 2>/dev/null || true
    ip -br addr 2>/dev/null | grep -E 'UP|UNKNOWN' || true
    show_gids 2>/dev/null || true
    ibstat 2>/dev/null | grep -E "CA '|State|Rate|Link" || true
    for d in /sys/class/infiniband/mlx5_*; do
      [[ -d "$d" ]] || continue
      echo "device_memory $($d 2>/dev/null; ibv_devinfo -d "$(basename "$d")" 2>/dev/null | grep -E 'hca_id|fw_ver|vendor_part|active_mtu|maximum available|max_qp' | head -20)"
    done
  else
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$host" 'hostname; date -Iseconds; ibdev2netdev; ip -br addr | grep -E "UP|UNKNOWN"; show_gids; ibstat 2>/dev/null | grep -E "CA .|State|Rate|Link"; ibv_devinfo 2>/dev/null | grep -E "hca_id|fw_ver|vendor_part|active_mtu|maximum available|active_speed" | head -40'
  fi
  echo '```'
}

{
  echo "# RDMA / Cluster Status"
  echo
  echo "Generated: $(date -Iseconds)"
  echo
  echo "## Connectivity checklist"
  echo
  echo "| Check | Expected | Notes |"
  echo "|-------|----------|-------|"
  echo "| MS↔CLT1 ping (RoCE IP) | OK | \`$SRV_IP\` ↔ \`$CLT_IP\` |"
  echo "| Same L2 / subnet | yes | RoCEv2 needs shared subnet |"
  echo "| Matching MTU | IB active_mtu equal | prefer eth MTU ≥ 4200 |"
  echo "| GID index | RoCEv2 row for that IPv4 | \`show_gids\` |"
  echo
  echo "## Machine layout (configured)"
  echo
  echo "| Role | Host | Device | Netdev IP | GID (RoCEv2) |"
  echo "|------|------|--------|-----------|--------------|"
  echo "| MS | server02 | \`$SRV_DEV\` | \`$SRV_IP\` | \`$SRV_GID\` |"
  echo "| Client1 | \`$CLT_HOST\` | \`$CLT_DEV\` | \`$CLT_IP\` | \`$CLT_GID\` |"
  if [[ -n "${CLT_HOST2:-}" ]]; then
    echo "| Client2 | \`$CLT_HOST2\` | \`$CLT_DEV2\` | \`$CLT_IP2\` | \`$CLT_GID2\` |"
  else
    echo "| Client2 | thoth | — | **not peered** | disable |"
  fi
  echo
  echo "## Live probe"
  probe_host "MS" "local"
  probe_host "Client1" "$CLT_HOST"
  if [[ -n "${CLT_HOST2:-}" ]]; then
    probe_host "Client2" "$CLT_HOST2"
  else
    echo
    echo "### Client2 (thoth) — skipped (CLT_HOST2 empty)"
  fi
  echo
  echo "## Ping"
  echo '```'
  ping -c 2 -W 1 "$CLT_IP" 2>&1 || true
  echo '```'
  echo
  echo "## Inline ceilings (MS)"
  echo '```'
  if [[ -x /tmp/probe_inl2 ]]; then
    /tmp/probe_inl2 "$SRV_DEV" 2>&1 || true
  else
    echo "(run scripts after building probe, or see STATUS known values: RC/UC 828, UD 956)"
  fi
  echo '```'
} >"$OUT"

echo "wrote $OUT"
