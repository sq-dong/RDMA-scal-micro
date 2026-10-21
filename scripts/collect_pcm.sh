#!/usr/bin/env bash
# PCM: idle / QP-sweep / footprint benches with pcm-pcie (server side).
#
# Usage:
#   source scripts/setup_machine.sh
#   ./scripts/collect_pcm.sh              # all: idle + qp + foot
#   BENCH=idle|qp|foot ./scripts/collect_pcm.sh
#   NQPS="1 4 8 16" CURVE=in-write-rc-inl ./scripts/collect_pcm.sh
#   BUF_MBS="8 32 64" FOOT_N=8 BENCH=foot ./scripts/collect_pcm.sh
#
# Needs sudo for pcm-pcie. CLT_SET / PIN same as collect_scale.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "${1:-}" =~ ^(server03|s03|thoth|both|dual|split)$ ]]; then
  export CLT_SET=$1
  shift
fi

# shellcheck source=setup_machine.sh
source "$SCRIPT_DIR/setup_machine.sh"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# PCM: official intel/pcm → pcm/build/bin (docs/pcm.md)
PCM_BIN="${PCM_BIN:-$ROOT/pcm/build/bin/pcm-pcie}"
PCM_INTERVAL="${PCM_INTERVAL:-1}"
BENCH="${BENCH:-all}"
CURVE="${CURVE:-in-write-rc-inl}"
FOOT_N="${FOOT_N:-8}"
# shellcheck disable=SC2206
BUF_MBS=(${BUF_MBS:-8 32 64})
TPUT_SEC="${TPUT_SEC:-15}"
PASSIVE_SEC="${PASSIVE_SEC:-$((TPUT_SEC + 10))}"

[[ -x "$PCM_BIN" ]] || {
  log "ERROR: missing $PCM_BIN — build official PCM: see docs/pcm.md"
  exit 1
}

apply_client_set "${CLT_SET:-thoth}"
discover_pin_cpus
sync_bins

RUN_DIR="$RESULTS_DIR/pcm_${RESULT_TAG}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_DIR"
CSV="$RUN_DIR/pcm_summary.csv"
csv_header "$CSV" \
  "bench,n_srv,n_clt,buf_mb,mops,PCIRdCur,RFO,ItoM,RFO_ItoM,curve,clients"

# ---- curve parse (subset; same tokens as collect_scale) ----
parse_curve() {
  local tok=$1
  MODE=""; UC_FLAG=""; INL_FLAG=""; LABEL=""; DIR=""; COUNT=""
  case "$tok" in
    in-write-rc-inl)  MODE=in-write;  UC_FLAG=--rc; INL_FLAG="";         LABEL=In-WRITE-RC-inl; DIR=in; COUNT=clt ;;
    in-write-rc-dma)  MODE=in-write;  UC_FLAG=--rc; INL_FLAG=--no-inline; LABEL=In-WRITE-RC-dma; DIR=in; COUNT=clt ;;
    in-write-uc-inl)  MODE=in-write;  UC_FLAG=--uc; INL_FLAG="";         LABEL=In-WRITE-UC-inl; DIR=in; COUNT=clt ;;
    out-write-rc-inl) MODE=out-write; UC_FLAG=--rc; INL_FLAG="";         LABEL=Out-WRITE-RC-inl; DIR=out; COUNT=srv ;;
    out-write-uc-inl) MODE=out-write; UC_FLAG=--uc; INL_FLAG="";         LABEL=Out-WRITE-UC-inl; DIR=out; COUNT=srv ;;
    *) log "ERROR: unsupported CURVE='$tok' for PCM collect"; exit 1 ;;
  esac
}

# PCM: median of per-sample socket-0 counters (NIC on NUMA0).
pcm_median() {
  local raw=$1
  python3 - "$raw" <<'PY'
import sys, statistics as st
path = sys.argv[1]
rows = []
with open(path) as f:
    hdr = None
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split(",")]
        if hdr is None:
            hdr = [p.lower() for p in parts]
            continue
        if len(parts) < len(hdr):
            continue
        d = dict(zip(hdr, parts))
        skt = d.get("skt", "")
        if skt not in ("0", "0.0"):
            continue
        def num(k):
            try: return float(d.get(k, "0") or 0)
            except ValueError: return 0.0
        # PCM: Cascade Lake names PCIRdCur / RFO / ItoM
        rows.append((num("pcirdcur"), num("rfo"), num("itom")))
if not rows:
    print("0,0,0,0")
    sys.exit(0)
# drop first/last sample (startup / teardown)
if len(rows) > 4:
    rows = rows[1:-1]
def med(i):
    return st.median(r[i] for r in rows)
pc, rfo, itom = med(0), med(1), med(2)
print(f"{pc:.0f},{rfo:.0f},{itom:.0f},{rfo+itom:.0f}")
PY
}

# PCM: start/stop sampler around one RDMA point
PCM_PID=""
pcm_start() {
  local raw=$1
  sudo "$PCM_BIN" -csv="$raw" "$PCM_INTERVAL" >/dev/null 2>"${raw}.err" &
  PCM_PID=$!
  sleep 2
}
pcm_stop() {
  if [[ -n "${PCM_PID:-}" ]]; then
    sudo kill "$PCM_PID" 2>/dev/null || true
    wait "$PCM_PID" 2>/dev/null || true
    PCM_PID=""
  fi
}
trap 'pcm_stop; kill_bench "$SRV_HOST"; kill_all_clients' EXIT

PORT_BASE=18740
idx=0

