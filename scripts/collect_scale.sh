#!/usr/bin/env bash
# Collect scalability matrix into results/<run_dir>/scale.csv
#
# Topology: N server procs x (CLT_MULT*N) client procs, full mesh.
# Default: CLT_SET=thoth, TPUT_SEC=30, CLT_MULT=1 (N×N).
#
# Counting (minimize work on the machine under test = server):
#   out-write / out-read : count on server (requester; WRITE has no remote CQE)
#   out-send RC/UD       : count on client RECV (remote)
#   out-send UC          : count on server (UC is unreliable; full-mesh RECV
#                          under-counts badly at high N while local SQ still posts)
#   in-*                 : count on client requester (server is passive)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" =~ ^(server03|s03|thoth|both|dual|split)$ ]]; then
  export CLT_SET=$1
  shift
fi

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
  exit 1
fi

apply_client_set "${CLT_SET:-thoth}"
discover_pin_cpus

if [[ "$CLT_MULT" == "1" ]]; then
  RUN_DIR_NAME="${RESULT_TAG}_${TPUT_SEC}s_N*N_${POSTLIST}"
else
  RUN_DIR_NAME="${RESULT_TAG}_${TPUT_SEC}s_N*${CLT_MULT}N_${POSTLIST}"
fi
RUN_DIR="$RESULTS_DIR/$RUN_DIR_NAME"
if [[ ! -d "$RUN_DIR" ]]; then
  mkdir -p "$RUN_DIR"
  log "created run dir: $RUN_DIR"
else
  log "using existing run dir: $RUN_DIR"
fi

CSV="$RUN_DIR/scale.csv"
# APPEND_CSV=1: keep existing rows (resume). Default: start a fresh CSV.
if [[ "${APPEND_CSV:-0}" == "1" && -f "$CSV" ]]; then
  log "APPEND_CSV=1: appending to existing $CSV"
else
  rm -f "$CSV"
  csv_header "$CSV" "curve,n_srv,n_clt,active_q_or_dest,mops,size,postlist,unsig,inline,clients,count_side"
fi

trap 'kill_bench "$SRV_HOST"; kill_all_clients; if [[ "${KEEP_LOGDIR:-0}" != "1" ]]; then rm -rf "$RUN_DIR"/scale_N* 2>/dev/null || true; fi' EXIT

log "sweep size=${SIZE}B postlist=$POSTLIST unsig=$UNSIG TPUT=${TPUT_SEC}s CLT_MULT=$CLT_MULT"
log "N_srv in ${NQPS[*]}; N_clt = ${CLT_MULT}*N_srv"
log "curves: $CURVES"
log "csv: $CSV"
sync_bins

PORT_BASE=18640
idx=0

