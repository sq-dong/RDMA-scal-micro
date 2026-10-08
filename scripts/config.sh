#!/usr/bin/env bash
# Measurement policy for scalability sweeps.
# shellcheck shell=bash

# Default: small messages, short postlist, expose QP-context pressure.
SIZE="${SIZE:-32}"
POSTLIST="${POSTLIST:-1}"
UNSIG="${UNSIG:-4}"
TPUT_SEC="${TPUT_SEC:-5}"
PASSIVE_SEC="${PASSIVE_SEC:-40}"

# N = processes per side. Connected active QPs = N*N.
# both: default sweep through 40; single client: through 32. Override with NQPS=...
if [[ -n "${NQPS:-}" ]]; then
  # shellcheck disable=SC2206
  NQPS=($NQPS)
elif [[ "${CLT_SET:-server03}" =~ ^(both|dual|split)$ ]]; then
  NQPS=(1 2 4 8 12 16 24 32 40)
else
  NQPS=(1 2 4 8 12 16 24 32)
fi

# Curves to run (space-separated). Override with CURVES=...
# Format tokens:
#   out-write-uc-inl  out-write-uc-dma  out-write-rc-inl  out-write-rc-dma
#   in-write-uc-inl   in-write-uc-dma
#   out-read-rc-dma
#   out-send-ud-inl   out-send-ud-dma
#   in-send-ud-inl
CURVES="${CURVES:-out-write-uc-inl in-write-uc-inl out-read-rc-dma out-send-ud-inl in-send-ud-inl out-write-uc-dma}"

# Which client machine(s) to use (proc ids 0..N-1):
#   server03  - all clients on smartx-server03 (mlx5_3 / 10.0.0.21)
#   thoth     - all clients on thoth (mlx5_1 / 10.0.0.22)
#   both      - split: first ceil(N/2) on server03, rest on thoth
# Also: ./scripts/collect_scale.sh both
# Results: results/scale_<tag>.csv and scale_fig_{A,B,C,all}_<tag>.*
CLT_SET="${CLT_SET:-server03}"
