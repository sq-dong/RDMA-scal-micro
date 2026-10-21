# PCM measurements with rdma_scal

Official Intel PCM: **https://github.com/intel/pcm** (submodule at `pcm/`).

ScaleRPC §3.6.3 used PCM to relate RDMA throughput to PCIe traffic. On this
cluster (Xeon Gold 5218 / Cascade Lake) `pcm-pcie` reports
`PCIRdCur,RFO,CRd,DRd,ItoM,PRd,WiL` — there is **no** `PCIeItoM` (older CPUs only).

| Counter | RDMA reading |
|---------|----------------|
| `PCIRdCur` | NIC reading host memory (QP/WQE thrashing when high vs mops) |
| `RFO` / `ItoM` | NIC writing host memory (DDIO / inbound payload) |

---

## Setup

```bash
cd ~/rdma_scal
git submodule update --init --recursive   # clones https://github.com/intel/pcm

cd pcm
mkdir -p build && cd build
cmake ..
cmake --build . --parallel
# tools: pcm/build/bin/pcm-pcie  pcm/build/bin/pcm  ...
```

Smoke (needs sudo):

```bash
sudo ~/rdma_scal/pcm/build/bin/pcm-pcie 1
# Ctrl-C to stop
```

If counts stay zero: `sudo env PCM_NO_PERF=1 …/pcm-pcie 1`.

---

## How to measure

Sample on the **RDMA server**. Build the bench first: `make -j` and
`source ./scripts/setup_machine.sh`.

### Wrap any command

```bash
./scripts/pcm_wrap.sh /tmp/pcm.csv -- sleep 10
```

### Automated idle / QP / footprint

```bash
# short first run
NQPS="1 4 8 16" TPUT_SEC=10 BENCH=all ./scripts/collect_pcm.sh

BENCH=idle ./scripts/collect_pcm.sh
BENCH=qp   CURVE=in-write-rc-inl NQPS="1 8 16 32" ./scripts/collect_pcm.sh
BENCH=foot FOOT_N=8 BUF_MBS="8 32 64" CURVE=in-write-rc-inl ./scripts/collect_pcm.sh
```

| `BENCH` | Meaning | Watch |
|---------|---------|--------|
| `idle` | PCM only | noise floor |
| `qp` | sweep `NQPS` | `PCIRdCur` vs `mops` |
| `foot` | fixed N, sweep `-B` MiB | `ItoM` / `RFO+ItoM` vs `mops` |

Results: `results/pcm_*/pcm_summary.csv`.

`scale_bench -B BUF_MB` enlarges the registered buffer and spreads remote WRITE
targets (LLC footprint). Override tool path with `PCM_BIN=…` if needed.
