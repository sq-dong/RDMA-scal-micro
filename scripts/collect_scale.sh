#!/usr/bin/env bash
# Collect scalability matrix into results/scale_<tag>.csv
#
# Usage:
#   source ./scripts/setup_machine.sh
#   ./scripts/collect_scale.sh
#   CLT_SET=thoth ./scripts/collect_scale.sh
#   ./scripts/collect_scale.sh both
#   CURVES="out-write-uc-inl in-write-uc-inl" NQPS="1 2 4 8" CLT_SET=both ./scripts/collect_scale.sh
#
# CLT_SET=server03|thoth|both writes results/scale_<tag>.csv and scale_fig_*_<tag>.*
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional positional: server03 | thoth | both
if [[ "${1:-}" =~ ^(server03|s03|thoth|both|dual|split)$ ]]; then
  export CLT_SET=$1
  shift
fi

# Refresh lab IPs/GIDs (overrides stale exports from an older setup_machine).
# Set KEEP_ENV=1 to keep pre-exported SRV_IP/CLT_* instead.
if [[ "${KEEP_ENV:-0}" != "1" ]]; then
  unset SRV_IP SRV_GID CLT_IP CLT_GID CLT_IP2 CLT_GID2 CLT_DEV CLT_DEV2 2>/dev/null || true
fi
# shellcheck source=setup_machine.sh
source "$SCRIPT_DIR/setup_machine.sh"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
if [[ "$SRV_IP" == 192.168.101.* ]]; then
  log "ERROR: SRV_IP=$SRV_IP looks like the retired fabric; want 10.0.0.20"
  log "       unset SRV_IP SRV_GID; source ./scripts/setup_machine.sh"
  exit 1
fi

apply_client_set "${CLT_SET:-server03}"
discover_pin_cpus

CSV="$RESULTS_DIR/scale_${RESULT_TAG}.csv"
rm -f "$CSV"
csv_header "$CSV" "curve,n,active_q_or_dest,mops,size,postlist,unsig,inline,clients"

trap 'kill_bench "$SRV_HOST"; kill_all_clients; rm -rf "$RESULTS_DIR"/scale_N* 2>/dev/null || true' EXIT

log "scale sweep size=${SIZE}B postlist=$POSTLIST unsig=$UNSIG N∈${NQPS[*]}"
log "curves: $CURVES"
log "results: $CSV"
sync_bins

PORT_BASE=18640
idx=0

parse_curve() {
  local tok=$1
  MODE=""; UC_FLAG=""; INL_FLAG=""; LABEL=""
  case "$tok" in
    out-write-uc-inl)  MODE=out-write; UC_FLAG=--uc; INL_FLAG="";         LABEL=Out-WRITE-UC-inl ;;
    out-write-uc-dma)  MODE=out-write; UC_FLAG=--uc; INL_FLAG=--no-inline; LABEL=Out-WRITE-UC-dma ;;
    out-write-rc-inl)  MODE=out-write; UC_FLAG=--rc; INL_FLAG="";         LABEL=Out-WRITE-RC-inl ;;
    out-write-rc-dma)  MODE=out-write; UC_FLAG=--rc; INL_FLAG=--no-inline; LABEL=Out-WRITE-RC-dma ;;
    in-write-uc-inl)   MODE=in-write;  UC_FLAG=--uc; INL_FLAG="";         LABEL=In-WRITE-UC-inl ;;
    in-write-uc-dma)   MODE=in-write;  UC_FLAG=--uc; INL_FLAG=--no-inline; LABEL=In-WRITE-UC-dma ;;
    in-write-rc-inl)   MODE=in-write;  UC_FLAG=--rc; INL_FLAG="";         LABEL=In-WRITE-RC-inl ;;
    out-read-rc-dma)   MODE=out-read;  UC_FLAG=--rc; INL_FLAG=--no-inline; LABEL=Out-READ-RC-dma ;;
    out-read-rc-inl)   MODE=out-read;  UC_FLAG=--rc; INL_FLAG="";         LABEL=Out-READ-RC-inl ;;
    out-send-ud-inl)   MODE=out-send-ud; UC_FLAG=""; INL_FLAG="";         LABEL=Out-SEND-UD-inl ;;
    out-send-ud-dma)   MODE=out-send-ud; UC_FLAG=""; INL_FLAG=--no-inline; LABEL=Out-SEND-UD-dma ;;
    in-send-ud-inl)    MODE=in-send-ud;  UC_FLAG=""; INL_FLAG="";         LABEL=In-SEND-UD-inl ;;
    in-send-ud-dma)    MODE=in-send-ud;  UC_FLAG=""; INL_FLAG=--no-inline; LABEL=In-SEND-UD-dma ;;
    *) log "ERROR: unknown curve token '$tok'"; exit 1 ;;
  esac
}

