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
CLT_HOST2="${CLT_HOST2:-thoth}"
SRV_DEV="${SRV_DEV:-mlx5_0}"
CLT_DEV="${CLT_DEV:-mlx5_3}"
CLT_DEV2="${CLT_DEV2:-mlx5_1}"
SRV_IP="${SRV_IP:-10.0.0.20}"
SRV_GID="${SRV_GID:-4}"
CLT_GID="${CLT_GID:-3}"
CLT_GID2="${CLT_GID2:-3}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no}"

# Active clients for this run (filled by apply_client_set).
ACTIVE_CLIENTS=()
RESULT_TAG="${RESULT_TAG:-server03}"

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

kill_all_clients() {
  local h
  for h in "${ACTIVE_CLIENTS[@]:-}"; do
    [[ -n "$h" ]] || continue
    kill_bench "$h"
  done
  # Also clear inventory hosts in case ACTIVE_CLIENTS not set yet.
  kill_bench "${CLT_HOST:-server03}"
  if [[ -n "${CLT_HOST2:-}" && "${CLT_HOST2}" != "none" ]]; then
    kill_bench "$CLT_HOST2"
  fi
}

client_dev_for() {
  local host=$1
  if [[ "$host" == "$CLT_HOST" ]]; then
    echo "$CLT_DEV"
  else
    echo "${CLT_DEV2:-$CLT_DEV}"
  fi
}

client_gid_for() {
  local host=$1
  if [[ "$host" == "$CLT_HOST" ]]; then
    echo "$CLT_GID"
  else
    echo "${CLT_GID2:-$CLT_GID}"
  fi
}

# CLT_SET=server03|thoth|both sets ACTIVE_CLIENTS and RESULT_TAG
apply_client_set() {
  local set=${1:-${CLT_SET:-server03}}
  case "$set" in
    server03|s03)
      ACTIVE_CLIENTS=("$CLT_HOST")
      RESULT_TAG=server03
      ;;
    thoth)
      ACTIVE_CLIENTS=("$CLT_HOST2")
      RESULT_TAG=thoth
      ;;
    both|dual|split)
      if [[ -z "${CLT_HOST2:-}" || "$CLT_HOST2" == "none" ]]; then
        log "ERROR: CLT_SET=both requires CLT_HOST2 (thoth)"
        exit 1
      fi
      ACTIVE_CLIENTS=("$CLT_HOST" "$CLT_HOST2")
      RESULT_TAG=both
      ;;
    *)
      log "ERROR: unknown CLT_SET='$set' (want server03|thoth|both)"
      exit 1
      ;;
  esac
  export RESULT_TAG
  log "CLT_SET=$set clients=[${ACTIVE_CLIENTS[*]}] results tag=$RESULT_TAG"
}