# MODE, UC_FLAG (--rc|--uc|--ud), INL_FLAG, LABEL, DIR (out|in), COUNT (srv|clt)
parse_curve() {
  local tok=$1
  MODE=""; UC_FLAG=""; INL_FLAG=""; LABEL=""; DIR=""; COUNT=""
  case "$tok" in
    out-write-uc-inl)  MODE=out-write; UC_FLAG=--uc; INL_FLAG="";         LABEL=Out-WRITE-UC-inl; DIR=out; COUNT=srv ;;
    out-write-uc-dma)  MODE=out-write; UC_FLAG=--uc; INL_FLAG=--no-inline; LABEL=Out-WRITE-UC-dma; DIR=out; COUNT=srv ;;
    out-write-rc-inl)  MODE=out-write; UC_FLAG=--rc; INL_FLAG="";         LABEL=Out-WRITE-RC-inl; DIR=out; COUNT=srv ;;
    out-write-rc-dma)  MODE=out-write; UC_FLAG=--rc; INL_FLAG=--no-inline; LABEL=Out-WRITE-RC-dma; DIR=out; COUNT=srv ;;
    in-write-uc-inl)   MODE=in-write;  UC_FLAG=--uc; INL_FLAG="";         LABEL=In-WRITE-UC-inl;  DIR=in;  COUNT=clt ;;
    in-write-uc-dma)   MODE=in-write;  UC_FLAG=--uc; INL_FLAG=--no-inline; LABEL=In-WRITE-UC-dma;  DIR=in;  COUNT=clt ;;
    in-write-rc-inl)   MODE=in-write;  UC_FLAG=--rc; INL_FLAG="";         LABEL=In-WRITE-RC-inl;  DIR=in;  COUNT=clt ;;
    in-write-rc-dma)   MODE=in-write;  UC_FLAG=--rc; INL_FLAG=--no-inline; LABEL=In-WRITE-RC-dma;  DIR=in;  COUNT=clt ;;
    out-read-rc-dma)   MODE=out-read;  UC_FLAG=--rc; INL_FLAG=--no-inline; LABEL=Out-READ-RC-dma;  DIR=out; COUNT=srv ;;
    out-read-rc-inl)   MODE=out-read;  UC_FLAG=--rc; INL_FLAG="";         LABEL=Out-READ-RC-inl;  DIR=out; COUNT=srv ;;
    in-read-rc-dma)    MODE=in-read;   UC_FLAG=--rc; INL_FLAG=--no-inline; LABEL=In-READ-RC-dma;   DIR=in;  COUNT=clt ;;
    in-read-rc-inl)    MODE=in-read;   UC_FLAG=--rc; INL_FLAG="";         LABEL=In-READ-RC-inl;   DIR=in;  COUNT=clt ;;
    out-send-ud-inl)   MODE=out-send;  UC_FLAG=--ud; INL_FLAG="";         LABEL=Out-SEND-UD-inl;  DIR=out; COUNT=clt ;;
    out-send-ud-dma)   MODE=out-send;  UC_FLAG=--ud; INL_FLAG=--no-inline; LABEL=Out-SEND-UD-dma;  DIR=out; COUNT=clt ;;
    in-send-ud-inl)    MODE=in-send;   UC_FLAG=--ud; INL_FLAG="";         LABEL=In-SEND-UD-inl;   DIR=in;  COUNT=clt ;;
    in-send-ud-dma)    MODE=in-send;   UC_FLAG=--ud; INL_FLAG=--no-inline; LABEL=In-SEND-UD-dma;   DIR=in;  COUNT=clt ;;
    out-send-uc-inl)   MODE=out-send;  UC_FLAG=--uc; INL_FLAG="";         LABEL=Out-SEND-UC-inl;  DIR=out; COUNT=srv ;;
    out-send-uc-dma)   MODE=out-send;  UC_FLAG=--uc; INL_FLAG=--no-inline; LABEL=Out-SEND-UC-dma;  DIR=out; COUNT=srv ;;
    in-send-uc-inl)    MODE=in-send;   UC_FLAG=--uc; INL_FLAG="";         LABEL=In-SEND-UC-inl;   DIR=in;  COUNT=clt ;;
    in-send-uc-dma)    MODE=in-send;   UC_FLAG=--uc; INL_FLAG=--no-inline; LABEL=In-SEND-UC-dma;   DIR=in;  COUNT=clt ;;
    out-send-rc-inl)   MODE=out-send;  UC_FLAG=--rc; INL_FLAG="";         LABEL=Out-SEND-RC-inl;  DIR=out; COUNT=clt ;;
    out-send-rc-dma)   MODE=out-send;  UC_FLAG=--rc; INL_FLAG=--no-inline; LABEL=Out-SEND-RC-dma;  DIR=out; COUNT=clt ;;
    in-send-rc-inl)    MODE=in-send;   UC_FLAG=--rc; INL_FLAG="";         LABEL=In-SEND-RC-inl;   DIR=in;  COUNT=clt ;;
    in-send-rc-dma)    MODE=in-send;   UC_FLAG=--rc; INL_FLAG=--no-inline; LABEL=In-SEND-RC-dma;   DIR=in;  COUNT=clt ;;
    *) log "ERROR: unknown curve token '$tok'"; exit 1 ;;
  esac
}

active_metric() {
  local mode=$1 n_srv=$2 n_clt=$3
  case "$mode" in
    in-send)
      if [[ "$UC_FLAG" == "--ud" ]]; then
        echo "$n_clt"
      else
        echo $((n_srv * n_clt))
      fi
      ;;
    out-send)
      if [[ "$UC_FLAG" == "--ud" ]]; then
        echo $((n_srv * n_clt))
      else
        echo $((n_srv * n_clt))
      fi
      ;;
    *) echo $((n_srv * n_clt)) ;;
  esac
}

# Launch clients id=lo..hi. peers_q = -q for clients (usually n_srv).
# duration: -D for clients. bg=1 background ssh; bg=0 wait and grep LABEL lines.
launch_client_range() {
  local host=$1 lo=$2 hi=$3 port=$4 mode=$5 peers_q=$6 duration=$7 logdir=$8 bg=${9:-0}
  local cdev cgid cpulist
  cdev=$(client_dev_for "$host")
  cgid=$(client_gid_for "$host")
  cpulist="${HOST_PIN_CPUS[$host]:-}"
  LAUNCH_PID=""
  if [[ "$lo" -gt "$hi" ]]; then
    return 0
  fi

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
    -M $mode -q $peers_q -I \$i -t $POSTLIST -l $SIZE -Q $UNSIG -D $duration \
    \$cflag $UC_FLAG $INL_FLAG >'$logdir'/clt_\$i.log 2>&1 &
done
wait
EOF
)

  if [[ "$bg" == "1" ]]; then
    ssh $SSH_OPTS "$host" bash -s <<<"$remote_body" &
    LAUNCH_PID=$!
  else
    ssh $SSH_OPTS "$host" bash -s <<EOF
$remote_body
grep -hE '^scale ${LABEL}:' '$logdir'/clt_*.log 2>/dev/null || true
EOF
  fi
}

sum_mops_grep() {
  # stdin: lines containing "Mops"
  awk '
    {
      for (i = 1; i <= NF; i++)
        if ($i == "Mops" && i > 1) { s += $(i - 1); break }
    }
    END { if (s != "") printf "%.2f", s; else printf "0" }'
}

