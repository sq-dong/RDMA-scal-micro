# rdma_scal

HERD 风格的 **RDMA scalability** 微基准：在两台机器上用多进程全互联，测量
RC/UC WRITE、RC READ、UD SEND 在 **inline / non-inline** 下随连接数（或目的数）的扩展拐点。

连接与建连方式对齐 [`rdma_verb_test`](../rdma_verb_test)（TCP 交换 QP 元数据 + RoCEv2 GID）。

## 实现思路

### 要测的瓶颈（不是 UDP 那种多线程打满）

| 故事 | 拓扑 | 横轴含义 | 预期形状 |
|------|------|----------|----------|
| Connected 出向 cache | 两侧各 N 进程，每进程 N 条 QP → **N² QP** | 活跃 QP 数 | Out-WRITE 先升后掉 |
| Connected 入向 | 同上，但 client 做 WRITE | 活跃 QP 数 | In-WRITE 更能扩展 |
| READ 出向 | 同上，RC READ | 活跃 QP 数 | 通常更低 / 更早饱和 |
| UD 出向扇出 | **1** 个 MS UD QP + **N 个 AH** | 目的数 N | 近似平坦（单 QP 上限） |
| UD 入向 | N 个 client UD SEND → 1 个 MS UD QP | 发送端数 N | 看收端能否吸收 |

默认 `postlist=1`、`unsig=4`、`size=32`、**inline**，故意暴露 QP 上下文压力；
另扫 `*-dma`（`--no-inline`）作对照。

### 为什么不用「server 多发线程 + client 多收线程」当主实验

那是 UDP/主机栈并行度测法。本仓库主曲线对齐 HERD Fig.6：UD **故意单发送 QP**，
用来证明「无连接扇出不涨 per-dest 状态」。需要抬绝对速率时再开对照（加大 postlist
或多 UD QP），不要和主扩展性曲线混读。

### 程序结构

```
scale_bench   单进程 worker（-I id -q N -M mode）
common.[ch]   设备 / QP 状态机 / TCP exchange（来自 rdma_verb_test）
scripts/
  setup_machine.sh   主机 / IP / GID
  config.sh          N 轴、曲线列表、postlist
  collect_scale.sh   扫矩阵 → results/scale.csv
  probe_status.sh    刷新 STATUS.md
```

`collect_scale.sh` 在 MS 本地 fork N 个（或 UD 时 1 个）`scale_bench -s`，
经一次 SSH 在 client 上 fork N 个 `-c`，避免 MaxStartups；各进程日志里的 Mops **加总**。

### 模式 → 谁发谁收

| `-M` | MS (`-s`) | Client (`-c`) |
|------|-----------|---------------|
| `out-write` / `out-read` | 发送并报 Mops | 被动 |
| `in-write` | 被动 | 发送并报 Mops |
| `out-send-ud` | 仅 `-I 0`：1 UD QP + N AH，发送 | N 进程收 |
| `in-send-ud` | 仅 `-I 0`：1 UD QP 收 | N 进程发送并报 Mops |

## 机器与网段（当前）

详见 [STATUS.md](STATUS.md)。摘要：

| Role | Host | Dev | IP | GID |
|------|------|-----|----|-----|
| MS | server02 | `mlx5_0` | `192.168.101.20` | 6 |
| Client | server03 | `mlx5_3` | `192.168.101.11` | 3 |
| Client2 | thoth | — | **未入同一子网** | — |

`-a` 必须填 **MS 的 RoCE IP**（TCP 与 RDMA 元数据交换都指向它）。

## 构建与运行

```bash
cd ~/rdma_scal
make -j

source ./scripts/setup_machine.sh
# 可选：只跑子集
# CURVES="out-write-uc-inl in-write-uc-inl out-send-ud-inl" NQPS="1 2 4 8" \
./scripts/collect_scale.sh
```

结果：`results/scale.csv`（`curve,n,active_q_or_dest,mops,...`）。

### 手动单点（调试）

```bash
# MS
./scale_bench -s -d mlx5_0 -a 192.168.101.20 -x 6 -p 18640 \
  -M out-write -q 2 -I 0 -t 1 -l 32 -Q 4 -D 5 --uc

# client（另一终端 / SSH）
ssh server03 'cd ~/rdma_scal && ./scale_bench -c -d mlx5_3 -a 192.168.101.20 -x 3 \
  -p 18640 -M out-write -q 2 -I 0 -t 1 -l 32 -Q 4 -D 40 --uc'
# 以及 -I 1 ...
```

### 曲线 token（`CURVES`）

`out-write-uc-inl` `out-write-uc-dma` `out-write-rc-inl` `in-write-uc-inl`
`out-read-rc-dma` `out-send-ud-inl` `out-send-ud-dma` `in-send-ud-inl` …

## 如何读结果

1. 以 **Out-WRITE-UC-inl** 的 N 或 `active_q_or_dest=N²` 为横轴，找峰值与回落 → 片上上下文压力。
2. **In-WRITE** 同轴对比：若持续上升而 Out 已掉，结论与论文一致。
3. **Out-SEND-UD**：横轴是目的数 N（不是 N²）；应远比 Out-WRITE 平坦。
4. **dma vs inl**：小消息下 inline 更高；大 postlist 会掩盖 cache miss——主扫保持 `POSTLIST=1`。
5. 绝对 Mops 勿与论文 CX-3/IB 叠图；只比形状与拐点。CX-5 拐点通常更靠右。

## 与 rdma_verb_test 的关系

| | rdma_verb_test | rdma_scal |
|--|----------------|-----------|
| 目标 | 复现 Fig.2–6 | 专扫扩展性矩阵 |
| Fig.6 | `fig6_scale` 三曲线 | 更多 verbs × inline × 方向 |
| 配置 | 旧文档常写 `10.0.0.0/24` | **以 STATUS / setup_machine 为准** |

公共代码：`common.c` / `common.h` 同源；本目录自包含，二进制需 `scp` 到 client（home 未共享）。
