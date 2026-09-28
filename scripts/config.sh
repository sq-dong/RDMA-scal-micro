#!/usr/bin/env bash
# Measurement policy for scalability sweeps.
# shellcheck shell=bash

# Default: expose QP-context pressure (HERD Fig.6 style).
SIZE="${SIZE:-32}"
POSTLIST="${POSTLIST:-1}"
UNSIG="${UNSIG:-4}"
TPUT_SEC="${TPUT_SEC:-5}"
PASSIVE_SEC="${PASSIVE_SEC:-40}"

# Paper N = procs per side. Active connected QPs = N*N.
# CX-5 usually needs larger N than CX-3 before Out-WRITE drops.
NQPS=(${NQPS:-1 2 4 8 12 16 24 32})

# Curves to run (space-separated). Override with CURVES=...
# Format tokens:
#   out-write-uc-inl  out-write-uc-dma  out-write-rc-inl  out-write-rc-dma
#   in-write-uc-inl   in-write-uc-dma
#   out-read-rc-dma
#   out-send-ud-inl   out-send-ud-dma
#   in-send-ud-inl
CURVES="${CURVES:-out-write-uc-inl in-write-uc-inl out-read-rc-dma out-send-ud-inl in-send-ud-inl out-write-uc-dma}"
