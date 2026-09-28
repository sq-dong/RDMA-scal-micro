# RDMA / Cluster Status

Generated: 2026-09-28（复检 server03 恢复后；MS 已对齐到 `192.168.101.0/24`）

## Connectivity checklist

| Check | Status | Detail |
|-------|--------|--------|
| server03 CX-5 链路 | **OK** | `mlx5_3` / `enp24s0f0np0` Up，100 Gb/s，Link detected |
| MS ↔ server03 ping | **OK** | `192.168.101.20` ↔ `192.168.101.11` |
| 同一 RoCE 子网 | **OK** | `192.168.101.0/24`（已不再使用旧文档的 `10.0.0.21`） |
| IB active_mtu | **OK** | 两端均为 **4096**；eth MTU **9000** |
| RoCEv2 GID | **OK** | MS index **6**；server03 index **3** |
| thoth 入网 | **未就绪** | `ens7f1np1` Up 100G，但 IP=`192.168.105.3`，与 MS 不通 |
| 旧 `10.0.0.0/24` 文档配置 | 过时 | MS 仍保留 `10.0.0.20` 别名；client 已不在该网段 |

## Machine layout（当前可用）

| Role | Host | Device | Netdev | IPv4 | RoCEv2 GID |
|------|------|--------|--------|------|------------|
| MS | smartx-server02 | `mlx5_0` | `enp59s0f0np0` | **192.168.101.20**（兼有 10.0.0.20） | **6** |
| Client1 | smartx-server03 | `mlx5_3` | `enp24s0f0np0` | **192.168.101.11** | **3** |
| Client2 | thoth | `mlx5_1` | `ens7f1np1` | 192.168.105.3（孤立） | 3（本机） |

管理网（SSH）：`192.168.100.12` / `.13` / `.68`，三机互通。

## RNIC 参数摘要

| 参数 | server02 (MS) | server03 | thoth |
|------|---------------|----------|-------|
| HCA | ConnectX-5 (4119) | ConnectX-5 (4119) | ConnectX-5 (4119) |
| FW | 16.35.4506 | 16.35.4506 | 16.35.8002 |
| Link | 100 Gb/s Up | 100 Gb/s Up | 100 Gb/s Up（异网段） |
| Device Memory | 128 KB | 128 KB | 128 KB |
| max_inline RC/UC | **828 B** | （同系 CX-5） | 828 B |
| max_inline UD | **956 B** | | 956 B |
| On-chip QP/ICM cache | **不可直接读** | 同左 | 同左 |
| PCIe (MS) | Gen3 x16 | — | — |
| PIO / BlueFlame | 典型 256 B record（无 sysfs 直接暴露） | 同左 | 同左 |

说明：`ibv_devinfo` 的 *maximum available device memory* 是 MEMIC，**不是** HERD 讨论的 QP 上下文 cache；后者靠本仓库的 N 扫描反推拐点。

## 网络变更记录（本机）

为与 server03 的 `192.168.101.11` 互通，在 server02 上：

1. 给 `enp59s0f0np0` 增加 `192.168.101.20/24`，MTU 9000（写入 `01-roce.yaml`）。
2. 从 `enp94s0f1` 去掉冲突的 `192.168.101.12`（该口不是 RoCE 网卡，会抢走路由）。

若重启后 ping 失败，先确认：

```bash
ping -c2 -I enp59s0f0np0 192.168.101.11
show_gids | grep 192.168.101
```

## thoth 接入（可选）

在 thoth 上将 RoCE 口改到同一子网，例如：

```bash
# 需 sudo；示例
sudo ip addr add 192.168.101.22/24 dev ens7f1np1
sudo ip link set ens7f1np1 mtu 9000
# 然后更新 setup_machine.sh: CLT_HOST2=thoth CLT_IP2=192.168.101.22 CLT_GID2=<show_gids>
```

## 复检命令

```bash
source ~/rdma_scal/scripts/setup_machine.sh
./scripts/probe_status.sh ~/rdma_scal/STATUS.md
```
