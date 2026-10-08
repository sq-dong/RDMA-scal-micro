# RDMA / Cluster Status

Generated: 2026-10-03（对齐绑核后 `scale_{server03,thoth,both}.csv` 与现行脚本）

结果解读：[`docs/RDMA_SCAL_RESULTS_AND_CACHE.md`](../docs/RDMA_SCAL_RESULTS_AND_CACHE.md)  
流程与 RNIC 参数：[`docs/RDMA_SCAL_RNIC_AND_FLOW.md`](../docs/RDMA_SCAL_RNIC_AND_FLOW.md)

## Connectivity checklist

| Check | Status | Detail |
|-------|--------|--------|
| MS ↔ server03 | `10.0.0.20` ↔ `10.0.0.21` | eth MTU **9000** / IB **4096**（曾掉 1500/1024，需防 thrash） |
| MS ↔ thoth | `10.0.0.20` ↔ `10.0.0.22` | 同上 |
| RoCEv2 GID | MS **4**；server03 **3**；thoth **3** | `show_gids \| grep 10.0.0` |
| 链路 | 100 Gb/s CX-5 | FW MS/server03 `16.35.4506`；thoth `16.35.8002` |

## Machine layout

| Role | Host | Device | IPv4 | RoCEv2 GID | CPU（绑核） |
|------|------|--------|------|------------|-------------|
| MS | smartx-server02 | `mlx5_0` | **10.0.0.20** | **4** | 5218；`local_cpulist` 偶核 0,2,…,62 |
| Client1 | smartx-server03 | `mlx5_3` | **10.0.0.21** | **3** | 5218；同上 |
| Client2 | thoth | `mlx5_1` | **10.0.0.22** | **3** | 6780E；`local_cpulist`（常 0–143） |

管理网（SSH）：`192.168.100.12` / `.13` / `.68`。

## 采集入口

```bash
cd ~/rdma_scal && make -j
source ./scripts/setup_machine.sh

./scripts/collect_scale.sh              # → results/scale_server03.csv + scale_fig_*_server03.*
CLT_SET=thoth ./scripts/collect_scale.sh
./scripts/collect_scale.sh both         # N 到 40 → scale_both.csv

PIN=0 ./scripts/collect_scale.sh        # 关绑核
```

| 项 | 现行默认 |
|----|----------|
| `CLT_SET` | `server03` \| `thoth` \| `both` |
| `PIN` | `1`（一进程一核，仅 NIC NUMA） |
| `NQPS` | 单机到 32；both 到 **40** |
| 输出 | `results/scale_<tag>.csv` + `scale_fig_{A,B,C,all}_<tag>.*` |

## 绑核后 WRITE 峰值摘要（2026-09-30 CSV）

| | Out-WRITE 峰 | Out 悬崖 | In-WRITE |
|--|--------------|----------|----------|
| server03 | **~65 @ N=12** | **~33 @ N=16** | 平台 **~40.5**（N=8–16） |
| thoth | **~65 @ N=12** | **~33 @ N=16** | 升到 **~82.5 @ N=24** |
| both | **~65 @ N=12** | 同左 | 升到 **~118 @ N=40** |

Out-\* 几乎不随 client 变；In-\* 受 client TX / 分摊影响。片上 QP cache 代理见 `cache_probe/`。
