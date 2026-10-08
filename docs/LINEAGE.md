# LINEAGE — 血缘、依赖归属与许可证

> 本文件回答三个问题：**这套东西是从哪来的**、**我们欠谁什么**、**别人怎么接着改**。
> 它是本项目"去黑盒化"原则的落地：任何一个产物都能回溯到具体的 repo、commit 和哈希。

---

## 一、三条上游

| 上游 | 提供什么 | 我们依赖的具体部分 | License |
|---|---|---|---|
| **引擎源码** `iamwavecut/ninfer-all` @ `796f985007775f4bc7cfde53804fa22e7d60dbf8` | NInfer 引擎的 C++/CUDA 源码 | 唯一能读 Bonsai v3 工件的源码线 | Apache-2.0 |
| **模型工件** `WaveCut/Ternary-Bonsai-2-27B-NInfer-v3` @ `b85b33627b27b9757a5a094fc74785a53e99f8ee` | 三值量化权重（`.ninfer` 单文件） | 9,520,051,456 B / sha256 `cdc4810b0ff17c40d0f62cf214b6e0bcd08346e9eb05ca53371507037793c14a` | Apache-2.0 |
| **方法学参照** `suanrongqieqiezi/ninfer-rtx30-bench` @ `c2f882ba274af6d31e941e81b114300a1dc9a657` | Windows 侧的测量口径与结果、三个坑的描述 | **只引用口径**；其代码一行未复制 | **无 license 声明（license = null）** |

工具链（CUDA、gcc、cmake、ninja）是第四类输入，但它是**工具**不是上游作品：CUDA 由本项目从 NVIDIA 官方 redist 清单按组件下载并逐件校验 sha256（见 `config/toolchain.lock`）。

---

## 二、引擎的完整 fork 血缘

```
Neroued/ninfer                                  ← 官方。面向 RTX 5090
  Apache-2.0, 2742★, master, 0 releases
  架构写死：CMakeLists.txt 默认 CMAKE_CUDA_ARCHITECTURES=120a，
  且 if(NOT STREQUAL "120a") message(FATAL_ERROR ...)
  tensor-formats 只注册 9 种格式，无 t2_g128_fp16 / hadamard_signs
  → 拒绝加载本项目的 v3 工件
    │
    ├── Don-Chad/ninfer-3090                    ← 428★，release v0.6.1-rtx3090
    │     最早把 3090 跑起来；v1/v2 容器魔数时代
    │     （旧移植误用了这一版的 kit → "unknown tensor format: PQ2_0_G128"）
    │       │
    │       ├── ashalliants/ninfer-3090         ← 33★，v0.14.0-rtx3090
    │       │     bench 所称"官方预编译 3090 包" = 它的 v0.11.0-rtx3090
    │       │
    │       └── iamwavecut/ninfer-all           ← 45★，无 releases，VERSION = 0.12.0-rtx3090
    │             合并线：GGUF 块格式、ternary Bonsai 2、device route profiles、MTP、DFlash2
    │             **带 t2_g128_fp16 + hadamard_signs** ← 本项目源码上游
    │             架构闸门放宽为 ^(80|86|89|120a)$，默认 86
    │             docs/rtx-3090-linux.md：GCC 13 / 驱动 580+ / CUDA 12.8+
    │
    └── （其他 sm_86 fork，仅作背景，本项目未使用）
        5258MF/ninfer-rtx3060-27b · ahnafnaf/ninfer-3080 · yangkang5303/ninfer-3090
        jimchan3301/ninfer-3080duo · giocom/ninfer-3060X2 · 770120799/ninfer-RTX3070-adapt
        songlinxin/ninfer3080-20G · lurenakillgore9-web/NInfer-…-sm86-win64
```

模型侧：

```
PrismML                                    ← Ternary-Bonsai-2-27B 的训练方
  三值权重 ∈ {-1,0,+1}，约 1.76 bit/参数，权重本体约 5.9GB
  技术路线源自 BitNet b1.58（arXiv:2402.17764）
    │
    └── WaveCut/Ternary-Bonsai-2-27B-NInfer-v3    ← HF，Apache-2.0
          面向 NInfer-all 线打包：
          t2_g128_fp16 与 hadamard_signs 只存在于该线
          （模型卡原话：Stock NInfer builds refuse this file）
```

---

## 三、本项目在血缘中的位置：与 bench 仓库**平行**，不是它的下游

```
suanrongqieqiezi/ninfer-rtx30-bench        Windows 侧 · 半成品
  只有：方法学 + 结果 + 一包 Windows 预编译运行时
  没有：引擎源码、补丁、依赖清单、构建文件
  license = null
        │
        │  ══════════ 平 行（同一件事的两个平台实现）══════════
        │
bonsai2-ninfer-3060-agent-linux            Linux 侧 · 本项目
  有：从零构建（源码 + 锁 commit + 可重放补丁）
      + 移植病历（PORTING-LEDGER.md）
      + agent 体验验收（AGENT-EXPERIENCE.md）
      + 打包即用（ModelScope 线）
```

