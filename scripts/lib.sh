#!/usr/bin/env bash
# Shared helpers for rdma_scal collectors.
# shellcheck shell=bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_DIR="${BENCH_DIR:-$ROOT}"
RESULTS_DIR="${RESULTS_DIR:-$BENCH_DIR/results}"
mkdir -p "$RESULTS_DIR"

SRV_HOST="${SRV_HOST:-local}"
CLT_HOST="${CLT_HOST:-server03}"
CLT_HOST2="${CLT_HOST2:-}"
SRV_DEV="${SRV_DEV:-mlx5_0}"
CLT_DEV="${CLT_DEV:-mlx5_3}"
CLT_DEV2="${CLT_DEV2:-mlx5_1}"
SRV_IP="${SRV_IP:-192.168.101.20}"
SRV_GID="${SRV_GID:-6}"
CLT_GID="${CLT_GID:-3}"
CLT_GID2="${CLT_GID2:-3}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

remote() {
  local host=$1
  shift
  if [[ -z "$host" || "$host" == "local" || "$host" == "localhost" ]]; then
    bash -lc "$*"
  else
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$host" "$*"
  fi
}

kill_bench() {
  local host=$1
  remote "$host" 'pkill -x scale_bench 2>/dev/null || true; true' || true
}

sync_bins() {
  kill_bench "${SRV_HOST:-local}"
  kill_bench "$CLT_HOST"
  if [[ -n "${CLT_HOST2:-}" ]]; then
    kill_bench "$CLT_HOST2"
  fi
  sleep 0.5
  make -C "$BENCH_DIR" -j"$(nproc)"
  sync_one() {
    local host=$1
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$host" "mkdir -p '$BENCH_DIR'"
    # Atomic replace avoids "Text file busy" on a still-mapped ELF.
    # shellcheck disable=SC2086
    scp $SSH_OPTS -q "$BENCH_DIR/scale_bench" "$host:$BENCH_DIR/scale_bench.new"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$host" "mv -f '$BENCH_DIR/scale_bench.new' '$BENCH_DIR/scale_bench' && chmod +x '$BENCH_DIR/scale_bench'"
  }
  sync_one "$CLT_HOST"
  if [[ -n "${CLT_HOST2:-}" ]]; then
    sync_one "$CLT_HOST2"
  fi
}

csv_header() {
  local file=$1
  local header=$2
  if [[ ! -f "$file" ]]; then
    echo "$header" >"$file"
  fi
}

append_csv() {
  local file=$1
  shift
  echo "$*" >>"$file"
}

sum_mops_files() {
  local pattern=$1
  shift
  local total=0 f line m
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    line=$(grep -E "$pattern" "$f" | tail -1 || true)
    m=$(echo "$line" | sed -n 's/.*: \([0-9.]*\) Mops.*/\1/p')
    [[ -n "$m" ]] || continue
    total=$(python3 -c "print(round(float('$total') + float('$m'), 4))")
  done
  printf '%s' "$total"
}
