#!/usr/bin/env bash
# setup_machine.sh — source before collect_scale.sh
#
# Current RoCE fabric (2026-09-28): 192.168.101.0/24 on CX-5 ports.
# Verify with: show_gids | grep 192.168.101
#
# shellcheck shell=bash

export BENCH_DIR="${BENCH_DIR:-$HOME/rdma_scal}"
export RESULTS_DIR="${RESULTS_DIR:-$BENCH_DIR/results}"

# ---- Server (MS) : smartx-server02 ----
export SRV_HOST="${SRV_HOST:-local}"
export SRV_DEV="${SRV_DEV:-mlx5_0}"
export SRV_IP="${SRV_IP:-192.168.101.20}"
export SRV_GID="${SRV_GID:-6}"   # RoCEv2 GID for 192.168.101.20

# ---- Client 1 : server03 ----
export CLT_HOST="${CLT_HOST:-server03}"
export CLT_DEV="${CLT_DEV:-mlx5_3}"
export CLT_IP="${CLT_IP:-192.168.101.11}"
export CLT_GID="${CLT_GID:-3}"   # RoCEv2 GID for 192.168.101.11

# ---- Client 2 (optional) : thoth — currently on 192.168.105.3, NOT peered ----
# Leave empty until thoth joins 192.168.101.0/24.
export CLT_HOST2="${CLT_HOST2:-}"
export CLT_DEV2="${CLT_DEV2:-mlx5_1}"
export CLT_IP2="${CLT_IP2:-}"
export CLT_GID2="${CLT_GID2:-3}"

export SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no}"

echo "setup_machine.sh loaded:"
echo "  BENCH_DIR=$BENCH_DIR"
echo "  SRV: host=$SRV_HOST dev=$SRV_DEV ip=$SRV_IP gid=$SRV_GID"
echo "  CLT1: host=$CLT_HOST dev=$CLT_DEV ip=$CLT_IP gid=$CLT_GID"
if [[ -n "${CLT_HOST2:-}" ]]; then
  echo "  CLT2: host=$CLT_HOST2 dev=$CLT_DEV2 ip=$CLT_IP2 gid=$CLT_GID2"
else
  echo "  CLT2: (disabled — thoth not on same RoCE subnet)"
fi
