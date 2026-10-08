# METHODOLOGY — Windows 口径 → Linux 口径的逐条映射

> 目的：把 `suanrongqieqiezi/ninfer-rtx30-bench` 的测量方法学搬到 Linux 时，
> **哪些照搬、哪些等价替换、哪些无法照搬**，逐条写清。不写清就会重演"测试与实际使用隔断"。
>
> 图例：**照搬** = 口径原样沿用；**等价替换** = 目的相同、实现因平台而异；**无法照搬** = 平台差异导致不可移植，须改判据。

---

## 一、测量口径

| # | bench（Windows）口径 | 本项目（Linux） | 类别 |
|---|---|---|---|
| 1 | 三档 decode：3.5K 长上下文·DFlash2 / 256 token 短生成 / 256 token 重复密集 + `--lookup-ngram 8` | 保留三档口径的**精神**，但主验收改为 agent 回路（见 §二）——因为真实负载是 21.6K token 的多轮工具调用，不是 256 token 短问答 | **等价替换** |
| 2 | prefill 焦点：用 `SENT * 470`（约 7K token）的长 prompt，且区分 raw 与 cached | 照搬，并**额外记录 PCIe 链路**（本机 3060 为 Gen1×4 / max Gen2×16），因为它直接决定 prefill 上限 | **照搬 + 补充** |
| 3 | `--draft-tokens` 扫描 5/7/9/12 | 暂不扫（用户明确"不需要那么多数据"）；只固定 K=7 作为投机臂 | **本轮裁剪** |
| 4 | 变体扫描：`--lookup-ngram 8`、`--mlp-a8-decode`、`--prefill-cublas`、`--kv-dtype k8v4` | 本轮不做变体矩阵；`--kv-dtype` 改为**可行性门禁**（见 §三-2） | **本轮裁剪** |
| 5 | 正确性参考：`输出与基座逐字节相同`，用 MD5 比对 | **改为输出一致性表征而非普遍硬门禁**：每类 prompt、每臂至少重复 3 次，分别记录臂内可复现性与基线/`--spec dflash2 --draft-tokens 7` 间 MD5；跨臂不一致必须披露，但不单独判部署失败 | **按本机实测修正** |
| 6 | 服务就绪判据 `GET /v1/models` 返回 200 | 照搬 | **照搬** |
| 7 | 服务清理 `taskkill /F /IM ninfer-serve.exe` | 等价替换为 `Popen` + `SIGINT`（先给优雅退出机会）→ 超时 `kill`，然后等 5 秒让显存回收 | **等价替换** |
| 8 | 客户端硬编码 `E:\AI\...` 路径 | 全部改为读 `config/env.sh`，脚本内不出现任何本机绝对路径 | **等价替换** |
| 9 | 客户端依赖 | 纯标准库（`json/time/subprocess/urllib.request/hashlib/os`）——本机**无 pip、无 venv**，必须如此 | **照搬（约束继承）** |
| 10 | `ab_compare.py` 的 A/B 两臂（官方包 vs 自编译补丁版） | 保留"两臂 + 比 tok/s + 比输出 MD5"的形态；但我们的两臂是**同源不同 flag**（无投机 vs 投机），因为 Linux 侧没有"官方预编译包"这一臂 | **等价替换** |

---

## 二、agent 体验验收（本项目扩展的口径）

bench 的口径对应的是"压榨峰值速度"；本项目要的是"**可用性**"。扩展如下：

| # | 指标 | 方法 | 不合格判据 |
|---|---|---|---|
| A1 | **真实 agent 回路可用性（主验收）** | ≥63 个工具 schema + 约 2K token 的 system prompt + ≥50 轮工具调用；每轮记 wall/TTFT、prompt_tokens、completion_tokens、cached_tokens、tool_calls 数、参数 JSON 合法率 | 任一轮请求失败；工具名越界或参数非法；轮数跑不满 |
| A2 | **长上下文边界** | 8K→16K→24K→32K→49K 逐档，测流式 TTFT 与 decode | 出现"起不来"或 TTFT 崩塌式增长（拐点必须被记录） |
| A3 | **长时间稳定性** | 同一会话连续 ≥50 轮，比较前 5 轮与后 5 轮的 wall/prompt_tokens 均值，并对比前后显存占用 | decode/TTFT 单向漂移、显存单调上涨（泄漏） |
| A4 | **输出一致性（投机是否无损的表征）** | 每类 prompt 在无投机与 `dflash2 K=7` 两臂各重复 ≥3 次，分别记录臂内与跨臂 MD5 | 必须记录并披露观察到的差异；跨臂不一致本身不判部署失败，臂内不可复现则需调查 |
| A5 | **冷启动与就绪** | 进程启动到 `/v1/models` 200 的秒数 + 首次请求 TTFT | 就绪超时或反复失败 |
| A6 | **环境记账** | PCIe gen/width（idle 与负载各一次）、桌面占用、驱动/CUDA/profile 版本 | 缺任一项（缺了就无法判断数字是否可比） |