launch_clients() {
  local n_clt=$1 port=$2 mode=$3 peers_q=$4 duration=$5 logdir=$6 buf_flag=$7
  local host lo hi cdev cgid cpulist
  while read -r host lo hi; do
    [[ -n "$host" ]] || continue
    cdev=$(client_dev_for "$host")
    cgid=$(client_gid_for "$host")
    cpulist="${HOST_PIN_CPUS[$host]:-}"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$host" bash -s <<EOF
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
    -M $mode -q $peers_q -I \$i -t $POSTLIST -l $SIZE -Q $UNSIG -D $duration \
    \$cflag $UC_FLAG $INL_FLAG $buf_flag >'$logdir'/clt_\$i.log 2>&1 &
done
wait
grep -hE '^scale ${LABEL}:' '$logdir'/clt_*.log 2>/dev/null || true
EOF
  done < <(client_id_ranges "$n_clt")
}

# One RDMA + PCM sample point → append summary CSV
run_point() {
  local bench=$1 n_srv=$2 buf_mb=$3
  local n_clt=$((n_srv * CLT_MULT))
  local port=$((PORT_BASE + idx * 128))
  idx=$((idx + 1))
  local tag="${bench}_N${n_srv}_B${buf_mb}"
  local logdir="$RUN_DIR/$tag"
  mkdir -p "$logdir"
  local raw="$logdir/pcm_raw.csv"
  local buf_flag=""
  [[ "$buf_mb" -gt 0 ]] && buf_flag="-B $buf_mb"

  local ms_dur clt_dur
  if [[ "$COUNT" == "srv" ]]; then
    ms_dur=$TPUT_SEC
    clt_dur=$PASSIVE_SEC
  else
    ms_dur=$PASSIVE_SEC
    clt_dur=$TPUT_SEC
  fi

  log "PCM $bench n=$n_srv buf_mb=$buf_mb curve=$CURVE port=$port"
  local -a ms_pids=()
  local i pin_flag
  for i in $(seq 0 $((n_srv - 1))); do
    pin_flag=$(ms_pin_flag "$i")
    # shellcheck disable=SC2086
    (cd "$BENCH_DIR" && ./scale_bench -s -d "$SRV_DEV" -a "$SRV_IP" -p "$port" \
      -x "$SRV_GID" -M "$MODE" -q "$n_clt" -I "$i" -t "$POSTLIST" -l "$SIZE" \
      -Q "$UNSIG" -D "$ms_dur" $pin_flag $UC_FLAG $INL_FLAG $buf_flag) \
      >"$logdir/ms_$i.log" 2>&1 &
    ms_pids+=($!)
  done
  sleep 1

  # PCM: sample while traffic is live
  pcm_start "$raw"

  local summary=""
  if [[ "$COUNT" == "clt" ]]; then
    summary=$(launch_clients "$n_clt" "$port" "$MODE" "$n_srv" "$clt_dur" "$logdir" "$buf_flag")
    for pid in "${ms_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  else
    launch_clients "$n_clt" "$port" "$MODE" "$n_srv" "$clt_dur" "$logdir" "$buf_flag" >/dev/null &
    local clt_bg=$!
    for pid in "${ms_pids[@]}"; do wait "$pid" || true; done
    kill "$clt_bg" 2>/dev/null || true
    wait "$clt_bg" 2>/dev/null || true
  fi

  pcm_stop
  kill_bench "$SRV_HOST"
  kill_all_clients
  sleep 0.3

  local mops
  if [[ "$COUNT" == "clt" ]]; then
    printf '%s\n' "$summary" >"$logdir/summary.txt"
    mops=$(printf '%s\n' "$summary" | sum_mops_grep)
  else
    mops=$(sum_mops_files "scale ${LABEL}:" "$logdir"/ms_*.log)
  fi
  [[ -n "$mops" ]] || mops=0

  # PCM: aggregate
  local agg
  agg=$(pcm_median "$raw")
  IFS=',' read -r pc rfo itom rfo_itom <<<"$agg"
  log "  mops=$mops  PCIRdCur=$pc RFO=$rfo ItoM=$itom"
  append_csv "$CSV" \
    "$bench,$n_srv,$n_clt,$buf_mb,$mops,$pc,$rfo,$itom,$rfo_itom,$CURVE,$RESULT_TAG"
}

sum_mops_grep() {
  awk '
    { for (i = 1; i <= NF; i++)
        if ($i == "Mops" && i > 1) { s += $(i - 1); break } }
    END { if (s != "") printf "%.2f", s; else printf "0" }'
}

# ---- benches ----
do_idle() {
  local raw="$RUN_DIR/idle_pcm_raw.csv"
  log "PCM idle ${TPUT_SEC}s"
  pcm_start "$raw"
  sleep "$TPUT_SEC"
  pcm_stop
  local agg
  agg=$(pcm_median "$raw")
  IFS=',' read -r pc rfo itom rfo_itom <<<"$agg"
  append_csv "$CSV" "idle,0,0,0,0,$pc,$rfo,$itom,$rfo_itom,none,$RESULT_TAG"
  log "  idle PCIRdCur=$pc RFO=$rfo ItoM=$itom"
}

do_qp() {
  parse_curve "$CURVE"
  local n
  for n in "${NQPS[@]}"; do
    run_point "qp" "$n" 0
  done
}

do_foot() {
  parse_curve "$CURVE"
  local b
  for b in "${BUF_MBS[@]}"; do
    run_point "foot" "$FOOT_N" "$b"
  done
}

log "RUN_DIR=$RUN_DIR BENCH=$BENCH CURVE=$CURVE"
case "$BENCH" in
  idle) do_idle ;;
  qp)   do_qp ;;
  foot) do_foot ;;
  all)  do_idle; do_qp; do_foot ;;
  *) log "ERROR: BENCH=$BENCH (idle|qp|foot|all)"; exit 1 ;;
esac

log "done: $CSV"
column -t -s, "$CSV" 2>/dev/null || cat "$CSV"