**为什么"平行"而不是"下游"**：bench 仓库从未包含引擎，所以**任何人都无法成为它的下游**——连作者自己也不是；他当时也是去拿引擎源码的。他选择只发布"测量与结果"那一半，把"怎么编出来的"留在了自己机器上。本项目要补的正是那另一半。

**为什么必须有第二个 repo（引擎源码）**：不是因为它对 Linux 不友好，而是因为它**按设计就不含引擎**。在一棵 19 个 blob 的树里（`.gitignore` + `README.md` + 4 个 bench 脚本 + 4 个辅助脚本 + 8 个结果文件），确实没有任何 `.c/.cc/.cpp/.cu/.cuh/.h`，也没有 `CMakeLists.txt`、没有 `.patch`、没有 `requirements/lock`。

---

## 四、输入清单：只有 4 项

| # | 输入 | 固定方式 | 校验证据 |
|---|---|---|---|
| 1 | 引擎源码 `iamwavecut/ninfer-all` | 锁 commit `796f985…`，工作树必须干净 | `evidence/sources/sources.lock` |
| 2 | 方法学参照 `suanrongqieqiezi/ninfer-rtx30-bench` | 锁 commit `c2f882ba…`，**只读** | `evidence/sources/sources.lock` |
| 3 | 模型工件（HF / ModelScope） | sha256 + 字节数双重校验 | `evidence/model/model-identity.txt` |
| 4 | CUDA 工具链（NVIDIA 官方 redist） | 清单 sha256 + 逐组件 sha256 + 字节数 | `config/toolchain.lock`、`evidence/toolchain/` |

> 血缘图是**解释**用的，不是采购清单。本项目只 clone 一个引擎仓库、一个参照仓库。

---

## 五、无法确指的部分（如实声明）

我们**无法精确复现** bench 作者那个 Windows 构建：

1. 他没有发布源码版本、没有发布补丁（README 只说"对源码做了两处改动"）；
2. 他 3060 文档里写的白名单是 **`sm_89`/`sm_120`**，这**既不同于官方的纯 `120a`，也不同于 `iamwavecut` 的 `80|86|89|120a`** → 他的源线是第三条，无法确指；
3. 他的仓库有 4 个结果 JSON 与 README 正文对不上（prefill 7K 实算约 1,402 tok/s vs 正文 1,520；decode 233 tok / 1.99 s ≈ 117 tok/s vs 正文"dense 49.8"；`mtpq4` 记为 `boot_failed`）。

因此本项目的定位是：**同方法学、独立选源、差异入账**。这份差异本身就是结论的一部分，写入 `METHODOLOGY.md`。

---

## 六、归属与致谢

- **NInfer 引擎**：[Neroued/ninfer](https://github.com/Neroued/ninfer)（Apache-2.0）及其 fork 线
  [Don-Chad/ninfer-3090](https://github.com/Don-Chad/ninfer-3090)、
  [ashalliants/ninfer-3090](https://github.com/ashalliants/ninfer-3090)、
  [iamwavecut/ninfer-all](https://github.com/iamwavecut/ninfer-all)。各改动保留原作者。
- **模型**：Ternary-Bonsai-2-27B 由 PrismML 训练发布；`.ninfer` 工件由
  [WaveCut/Ternary-Bonsai-2-27B-NInfer-v3](https://huggingface.co/WaveCut/Ternary-Bonsai-2-27B-NInfer-v3) 发布（Apache-2.0）。
- **方法学**：[suanrongqieqiezi/ninfer-rtx30-bench](https://github.com/suanrongqieqiezi/ninfer-rtx30-bench)。
  该仓库**无 license 声明**，故本项目**未复制其任何代码**；仅引用其测量口径（三档 decode 口径、prefill 焦点、
  draft 深度扫描、`--lookup-ngram`、与无投机基线的 A/B、逐字节/MD5 正确性判据）与三个坑的描述，并逐条标注出处。
- 本项目自身的脚本、文档与构建流程为本项目原创，除非某行显式标注了出处。

---

## 七、给别人接着改：3080 / 3090 的移植锚点

只有"与卡相关"的量需要改，引擎源码与 CUDA 版本可以完全不动：

| 参数 | 位置 | 3060（本机） | 3080 / 3090 怎么改 |
|---|---|---|---|
| `NINFER_CUDA_ARCH` | `config/env.sh` | `86` | **不变**（同为 sm_86） |
| GPU UUID | `config/env.sh` 的 `GPU_UUID_3060` | `GPU-<UUID>` | 换成自己卡的 `nvidia-smi -L` 里那串（**别用序号**） |
| `NINFER_JOBS` | `config/env.sh` | `6` | 按物理内存调；内存 <32GB 不要超过 6（bench 侧 `-j 24` 曾触发内核 BugCheck） |
| device profile | `scripts/70-calibrate.sh` | 28 SM 标定结果 | **每张卡都必须重跑**（SM 数不同 → 调度表不同） |
| KV `(dtype, capacity)` | `scripts/75-kv-gate.sh` | 门禁实测 | **必须重跑**（显存不同） |
| 桌面占用 | `scripts/75-kv-gate.sh` 的两态 | 带桌面 / TTY 各一次 | 同样两态各跑一次 |

Docker（后置）按同一组参数设计接口，不做 3060 专有假设。