对标坐标（仅作参考，不作结论）：bench 的 Windows 3060 记录为 decode 中位 108.7 tok/s、prefill 640 tok/s、
无投机基线 17.5 tok/s（5.95–6.21×）、`--spec mtp` 回退 71.2 tok/s。

---

## 三、三个坑的 Linux 对应物

### 1. 架构白名单 + `NINFER_SM_COUNT=28`
- **bench 原文**：官方 CMake 只编 sm_89/sm_120，需加 sm_86；另有按 SM 数分支的逻辑，需 `NINFER_SM_COUNT` 覆盖为 28。
- **Linux 实际**：所选源码线（`iamwavecut/ninfer-all`）**本身已接受 `86`**（`CMakeLists.txt:14` 的 `^(80|86|89|120a)$`），且**根本没有 `NINFER_SM_COUNT` 这个宏**（grep 无命中）。
- **等价替换**：该线改用"按实测 device profile 选 route"的机制。RTX 3060（28 SM）**没有内置 profile**（`docs/device-profiles.md:21` 只覆盖 3090/4090/5090/PRO 6000），故用仓库自带的 `ninfer-calibrate` 标定 28-SM profile（`scripts/70-calibrate.sh`），并与 `--device-profile off` 的编译期表做双向对照。
- **类别**：**等价替换**（同一意图，机制不同）。

### 2. FP8 墙
- **bench 原文**：sm_86 无 FP8 张量核，12 个 FP8-mma 单元 `ptxas fatal`，需排除并补 `fp8_a8_stubs.cpp` 桩。
- **Linux 实际**：所选源码线里 `src/ops/fp8_sm86_stubs.cpp` **已经存在**（3,919 B），且构建日志里可见 `-D NINFER_SM8X_COMPAT=1` 生效。
- **类别**：**已由源码线上游解决**（记录在案，若将来换源码线需重做）。

### 3. 12G 拒启 / `--kv-capacity`
- **bench 原文**：dflash2 草稿权重 9.10 GiB，`--kv-capacity auto` 强制多留 1 GiB → 12G 卡拒绝启动，必须显式容量（他们用 `24576` / `int8`）。
- **Linux 实际**：容量强依赖 `--kv-dtype`。反例：本机旧服务在同一张 12G 卡上用 `--kv-capacity 76768 --kv-dtype rk2v4-e8` **跑通过**。
- **处理**：把 `(kv-dtype, kv-capacity)` 当**可行性门禁实测扫描**（`scripts/75-kv-gate.sh` + `agent/kvgate.py`），二分出"能启动 + 连续 3 次请求无错"的最大容量；并分别在**带桌面**与**TTY 无桌面**两态各跑一次。bench 的 `24576` 只作为"要求对齐的目标值"。
- **类别**：**等价替换 + 口径修正**（把别人的常数换成自己的实测）。

---

## 四、已知差异（不得隐去）

1. **源码线不同**：bench 作者的 Windows 构建基于一条**无法确指**的源线（其 3060 文档白名单为 `sm_89`/`sm_120`，既非官方纯 `120a`，也非 `iamwavecut` 的 `80|86|89|120a`）。本项目选 `iamwavecut/ninfer-all`，理由是**工件决定的**：v3 工件需要 `t2_g128_fp16` + `hadamard_signs`，只有这条线有。因此两边是"同方法学、不同源线"。
2. **CUDA 版本不同**：bench Windows 用 CUDA 13.3 + MSVC 14.51；本项目用项目自带的 CUDA 13.1 + GCC 13。
3. **平台不同**：Windows 侧无需编译（发预编译包），Linux 侧必须编译——这正是本项目补上的那一半。
4. **bench 结果文件与正文不自洽**（prefill/decode 数字），故只把其正文当作"量级参照"，不当作可比基线。

---

## 五、可比性边界（写数字时必须同时写清）

1. **PCIe 链路**：本机 3060 实测 idle 为 **Gen1 ×4（max Gen2 ×16）**。prefill 走 PCIe 传激活，**不可跨机横比**；decode 权重常驻显存，受链路影响小，可比性更好。
2. **桌面占用**：GPU0 上有 Xorg/gnome-shell 等约 922 MiB。它会直接吃掉可用的 `--kv-capacity`，因此容量门禁必须两态各做一次。
3. **卡不同**：bench 的 3060 数字来自另一台机器（独立实测）。本项目的数字是**本机 Linux 的参考值**，不是对它的复现。
4. **口径不同**：agent 回路指标（A1–A3）在 bench 里没有对应项，不能与它的三档 decode 直接比较。
