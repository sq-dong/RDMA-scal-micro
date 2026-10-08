#!/usr/bin/env bash
# setup_machine.sh - source before collect_scale.sh
#
# Current RoCE fabric: 10.0.0.0/24 on CX-5 ports.
# Client inventory matches rdma_verb_test/scripts/setup_machine.sh.
# Select which clients to use via CLT_SET (see config.sh / collect_scale.sh):
#   server03 | thoth | both
#
# Verify with: show_gids | grep 10.0.0
#
# shellcheck shell=bash

export BENCH_DIR="${BENCH_DIR:-$HOME/rdma_scal}"
export RESULTS_DIR="${RESULTS_DIR:-$BENCH_DIR/results}"

# ---- Server (MS) : smartx-server02 ----
export SRV_HOST="${SRV_HOST:-local}"
export SRV_DEV="${SRV_DEV:-mlx5_0}"
export SRV_IP="${SRV_IP:-10.0.0.20}"
export SRV_GID="${SRV_GID:-4}"   # RoCEv2 GID for 10.0.0.20

# ---- Client 1: server03 ----
export CLT_HOST="${CLT_HOST:-server03}"
export CLT_DEV="${CLT_DEV:-mlx5_3}"
export CLT_IP="${CLT_IP:-10.0.0.21}"
export CLT_GID="${CLT_GID:-3}"   # RoCEv2 GID for 10.0.0.21

# ---- Client 2: thoth ----
export CLT_HOST2="${CLT_HOST2:-thoth}"
export CLT_DEV2="${CLT_DEV2:-mlx5_1}"
export CLT_IP2="${CLT_IP2:-10.0.0.22}"
export CLT_GID2="${CLT_GID2:-3}" # RoCEv2 GID for 10.0.0.22

export SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no}"

echo "setup_machine.sh loaded:"
echo "  BENCH_DIR=$BENCH_DIR"
echo "  SRV: host=$SRV_HOST dev=$SRV_DEV ip=$SRV_IP gid=$SRV_GID"
echo "  CLT1: host=$CLT_HOST dev=$CLT_DEV ip=$CLT_IP gid=$CLT_GID"
echo "  CLT2: host=$CLT_HOST2 dev=$CLT_DEV2 ip=$CLT_IP2 gid=$CLT_GID2"
echo "  CLT_SET=${CLT_SET:-server03}  # server03 | thoth | both"
