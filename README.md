# rdma_scal

RDMA scalability microbenchmark. Measures small-message throughput (Mops) for UC/RC WRITE, RC READ, and UD SEND as the number of processes and queue pairs grows, with optional inline vs DMA.

Peers exchange QP endpoints over TCP and use RoCEv2 GIDs. Default load: 32-byte messages, `postlist=1`, `unsig=4`, inline enabled.

## Layout

| Path | Role |
|------|------|
| `scale_bench` | Per-process worker (`-I`, `-q`, `-M`) |
| `common.[ch]` | Device setup, QP state machine, TCP exchange, CPU pinning |
| `scripts/setup_machine.sh` | Host, device, IP, GID |
| `scripts/config.sh` | N sweep, curve list, defaults |
| `scripts/collect_scale.sh` | Matrix run, CSV, plots |
| `scripts/plot_scale.py` | Figures from CSV |

`collect_scale.sh` starts N server processes locally and N client processes over SSH (split across two hosts when `CLT_SET=both`). Throughput is the sum of sender-side Mops.

## Modes (`-M`)

| Mode | Server (`-s`) | Client (`-c`) |
|------|---------------|---------------|
| `out-write` / `out-read` | Sends; reports Mops | Passive |
| `in-write` | Passive | Sends; reports Mops |
| `out-send-ud` | N processes: one UD QP and N AHs each | N receivers |
| `in-send-ud` | Process `-I 0` only: one UD QP receive | N senders |

Connected WRITE/READ use an N by N QP mesh (Q = N squared). Out-SEND uses N UD QPs on the server (one per process). In-SEND uses one UD QP on the server.

## Cluster

Configure via `scripts/setup_machine.sh`. Typical RoCE fabric:

| Role | Host | Device | IP | GID |
|------|------|--------|-----|-----|
| Server | server02 | `mlx5_0` | `10.0.0.20` | 4 |
| Client | server03 | `mlx5_3` | `10.0.0.21` | 3 |
| Client | thoth | `mlx5_1` | `10.0.0.22` | 3 |

Pass the server RoCE IP with `-a`. Prefer eth MTU 9000 and IB `active_mtu` 4096 on both ends.

## CPU pinning

Enabled by default (`PIN=1`). Each process is bound to one logical CPU from the RNIC `local_cpulist` (same NUMA node). Process `-I i` uses list entry `i % ncpus`. Disable with `PIN=0`.

## Client selection (`CLT_SET`)

| Value | Clients | Output |
|-------|---------|--------|
| `server03` (default) | All on server03 | `results/scale_server03.csv`, `scale_fig_*_server03.*` |
| `thoth` | All on thoth | `scale_thoth.*` |
| `both` | First `ceil(N/2)` on server03, rest on thoth; N up to 40 | `scale_both.*` |

## Build and run

```bash
cd ~/rdma_scal
make -j
source ./scripts/setup_machine.sh

./scripts/collect_scale.sh
CLT_SET=thoth ./scripts/collect_scale.sh
./scripts/collect_scale.sh both

CURVES="out-write-uc-inl in-write-uc-inl" NQPS="1 2 4 8" ./scripts/collect_scale.sh
```

Sync `scale_bench` to clients if home directories are not shared. Replot without collecting:

```bash
python3 scripts/plot_scale.py --csv results/scale_both.csv
PLOT_X=q python3 scripts/plot_scale.py --csv results/scale_server03.csv
```

Skip plotting during collect with `SKIP_PLOT=1`.

## Curve tokens (`CURVES`)

`out-write-uc-inl`, `out-write-uc-dma`, `out-write-rc-inl`, `in-write-uc-inl`,
`out-read-rc-dma`, `out-send-ud-inl`, `out-send-ud-dma`, `in-send-ud-inl`, ...

## Manual single point

```bash
# server
./scale_bench -s -d mlx5_0 -a 10.0.0.20 -x 4 -p 18640 \
  -M out-write -q 2 -I 0 -t 1 -l 32 -Q 4 -D 5 --uc

# client
ssh server03 'cd ~/rdma_scal && ./scale_bench -c -d mlx5_3 -a 10.0.0.20 -x 3 \
  -p 18640 -M out-write -q 2 -I 0 -t 1 -l 32 -Q 4 -D 40 --uc'
```

## Reading results

Use Out-WRITE-UC-inl versus N or active QPs to find the outbound peak and drop (QP-context pressure on the server NIC). Compare In-WRITE on the same axis; with a weak single client, In may reflect client TX limits rather than server inbound capacity. Out-SEND-UD (N server senders) typically plateaus near the small-message send-rate ceiling. Keep `POSTLIST=1` on the main sweep so large postlists do not hide context misses.