# Split proc ids 0..n-1 across ACTIVE_CLIENTS (contiguous halves).
# Prints lines: host start_id end_id_inclusive
client_id_ranges() {
  local n=$1
  local nh=${#ACTIVE_CLIENTS[@]}
  if [[ "$nh" -le 0 ]]; then
    log "ERROR: no ACTIVE_CLIENTS"
    exit 1
  fi
  if [[ "$nh" -eq 1 ]]; then
    echo "${ACTIVE_CLIENTS[0]} 0 $((n - 1))"
    return
  fi
  # both: first ceil(n/2) on CLT1, rest on CLT2
  local n1=$(( (n + nh - 1) / nh ))
  local start=0 i chunk
  for i in $(seq 0 $((nh - 1))); do
    if [[ "$i" -eq $((nh - 1)) ]]; then
      chunk=$((n - start))
    else
      chunk=$n1
      if [[ $((start + chunk)) -gt $n ]]; then
        chunk=$((n - start))
      fi
    fi
    if [[ "$chunk" -le 0 ]]; then
      break
    fi
    echo "${ACTIVE_CLIENTS[$i]} $start $((start + chunk - 1))"
    start=$((start + chunk))
  done
}

sync_bins() {
  kill_bench "${SRV_HOST:-local}"
  kill_all_clients
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
  local h
  # Unique hosts from inventory that we might use.
  declare -A seen=()
  for h in "${ACTIVE_CLIENTS[@]}"; do
    [[ -n "$h" ]] || continue
    [[ -z "${seen[$h]:-}" ]] || continue
    seen[$h]=1
    sync_one "$h"
  done
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

# ---- CPU pinning (NIC NUMA-local, one process per logical CPU) ----
# sched_setaffinity to a single core from the RNIC local_cpulist.
# PIN=0 disables. Default PIN=1.

# Expand sysfs cpulist "0,2,4-6" to space-separated ids.
expand_cpulist() {
  local list=$1
  local p a b i
  local -a out=()
  IFS=',' read -ra parts <<<"$list"
  for p in "${parts[@]}"; do
    p=${p// /}
    [[ -n "$p" ]] || continue
    if [[ "$p" == *-* ]]; then
      a=${p%-*}
      b=${p#*-}
      for ((i = a; i <= b; i++)); do
        out+=("$i")
      done
    else
      out+=("$p")
    fi
  done
  echo "${out[*]}"
}

# Read NIC-local CPU list from host (prefer local_cpulist = device NUMA).
fetch_nic_cpulist_raw() {
  local host=$1
  local ibdev=$2
  remote "$host" "cat /sys/class/infiniband/$ibdev/device/local_cpulist 2>/dev/null || \
    cat /sys/class/infiniband/$ibdev/device/local_cpus 2>/dev/null || true"
}

# Space-separated logical CPUs for host+ibdev.
fetch_nic_cpus() {
  local host=$1
  local ibdev=$2
  local raw
  raw=$(fetch_nic_cpulist_raw "$host" "$ibdev" | tr -d '\r' | head -1)
  raw=${raw// /}
  if [[ -z "$raw" ]]; then
    log "WARN: no local_cpulist for $host/$ibdev; using all online CPUs"
    raw=$(remote "$host" 'cat /sys/devices/system/cpu/online')
    raw=${raw// /}
  fi
  expand_cpulist "$raw"
}

# Pick CPU for process index (wrap if N > #cpus on NIC NUMA).
pin_cpu_at() {
  local cpus_str=$1
  local idx=$2
  local -a arr=($cpus_str)
  local n=${#arr[@]}
  if [[ "$n" -le 0 ]]; then
    echo "-1"
    return
  fi
  echo "${arr[$((idx % n))]}"
}

# Fill SRV_PIN_CPUS (array) and HOST_PIN_CPUS[host]="c0 c1 ..."
# Call after apply_client_set.
discover_pin_cpus() {
  PIN="${PIN:-1}"
  if [[ "$PIN" != "1" ]]; then
    log "PIN=$PIN: CPU pinning disabled"
    SRV_PIN_CPUS_STR=""
    declare -gA HOST_PIN_CPUS=()
    return
  fi
  local raw host d
  SRV_PIN_CPUS_STR=$(fetch_nic_cpus "local" "$SRV_DEV")
  log "MS pin CPUs ($SRV_DEV): $(echo "$SRV_PIN_CPUS_STR" | awk '{print NF}') logical CPUs on NIC NUMA (e.g. $(echo "$SRV_PIN_CPUS_STR" | awk '{print $1,$2,$3,"..."}'))"
  declare -gA HOST_PIN_CPUS=()
  for host in "${ACTIVE_CLIENTS[@]}"; do
    d=$(client_dev_for "$host")
    HOST_PIN_CPUS[$host]=$(fetch_nic_cpus "$host" "$d")
    log "CLT $host pin CPUs ($d): $(echo "${HOST_PIN_CPUS[$host]}" | awk '{print NF}') logical CPUs"
  done
}

# -C flag fragment for proc index on MS / given host (empty if PIN off).
ms_pin_flag() {
  local idx=$1
  if [[ "${PIN:-1}" != "1" || -z "${SRV_PIN_CPUS_STR:-}" ]]; then
    echo ""
    return
  fi
  echo "-C $(pin_cpu_at "$SRV_PIN_CPUS_STR" "$idx")"
}

clt_pin_flag() {
  local host=$1
  local idx=$2
  local list=${HOST_PIN_CPUS[$host]:-}
  if [[ "${PIN:-1}" != "1" || -z "$list" ]]; then
    echo ""
    return
  fi
  echo "-C $(pin_cpu_at "$list" "$idx")"
}