active_metric() {
  local mode=$1 n=$2
  case "$mode" in
    out-send-ud) echo $((n * n)) ;;
    in-send-ud)  echo "$n" ;;
    *) echo $((n * n)) ;;
  esac
}

# Launch client procs id=lo..hi on one host.
# bg=1: start ssh in background; sets LAUNCH_PID (do NOT call via $(); kills bg job).
# bg=0: run foreground; stdout is Mops summary lines.
launch_client_range() {
  local host=$1 lo=$2 hi=$3 port=$4 mode=$5 paper_n=$6 duration=$7 logdir=$8 bg=${9:-0}
  local cdev cgid cpulist
  cdev=$(client_dev_for "$host")
  cgid=$(client_gid_for "$host")
  cpulist="${HOST_PIN_CPUS[$host]:-}"
  LAUNCH_PID=""
  if [[ "$lo" -gt "$hi" ]]; then
    return 0
  fi

  # Remote for-loop: map proc id to NIC-local CPU (wrap). Avoid multi-& one-liners.
  local remote_body
  remote_body=$(cat <<EOF
set -e
cd '$BENCH_DIR'
mkdir -p '$logdir'
PIN="${PIN:-1}"
CPUS=($cpulist)
ncpu=\${#CPUS[@]}
for i in \$(seq $lo $hi); do
  cflag=""
  if [[ "\$PIN" == "1" && "\$ncpu" -gt 0 ]]; then
    cflag="-C \${CPUS[\$((i % ncpu))]}"
  fi
  ./scale_bench -c -d $cdev -a $SRV_IP -p $port -x $cgid \
    -M $mode -q $paper_n -I \$i -t $POSTLIST -l $SIZE -Q $UNSIG -D $duration \
    \$cflag $UC_FLAG $INL_FLAG >'$logdir'/clt_\$i.log 2>&1 &
done
wait
EOF
)

  # shellcheck disable=SC2086
  if [[ "$bg" == "1" ]]; then
    ssh $SSH_OPTS "$host" bash -s <<<"$remote_body" &
    LAUNCH_PID=$!
  else
    # Append mops grep for inbound summary
    ssh $SSH_OPTS "$host" bash -s <<EOF
$remote_body
grep -h '^scale ${LABEL}:' '$logdir'/clt_*.log 2>/dev/null || true
EOF
  fi
}

# Outbound: MS sends (wait MS), clients passive (kill after).
run_outbound() {
  local n=$1
  local port=$((PORT_BASE + idx * 64))
  idx=$((idx + 1))
  local logdir="$RESULTS_DIR/scale_N${n}_${tok}_${RESULT_TAG}"
  mkdir -p "$logdir"
  local inl_note=1
  [[ "$INL_FLAG" == "--no-inline" ]] && inl_note=0
  local qmetric
  qmetric=$(active_metric "$MODE" "$n")
  log "$LABEL paper_N=$n port=$port (outbound) clients=$RESULT_TAG"

  local -a ms_pids=()
  local i pin_flag
  for i in $(seq 0 $((n - 1))); do
    pin_flag=$(ms_pin_flag "$i")
    # shellcheck disable=SC2086
    (cd "$BENCH_DIR" && ./scale_bench -s -d "$SRV_DEV" -a "$SRV_IP" -p "$port" \
      -x "$SRV_GID" -M "$MODE" -q "$n" -I "$i" -t "$POSTLIST" -l "$SIZE" \
      -Q "$UNSIG" -D "$TPUT_SEC" $pin_flag $UC_FLAG $INL_FLAG) \
      >"$logdir/ms_$i.log" 2>&1 &
    ms_pids+=($!)
  done
  sleep 1

  local -a clt_sshs=()
  local host lo hi
  while read -r host lo hi; do
    [[ -n "$host" ]] || continue
    launch_client_range "$host" "$lo" "$hi" "$port" "$MODE" "$n" "$PASSIVE_SEC" "$logdir" 1
    [[ -n "${LAUNCH_PID:-}" ]] && clt_sshs+=("$LAUNCH_PID")
  done < <(client_id_ranges "$n")

  for pid in "${ms_pids[@]}"; do wait "$pid" || true; done
  for pid in "${clt_sshs[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  kill_bench "$SRV_HOST"
  kill_all_clients

  local mops
  mops=$(sum_mops_files "scale ${LABEL}:" "$logdir"/ms_*.log)
  [[ -n "$mops" ]] || mops=0
  log "$LABEL N=$n Q/dest=$qmetric total=${mops} Mops [$RESULT_TAG]"
  append_csv "$CSV" "$LABEL,$n,$qmetric,$mops,$SIZE,$POSTLIST,$UNSIG,$inl_note,$RESULT_TAG"
  rm -rf "$logdir"
}

# Inbound: clients send (wait via SSH), MS passive (kill after).
run_inbound() {
  local n=$1
  local port=$((PORT_BASE + idx * 64))
  idx=$((idx + 1))
  local logdir="$RESULTS_DIR/scale_N${n}_${tok}_${RESULT_TAG}"
  mkdir -p "$logdir"
  local inl_note=1
  [[ "$INL_FLAG" == "--no-inline" ]] && inl_note=0
  local qmetric
  qmetric=$(active_metric "$MODE" "$n")
  log "$LABEL paper_N=$n port=$port (inbound) clients=$RESULT_TAG"

  local -a ms_pids=()
  local i n_ms=$n pin_flag
  if [[ "$MODE" == "in-send-ud" ]]; then
    n_ms=1
  fi

  for i in $(seq 0 $((n_ms - 1))); do
    pin_flag=$(ms_pin_flag "$i")
    # shellcheck disable=SC2086
    (cd "$BENCH_DIR" && ./scale_bench -s -d "$SRV_DEV" -a "$SRV_IP" -p "$port" \
      -x "$SRV_GID" -M "$MODE" -q "$n" -I "$i" -t "$POSTLIST" -l "$SIZE" \
      -Q "$UNSIG" -D "$PASSIVE_SEC" $pin_flag $UC_FLAG $INL_FLAG) \
      >"$logdir/ms_$i.log" 2>&1 &
    ms_pids+=($!)
  done
  sleep 1

  local summary="" part host lo hi
  while read -r host lo hi; do
    [[ -n "$host" ]] || continue
    part=$(launch_client_range "$host" "$lo" "$hi" "$port" "$MODE" "$n" "$TPUT_SEC" "$logdir" 0)
    summary+="$part"$'\n'
  done < <(client_id_ranges "$n")

  for pid in "${ms_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  kill_bench "$SRV_HOST"
  kill_all_clients
  sleep 0.3

  printf '%s\n' "$summary" >"$logdir/summary.txt"
  local mops
  mops=$(printf '%s\n' "$summary" | awk '
    /^scale / {
      for (i = 1; i <= NF; i++)
        if ($i == "Mops" && i > 1) { s += $(i - 1); break }
    }
    END { if (s != "") printf "%.2f", s; else printf "0" }')
  log "$LABEL N=$n Q/dest=$qmetric total=${mops} Mops [$RESULT_TAG]"
  append_csv "$CSV" "$LABEL,$n,$qmetric,$mops,$SIZE,$POSTLIST,$UNSIG,$inl_note,$RESULT_TAG"
  rm -rf "$logdir"
}

for tok in $CURVES; do
  parse_curve "$tok"
  for n in "${NQPS[@]}"; do
    case "$MODE" in
      in-write|in-send-ud) run_inbound "$n" ;;
      *) run_outbound "$n" ;;
    esac
  done
done

log "done: $CSV"
column -t -s, "$CSV" 2>/dev/null || cat "$CSV"

# Auto-plot A/B/C/all (set SKIP_PLOT=1 to skip; PLOT_X=n|q, default n)
if [[ "${SKIP_PLOT:-0}" != "1" ]]; then
  PLOT_X="${PLOT_X:-n}"
  log "plotting figures (x=$PLOT_X): $RESULTS_DIR/scale_fig_{A,B,C,all}_${RESULT_TAG}.{pdf,png}"
  python3 "$SCRIPT_DIR/plot_scale.py" --csv "$CSV" --out-dir "$RESULTS_DIR" --x "$PLOT_X" \
    --suffix "_${RESULT_TAG}"
  log "plot done"
fi
