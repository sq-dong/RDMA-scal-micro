#!/usr/bin/env bash
# PCM: sample pcm-pcie while a command runs. Needs sudo.
# Usage: pcm_wrap.sh OUT.csv [--] cmd [args...]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# PCM: official intel/pcm submodule → build/bin (see docs/pcm.md)
PCM_BIN="${PCM_BIN:-$ROOT/pcm/build/bin/pcm-pcie}"
INTERVAL="${PCM_INTERVAL:-1}"

OUT="${1:?usage: pcm_wrap.sh OUT.csv [--] cmd...}"
shift
[[ "${1:-}" == "--" ]] && shift
[[ -x "$PCM_BIN" ]] || {
  echo "missing $PCM_BIN — build official PCM: see docs/pcm.md" >&2
  exit 1
}
[[ $# -ge 1 ]] || { echo "no command" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
# PCM: background sampler (CSV: Skt,PCIRdCur,RFO,CRd,DRd,ItoM,...)
sudo "$PCM_BIN" -csv="$OUT" "$INTERVAL" >/dev/null 2>"${OUT}.pcm.err" &
PCM_PID=$!
cleanup() { sudo kill "$PCM_PID" 2>/dev/null || true; wait "$PCM_PID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 2
"$@"
ec=$?
sleep 1
exit "$ec"