run_one() {
  local n_srv=$1
  local n_clt=$((n_srv * CLT_MULT))
  local port=$((PORT_BASE + idx * 128))
  idx=$((idx + 1))
  local logdir="$RUN_DIR/scale_N${n_srv}_${tok}"
  mkdir -p "$logdir"
  local inl_note=1
  [[ "$INL_FLAG" == "--no-inline" ]] && inl_note=0
  local qmetric
  qmetric=$(active_metric "$MODE" "$n_srv" "$n_clt")

  # Server -q = client count (peers); client -q = server count.
  local srv_peers=$n_clt
  local clt_peers=$n_srv
  local n_ms=$n_srv
  if [[ "$MODE" == "in-send" && "$UC_FLAG" == "--ud" ]]; then
    n_ms=1
    # In-SEND-UD: each client still uses -q 1 conceptually but connects to MS0;
    # scale_bench in-send-ud path uses -q as listen peer count on server.
    srv_peers=$n_clt
    clt_peers=1
  fi

  log "$LABEL n_srv=$n_srv n_clt=$n_clt port=$port count=$COUNT [$RESULT_TAG]"

  local -a ms_pids=()
  local i pin_flag
  local ms_dur
  if [[ "$DIR" == "out" && "$COUNT" == "srv" ]]; then
    ms_dur=$TPUT_SEC
  elif [[ "$DIR" == "out" && "$COUNT" == "clt" ]]; then
    # Out-SEND: server sends; clients count RECV. Both need duration.
    ms_dur=$TPUT_SEC
  else
    ms_dur=$PASSIVE_SEC
  fi

  for i in $(seq 0 $((n_ms - 1))); do
    pin_flag=$(ms_pin_flag "$i")
    # shellcheck disable=SC2086
    (cd "$BENCH_DIR" && ./scale_bench -s -d "$SRV_DEV" -a "$SRV_IP" -p "$port" \
      -x "$SRV_GID" -M "$MODE" -q "$srv_peers" -I "$i" -t "$POSTLIST" -l "$SIZE" \
      -Q "$UNSIG" -D "$ms_dur" $pin_flag $UC_FLAG $INL_FLAG) \
      >"$logdir/ms_$i.log" 2>&1 &
    ms_pids+=($!)
  done
  sleep 1

  local clt_dur
  if [[ "$COUNT" == "clt" ]]; then
    clt_dur=$TPUT_SEC
  else
    clt_dur=$PASSIVE_SEC
  fi

  local summary="" part host lo hi
  local -a clt_sshs=()
  if [[ "$COUNT" == "clt" ]]; then
    while read -r host lo hi; do
      [[ -n "$host" ]] || continue
      part=$(launch_client_range "$host" "$lo" "$hi" "$port" "$MODE" "$clt_peers" "$clt_dur" "$logdir" 0)
      summary+="$part"$'\n'
    done < <(client_id_ranges "$n_clt")
    for pid in "${ms_pids[@]}"; do
      if [[ "$DIR" == "out" ]]; then
        wait "$pid" || true
      else
        kill "$pid" 2>/dev/null || true
      fi
    done
    if [[ "$DIR" == "in" ]]; then
      for pid in "${ms_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    fi
  else
    # Count on server: clients passive in background
    while read -r host lo hi; do
      [[ -n "$host" ]] || continue
      launch_client_range "$host" "$lo" "$hi" "$port" "$MODE" "$clt_peers" "$clt_dur" "$logdir" 1
      [[ -n "${LAUNCH_PID:-}" ]] && clt_sshs+=("$LAUNCH_PID")
    done < <(client_id_ranges "$n_clt")
    for pid in "${ms_pids[@]}"; do wait "$pid" || true; done
    for pid in "${clt_sshs[@]}"; do
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi

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

  log "$LABEL n_srv=$n_srv n_clt=$n_clt Q=$qmetric total=${mops} Mops count=$COUNT"
  append_csv "$CSV" "$LABEL,$n_srv,$n_clt,$qmetric,$mops,$SIZE,$POSTLIST,$UNSIG,$inl_note,$RESULT_TAG,$COUNT"
  if [[ "${KEEP_LOGDIR:-0}" == "1" ]]; then
    log "KEEP_LOGDIR=1: preserving $logdir"
  else
    rm -rf "$logdir"
  fi
}

for tok in $CURVES; do
  parse_curve "$tok"
  for n in "${NQPS[@]}"; do
    run_one "$n"
  done
done

log "done: $CSV"
column -t -s, "$CSV" 2>/dev/null || cat "$CSV"

if [[ "${SKIP_PLOT:-0}" != "1" ]]; then
  PLOT_X="${PLOT_X:-n}"
  log "plotting into $RUN_DIR"
  python3 "$SCRIPT_DIR/plot_scale.py" --csv "$CSV" --out-dir "$RUN_DIR" --x "$PLOT_X"
  log "plot done"
fi
