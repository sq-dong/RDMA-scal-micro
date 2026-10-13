#!/usr/bin/env bash
# Measurement policy for scalability sweeps.
# shellcheck shell=bash

SIZE="${SIZE:-32}"
POSTLIST="${POSTLIST:-1}"
UNSIG="${UNSIG:-4}"
TPUT_SEC="${TPUT_SEC:-30}"
PASSIVE_SEC="${PASSIVE_SEC:-$((TPUT_SEC + 15))}"

# Client machine(s): default thoth only.
CLT_SET="${CLT_SET:-thoth}"

# Server processes per point = N; client processes = CLT_MULT * N (default 1 → N×N).
CLT_MULT="${CLT_MULT:-1}"

# N = processes per side. Connected active QPs = N*N when CLT_MULT=1.
# both: default sweep through 40; otherwise through 32. Override with NQPS=...
if [[ -n "${NQPS:-}" ]]; then
  # shellcheck disable=SC2206
  NQPS=($NQPS)
elif [[ "${CLT_SET}" =~ ^(both|dual|split)$ ]]; then
  NQPS=(1 2 4 8 12 16 24 32 40)
else
  NQPS=(1 2 4 8 12 16 24 32)
fi

# Full verb matrix (all hardware-legal combinations we implement).
# Starred subset for focused plots is handled in plot_scale.py.
CURVES="${CURVES:-in-read-rc-dma out-read-rc-dma in-write-rc-dma in-write-rc-inl out-write-rc-dma out-write-rc-inl in-write-uc-dma in-write-uc-inl out-write-uc-dma out-write-uc-inl in-send-rc-dma in-send-rc-inl out-send-rc-dma out-send-rc-inl in-send-uc-dma in-send-uc-inl out-send-uc-dma out-send-uc-inl in-send-ud-dma in-send-ud-inl out-send-ud-dma out-send-ud-inl}"
