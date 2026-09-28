#!/usr/bin/env bash
# Collect scalability matrix → results/scale.csv
#
# Usage:
#   source ./scripts/setup_machine.sh
#   ./scripts/collect_scale.sh
#   CURVES="out-write-uc-inl out-send-ud-inl" NQPS="1 2 4 8" ./scripts/collect_scale.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

CSV="$RESULTS_DIR/scale.csv"
rm -f "$CSV"
csv_header "$CSV" "curve,n,active_q_or_dest,mops,size,postlist,unsig,inline"

trap 'kill_bench "$SRV_HOST"; kill_bench "$CLT_HOST"; rm -rf "$RESULTS_DIR"/scale_N* 2>/dev/null || true' EXIT

log "scale sweep size=${SIZE}B postlist=$POSTLIST unsig=$UNSIG N∈${NQPS[*]}"
log "curves: $CURVES"
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
    out-send-ud|in-send-ud) echo "$n" ;;
    *) echo $((n * n)) ;;
  esac
}

# Outbound: MS sends (wait MS), clients passive (kill after).
run_outbound() {
  local n=$1
  local port=$((PORT_BASE + idx * 64))
  idx=$((idx + 1))
  local logdir="$RESULTS_DIR/scale_N${n}_${tok}"
  mkdir -p "$logdir"
  local inl_note=1
  [[ "$INL_FLAG" == "--no-inline" ]] && inl_note=0
  local qmetric
  qmetric=$(active_metric "$MODE" "$n")
  log "$LABEL paper_N=$n port=$port (outbound)"

  local -a ms_pids=()
  local i n_ms=$n
  if [[ "$MODE" == "out-send-ud" ]]; then
    n_ms=1
  fi

  for i in $(seq 0 $((n_ms - 1))); do
    # shellcheck disable=SC2086
    (cd "$BENCH_DIR" && ./scale_bench -s -d "$SRV_DEV" -a "$SRV_IP" -p "$port" \
      -x "$SRV_GID" -M "$MODE" -q "$n" -I "$i" -t "$POSTLIST" -l "$SIZE" \
      -Q "$UNSIG" -D "$TPUT_SEC" $UC_FLAG $INL_FLAG) \
      >"$logdir/ms_$i.log" 2>&1 &
    ms_pids+=($!)
  done
  sleep 1

  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$CLT_HOST" "cd '$BENCH_DIR' && mkdir -p '$logdir' && \
    for i in \$(seq 0 $((n - 1))); do \
      ./scale_bench -c -d $CLT_DEV -a $SRV_IP -p $port -x $CLT_GID \
        -M $MODE -q $n -I \$i -t $POSTLIST -l $SIZE -Q $UNSIG -D $PASSIVE_SEC \
        $UC_FLAG $INL_FLAG >$logdir/clt_\$i.log 2>&1 & \
    done; wait" &
  local clt_ssh=$!

  for pid in "${ms_pids[@]}"; do wait "$pid" || true; done
  kill "$clt_ssh" 2>/dev/null || true
  wait "$clt_ssh" 2>/dev/null || true
  kill_bench "$SRV_HOST"
  kill_bench "$CLT_HOST"

  local mops
  mops=$(sum_mops_files "scale ${LABEL}:" "$logdir"/ms_*.log)
  [[ -n "$mops" ]] || mops=0
  log "$LABEL N=$n Q/dest=$qmetric total=${mops} Mops"
  append_csv "$CSV" "$LABEL,$n,$qmetric,$mops,$SIZE,$POSTLIST,$UNSIG,$inl_note"
  rm -rf "$logdir"
}

# Inbound: clients send (wait via SSH), MS passive (kill after).
run_inbound() {
  local n=$1
  local port=$((PORT_BASE + idx * 64))
  idx=$((idx + 1))
  local logdir="$RESULTS_DIR/scale_N${n}_${tok}"
  mkdir -p "$logdir"
  local inl_note=1
  [[ "$INL_FLAG" == "--no-inline" ]] && inl_note=0
  local qmetric
  qmetric=$(active_metric "$MODE" "$n")
  log "$LABEL paper_N=$n port=$port (inbound)"

  local -a ms_pids=()
  local i n_ms=$n
  if [[ "$MODE" == "in-send-ud" ]]; then
    n_ms=1
  fi

  for i in $(seq 0 $((n_ms - 1))); do
    # shellcheck disable=SC2086
    (cd "$BENCH_DIR" && ./scale_bench -s -d "$SRV_DEV" -a "$SRV_IP" -p "$port" \
      -x "$SRV_GID" -M "$MODE" -q "$n" -I "$i" -t "$POSTLIST" -l "$SIZE" \
      -Q "$UNSIG" -D "$PASSIVE_SEC" $UC_FLAG $INL_FLAG) \
      >"$logdir/ms_$i.log" 2>&1 &
    ms_pids+=($!)
  done
  sleep 1

  local summary
  # shellcheck disable=SC2086
  summary=$(ssh $SSH_OPTS "$CLT_HOST" bash -s <<EOF
set -e
cd '$BENCH_DIR'
LOGDIR='$logdir'
mkdir -p "\$LOGDIR"
rm -f "\$LOGDIR"/clt_*.log
for i in \$(seq 0 $((n - 1))); do
  ./scale_bench -c -d $CLT_DEV -a $SRV_IP -p $port -x $CLT_GID \
    -M $MODE -q $n -I \$i -t $POSTLIST -l $SIZE -Q $UNSIG -D $TPUT_SEC \
    $UC_FLAG $INL_FLAG \
    >"\$LOGDIR/clt_\$i.log" 2>&1 &
done
wait
grep -h '^scale ${LABEL}:' "\$LOGDIR"/clt_*.log || true
EOF
)

  for pid in "${ms_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  kill_bench "$SRV_HOST"
  kill_bench "$CLT_HOST"
  sleep 0.3

  printf '%s\n' "$summary" >"$logdir/summary.txt"
  local mops
  mops=$(printf '%s\n' "$summary" | awk '
    /^scale / {
      for (i = 1; i <= NF; i++)
        if ($i == "Mops" && i > 1) { s += $(i - 1); break }
    }
    END { if (s != "") printf "%.2f", s; else printf "0" }')
  log "$LABEL N=$n Q/dest=$qmetric total=${mops} Mops"
  append_csv "$CSV" "$LABEL,$n,$qmetric,$mops,$SIZE,$POSTLIST,$UNSIG,$inl_note"
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

log "done → $CSV"
column -t -s, "$CSV" 2>/dev/null || cat "$CSV"
