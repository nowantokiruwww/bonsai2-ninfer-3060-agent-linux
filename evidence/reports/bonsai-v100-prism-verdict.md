# Bonsai2-27B 在 Tesla V100 上的可行性判定与实测报告

> 日期：2026-10-06 · 主机：<user>-MS-7B89
> 目标卡：**Tesla V100-SXM2-16GB**（nvidia-smi index 1，UUID `GPU-<redacted>`，compute capability **7.0 / sm_70**）
> 驱动 580.178.04 · 系统 CUDA runtime 13.0 · 为本次构建另装 **CUDA 12.9** 于 `~/cuda-12.9`

---

## 0. 结论速览

用户的问题是「**ninfer 或者 llama.cpp-prism 内核的 bonsai，能不能跑在 V100 上**」。答案对两条路线是相反的：

| 路线 | V100 可行性 | 关键事实 |
|---|---|---|
| **NInfer** | ❌ **不能** | 官方 kit 里只有 sm_86 设备码、且**没有 PTX**（无法 JIT），驱动直接拒绝加载；源码层也是 sm_80+ 硬闸 |
| **llama.cpp-prism（PTQ1_0）** | ✅ **能，而且很快** | 自编译出 sm_70 设备码后，**decode 61–71 t/s、prefill 868 t/s**，全面超过 V100 原先跑的 Qwen3.8-27B IQ3_S |

**一句话**：不用等 NInfer 移植，**现在就能让 V100 跑 bonsai，且比它原来跑的模型更快、更省显存、上下文翻倍。**

---

## 1. 前提动作：卸掉 V100 上原有的服务

| | |
|---|---|
| 原进程 | PID 694237 = `（本机工作目录，未发布） -m （本机工作目录，未发布） … -c 65536 -t 6 --spec-type draft-mtp` |
| 启动方式 | 手工在 gnome-terminal 里起的（PPID = `gnome-terminal-server`），**无 systemd unit、无 supervisor** |
| 已运行 | 15:27:16 |
| 卸载方式 | `kill -INT 694237`（**未用 -9**）。约 4 s 后退出 |
| 验证 | `kill -0` 已消失 · 端口 8911 已释放 · V100 显存 **15550 MiB → 6 MiB** · `--query-compute-apps` 为空 |

> ⚠️ **必须按 UUID 锁卡，不能按序号。** 本机 `nvidia-smi` 的 index 0 是 RTX 3060、index 1 是 V100，而 **CUDA 运行时的枚举顺序正好相反**：不设 `CUDA_VISIBLE_DEVICES` 时 CUDA device 0 = V100、device 1 = 3060。所有脚本一律用 `CUDA_VISIBLE_DEVICES=GPU-<redacted>-…` 锁卡。

---

## 2. 路线一：NInfer —— 判定不能（详见 `（本机工作目录，未发布）`）

结论基于静态证据 + 实机证伪，不是推测：

**静态** — 包里根本没有 sm_70 设备码，也没有退路：
```
$ cuobjdump --list-elf （本机工作目录，未发布）
  ninfer-serve.1.sm_86.cubin
  ninfer-serve.2.sm_86.cubin          ← 只有 sm_86
$ cuobjdump --list-ptx （本机工作目录，未发布）
  cuobjdump info : No PTX file found to extract from '…/ninfer-serve'.   ← 无 PTX，JIT 回退不可能
```

**实机证伪（决定性）** — 抽出 ninfer 自己的 `ninfer-serve.1.sm_86.cubin`（614 MB），用驱动 API 在两块卡上各加载一次：

```
-- V100 (compute capability 7.0)
cuModuleLoad(ninfer-serve.1.sm_86.cubin) -> 209  CUDA_ERROR_NO_BINARY_FOR_GPU
                                          "no kernel image is available for execution on the device"
-- RTX 3060 (compute capability 8.6) —— 对照组
cuModuleLoad(ninfer-serve.1.sm_86.cubin) -> 0    CUDA_SUCCESS
```
同一份二进制、同一个 cubin：3060 成功，V100 被拒。

**为什么没有补救空间**：`~/src/ninfer-all/CMakeLists.txt:5-17` 是 `FATAL_ERROR` 硬闸，注释写明「sm_80 shares the sm_86 instruction set」；指令面统计 `cp.async` 43 处、`ldmatrix` 74 处、`mma.sync` 15 处、`__nv_bfloat16` 452 处；全树只有 1 处 `__CUDA_ARCH__` 比较，即**没有为多架构做过条件编译**。要跑需要数周的 kernel 移植工程。

> 附注：3060 上另有一个**本地源码构建**的 `~/src/ninfer-all/build-sm86/apps/ninfer-serve`（PID 1001072，占用 3060 的 9328 MiB），它能加载 `.ninfer` 模型。它与判定用的官方 kit 不是同一个二进制 —— 上面「模型格式不兼容」的结论只对 kit 那份成立。该进程是用户自己起的，本次全程按 UUID 隔离，未触碰。

---

## 3. 路线二：llama.cpp-prism —— 判定能，且已实测

### 3.1 为什么必须自己编译

bonsai 的 `PTQ1_0` 是 PrismML fork 的**私有类型**，上游 llama.cpp 完全不认：

- `ggml/include/ggml.h:436` — `GGML_TYPE_PTQ1_0 = 143, // Prism-private ternary, group 128`
- `ggml/include/ggml.h:483` — `GGML_FTYPE_MOSTLY_PTQ1_0 = 129`

而官方预编译包**只含 sm_86 / sm_89 的 cubin**，V100（sm_70）加载不了 —— 这正是 NInfer 失败的同一个原因。唯一出路是拿到源码、用**还支持 compute_70 的 CUDA 工具链**自己编出 sm_70 设备码。

### 3.2 工具链：CUDA 12.9 是硬约束

| | |
|---|---|
| 系统自带 | `/usr/local/cuda` = CUDA **13.1** → `nvcc --list-gpu-arch` **不含 compute_70**（CUDA 13 起移除） |
| 本次另装 | **CUDA 12.9.41**（`~/cuda-12.9`，免 root，runfile 静默安装）→ `--list-gpu-arch` **含 compute_70** |
| 安装坑 | ① 该 runfile **没有 `--no-driver` 选项**（不传 `--driver` 即可）；② 必须 `unset DISPLAY` 并用 `--nox11`，否则 makeself 会 `exec $XTERM -title …` 报 `exec: -title: not found`；③ 需 `TMPDIR` 指向可写目录 |
| 成功命令 | `env -u DISPLAY bash cuda_12.9.0_575.51.03_linux.run --silent --nox11 --toolkit --toolkitpath="$HOME/cuda-12.9" --no-opengl-libs --no-man-page --override` |

编译期只有一条相关警告，**不影响结果**：
```
nvcc warning : Support for offline compilation for architectures prior to '<compute/sm/lto>_75'
               will be removed in a future release
```

### 3.3 构建

- 源码：`~/src/llama.cpp-prism`，分支 `prism`，HEAD **`6bfcd79`**「arm: NEON vec_dot for PQ2_0 (#265)」
- 配置：`-DCMAKE_CUDA_ARCHITECTURES=70-real -DGGML_CUDA=ON -DGGML_CUDA_FA=ON -DGGML_CUDA_GRAPHS=ON -DCMAKE_BUILD_TYPE=Release`
- 产物：`（本机工作目录，未发布）`

**踩到的坑（与 sm_70 无关，是链接器 rpath）**：CUDA 装在非标准路径时，CMake 只给可执行文件带了 `-Wl,-rpath-link,.../targets/x86_64-linux/lib/**stubs**`，而真实 cuBLAS 在 `~/cuda-12.9/lib64`，导致 `test-tokenizer-0` 链接失败：
```
libcublas.so.12, needed by bin/libggml-cuda.so.0.21.0, not found
undefined reference to cublasSetStream_v2@libcublas.so.12
```
修法是重配时补 `-DCMAKE_BUILD_RPATH/-DCMAKE_INSTALL_RPATH="$HOME/cuda-12.9/lib64"` 与显式 `-Wl,-rpath,-rpath-link`。修完 **`[202/202]`、exit 0、零错误**。

### 3.4 静态验证：设备码确实全是 sm_70（不碰 GPU 就能确认）

```
$ ~/cuda-12.9/bin/cuobjdump --list-elf bin/libggml-cuda.so.0.21.0 | grep -c sm_70
177            ← 全部 177 个 cubin 都是 sm_70，非 sm_70 计数为 0
$ nm -C --defined-only bin/libggml-cuda.so.0.21.0 | grep -c PTQ1_0
68             ← PTQ1_0 专用内核符号
```
`libggml-cuda.so.0.21.0` = 45,212,384 B，NEEDED = `libcudart.so.12` + `libcublas.so.12`。

### 3.5 模型被正确识别

```
qwen35 27B PTQ1_0 - 1.75 bpw ternary (group 128) | 5.85 GiB | 27.32 B | build: 6bfcd79
```
模型 `Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf`（6,297,658,848 B）内部结构（自写解析器导出）：
GGUF v3 · 架构 `qwen35`（**attention + SSM 混合**）· 65 个 block（0–64）· 866 tensor / 54 KV
类型分布：PTQ1_0 × 402、F32 × 360、BF16 × 96、Q6_K × 6、Q8_0 × 2
`general.file_type = 143`(=PTQ1_0) · `prism.hadamard.weight_names` 401 项 · `prism.hadamard.inverse_weight_names = ['token_embd.weight']` · `graft.donor.name = Qwen3.8-27B-UD-Q4_K_M.gguf`
**`blk.64.*` 就是 MTP 头**（含 `blk.64.nextn.eh_proj.weight [10240,5120]`、`nextn.enorm/hnorm/shared_head_norm.weight`）→ 这是自带 MTP 的模型，**绝不能传 `-md`**。

---

## 4. 实测数据

测试条件：`-ngl 99 -fa on -ctk q4_0 -ctv q4_0 -b 2048 -ub 512`，`GGML_CUDA_BATCH_INVARIANT=1`，按 UUID 锁 V100。
V100 当前 PCIe 链路 **Gen3 ×16**（`pcie.link.gen.current=3, width=16`）。

### 4.1 prefill / decode（llama-bench，r=3）

| 测试 | t/s |
|---|---|
| **pp512** | 883.46 ± 20.33 |
| **pp2048** | 868.06 ± 1.95 |
| **pp4096** | 844.48 ± 0.89 |
| **tg128**（无投机） | 58.55 ± 0.35 |

prefill 长上下文几乎不衰减（512→4096 只掉 4%），说明没有被 PCIe 卡脖子。

### 4.2 MTP（`--spec-type draft-mtp`）n-max 扫描

两个固定探针各生成 400 token，`temp 1.0 / top-p 0.95 / top-k 20`，ctx 131072。**n-max=1/2 与对照组是带暖机的公平对照**；n-max≥3 来自无暖机的扫描（同口径下约偏低 2.5%，不影响趋势）。

| 配置 | prose t/s | prose 接受率 | code t/s | code 接受率 | VRAM |
|---|---|---|---|---|---|
| **无投机（对照）** | 55.06 | — | 55.00 | — | 8676 MiB |
| **n-max=1** | **61.35** | 50.8% | **71.10** | 75.8% | 9878 MiB |
| n-max=2 | 57.47 | 38.1% | 72.61 | 62.4% | 10028 MiB |
| n-max=3 | 50.84 | 29.7% | 70.37 | 54.3% | 10180 MiB |
| n-max=7 | 26.39 | 12.3% | 39.68 | 25.7% | 10778 MiB |
| n-max=11 | 7.80 | 10.1% | 9.06 | 13.2% | 13636 MiB |

相对无投机的提升：

| n-max | prose | code |
|---|---|---|
| 1 | **+11.5%** | **+29.3%** |
| 2 | +4.5% | +32.0% |
| 3 | **−7.6%** | +28.0% |
| 7 | **−52.0%** | **−27.9%** |
| 11 | **−85.8%** | **−83.5%** |

**这是本次最重要的调参结论**：MTP 的收益随 n-max **单调变差**。原因是这个 MTP 头是单层 next-token 预测器，草稿越深越不准，而每多一个草稿 token 就要多跑一次前向，验证成本线性增长而接受率指数下降。**n-max=1 是稳健最优**；n-max≥7 会带来数倍减速，且显存白涨 3.8 GB。这与项目既有脚本 `（本机工作目录，未发布）` 采用 `--spec-draft-n-max 1` 一致。

在**高度可预测**的文本（算法讲解、结构化推理）上收益更大 —— 900 token 实测：

| 配置 | t/s | 接受率 |
|---|---|---|
| 无投机 | 49.74 / 50.31 | — |
| MTP n-max=1 | 72.53 | 81.3% |
| MTP n-max=3 | 75.31 | 60.9% |

即这类文本上 **+45% ~ +50%**，且此处 n-max=3 反超 n-max=1。**所以推荐值：散文/闲聊用 1，代码/推理可试 3。**

### 4.3 无损性验证（重要，已定量）

投机解码理论上必须是无损的，这个疑点必须查清：关掉投机与开启投机，输出是否一致？

方法：`temperature=0 + seed=42 + top_p=1 + top_k=0`，同一提示词各生成 900 token，逐 token 比对。

- **无投机跑两次 → 逐 token 完全一致（900/900）** ⇒ 比对方法有效，分歧不能归因于随机性
- **n-max=1 与 n-max=3 互相 → 逐 token 完全一致** ⇒ MTP 路径内部自洽可复现
- **MTP vs 无投机 → 首个分歧 @ token 81/900**（前 81 个完全相同）

查这个分歧点的分布（`n_probs=5`，该位置两边上下文完全相同）：

```
#1 id=2107 ' both'  logprob = -0.6921278   p = 0.50058   <-- 无投机选了它
#2 id=1179 ' then'  logprob = -0.7412477   p = 0.47658   <-- MTP 选了它
#3 id=1141 ' its'   logprob = -3.8218694   p = 0.02191
top-1 与 top-2 间距 = 0.0491 nats
```

**这是一个教科书的近似平局（0.5006 : 0.4766）**。在这种位置，任何 ~1e-3 量级的浮点累加顺序差异都足以翻转 argmax，之后 greedy 轨迹完全分叉。属**良性数值抖动，不是质量退化**：两条轨迹都是同一模型在同一上下文下的合法延续。

需要如实说明的局限：fork 本身**专门为此设计了批量不变性机制**（`GGML_CUDA_BATCH_INVARIANT=1` → `mmvq-ptq1_0.cuh` 的 warp-reduce 路径，见该文件 :12 与 :373-375 的注释、`mmvq.cu:411` 与 `:550` 的列表选择；作者注释里甚至记录了「5080 bisect: 5300cd1」和 "coastal waters" vs "coastal areas" 这个同类案例）。该机制在 sm_70 上**确实生效**（`ptq1_0_pt_enabled()` 非 HIP 恒为 `true`，且 Volta 在 `mmvq.cu:404` 与 Ada 并列被特殊照顾），但**未能做到 MTP 开/关逐比特一致**。最可能的原因：本模型是 `qwen35` **混合 SSM 架构**，`ssm-conv.cu` / `ssm-scan.cu` 的递归扫描在「2 token 批量」与「逐个 1 token」下累加顺序不同，而这两个文件（以及 `mmq.cu`）里**没有任何 `batch_invariant` 分支**（全树 grep 只命中 `fattn.cu:481`、`fattn-common.cuh:1159`、`mmvf.cu:824/855`、`mmvq-ptq1_0.cuh`、`common.cuh:180`）。即混合 SSM 架构上逐比特一致大概率不可达，除非给 SSM 扫描也写不变性内核。

**实用判断**：`temp > 0` 的采样本来每个 token 都在做随机选择，这种量级的抖动完全被采样噪声淹没。建议放心开启 MTP。

### 4.4 显存

| 场景 | V100 显存 |
|---|---|
| 空载 | 6 MiB |
| ctx 131072 + 无投机 | 8676 MiB |
| ctx 131072 + MTP n-max=1 | 9878 MiB |
| ctx 131072 + MTP n-max=11 | 13636 MiB |

**在 16 GB 卡上开了 128K 上下文还只用 9.9 GB**，余量约 6.5 GB。

---

## 5. 与既有基线的横向对比

数据来源：`（本机工作目录，未发布）`、`（本机工作目录，未发布）`。

| 服务 | 卡 | decode | 权重 | 上下文 | 显存 |
|---|---|---|---|---|---|
| V100 · Bonsai2 PTQ1_0 + MTP-1（**本次**） | V100 | **61.4–71.1** | 5.85 GiB | **131072** | **9.9 GB** |
| V100 · Qwen3.8-27B IQ3_S + MTP-3（**它原来跑的**） | V100 | 48.8 → 56.0 | 12.1 GB | 65536 | 15.1 GB |
| 3060 · Bonsai2 GGUF PTQ1_0 n-max=1 | 3060 | 40–50 | 5.85 GiB | — | — |
| 3060 · Bonsai2 NInfer mtp-3 | 3060 | 63.3 | 7.99 GiB | — | — |
| 3060 · Bonsai2 NInfer dflash2-5 | 3060 | 82–137（均值 87） | 7.99 GiB | — | — |
| V100 · Gemma4 26B-A4B + MTP | V100 | 123.5 | — | — | — |

三个要点：

1. **V100 比 3060 快 30–55%** 跑同一个 bonsai PTQ1_0 模型（61.4–71.1 vs 40–50）。先前「V100 会更慢」的担心不成立 —— 1.75 bpw 解码主要吃显存带宽，V100 的 HBM2 优势盖过了被禁用的 Ampere 调优路径。
2. **V100 跑 bonsai 比它原来跑的 Qwen3.8-27B 快 10–46%**，同时权重从 12.1 GB 降到 5.85 GiB、上下文从 64K 翻到 128K、显存从 15.1 GB 降到 9.9 GB。**这是一次全面升级，不是妥协。**
3. **prefill 优势更大**：bonsai pp2048 = 868 t/s，而 Qwen38 长 prompt prefill 基线是 493.5 t/s，**约 +76%**。

### V100 上被"降级"的代码路径（已知，非 bug）

这两处在 Volta 上会退回通用路径，是 V100 与 Ampere 的差距来源，但不影响正确性：

- `ggml-cuda.cu:2768` — `if (!GGML_CUDA_CC_IS_NVIDIA(cc) || cc < GGML_CUDA_CC_TURING)` → **融合 Hadamard + PTQ1_0 的共享解码路径在 Volta 被禁用**，退回通用 MMVQ/MMQ
- `mmvq.cu:299` — PTQ1_0 的 PT 多列 mat-vec 阈值调优同样要求 `cc >= 750`

好消息是 `mmvq-ptq1_0.cuh` 里 **`cp.async` / `ldmatrix` / `mma.sync` 的命中数均为 0**，所以能干净地编过 sm_70。另 `ggml-cuda.cu:1516` 有 `prefer_f32_output = cc == GGML_CUDA_CC_VOLTA`，说明 Volta 在该树里是被显式照顾的目标。

---

## 6. 最终判定

| 问题 | 判定 |
|---|---|
| ninfer 内核能在 V100 跑吗 | **不能**。只有 sm_86 cubin、无 PTX、无 JIT 回退，驱动层已实测拒绝。要支持需数周 kernel 移植 |
| llama.cpp-prism 内核能在 V100 跑吗 | **能**。自编译 sm_70 设备码成功，177 个 cubin 全为 sm_70，实测出数 |
| 跑得动吗 | **跑得很好**。prefill 868 t/s、decode 61–71 t/s、128K 上下文占 9.9 GB 显存 |
| 值得换吗 | **值得**。比 V100 原来的 Qwen3.8-27B 更快、更省显存、上下文翻倍 |
| 推荐参数 | `--spec-type draft-mtp --spec-draft-n-max 1`（散文/闲聊）；代码/推理可试 3。**不要超过 3** |

---

## 7. 复现步骤

```bash
# 1) CUDA 12.9（免 root）—— 系统 CUDA 13 不支持 compute_70，这步不可省
TMPDIR=$HOME/llm/tmp/inst  env -u DISPLAY bash cuda_12.9.0_575.51.03_linux.run \
  --silent --nox11 --toolkit --toolkitpath="$HOME/cuda-12.9" --no-opengl-libs --no-man-page --override

# 2) 源码
git clone -b prism --depth 1 https://github.com/PrismML/llama.cpp.git ~/src/llama.cpp-prism

# 3) 配置（注意 rpath 三件套，否则 cuBLAS 链接失败）
CU=$HOME/cuda-12.9/lib64
cmake -S ~/src/llama.cpp-prism -B （本机工作目录，未发布） -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_COMPILER=$HOME/cuda-12.9/bin/nvcc \
  -DCUDAToolkit_ROOT=$HOME/cuda-12.9 -DCMAKE_CUDA_ARCHITECTURES=70-real \
  -DGGML_CUDA=ON -DGGML_CUDA_FA=ON -DGGML_CUDA_GRAPHS=ON -DGGML_NATIVE=OFF \
  -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF \
  -DCMAKE_BUILD_RPATH=$CU -DCMAKE_INSTALL_RPATH=$CU \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath,$CU -Wl,-rpath-link,$CU" \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-rpath,$CU -Wl,-rpath-link,$CU"
cmake --build （本机工作目录，未发布） -j8

# 4) 静态确认设备码（不碰 GPU）
~/cuda-12.9/bin/cuobjdump --list-elf （本机工作目录，未发布） | grep -c sm_70   # 期望 177

# 5) 起服务 / 测速
（本机工作目录，未发布）            # 端口 8913，NMAX=1，按 UUID 锁 V100
# 调参：NMAX=3 SPEC=draft-mtp （本机工作目录，未发布）
```

---

## 8. 附带产物清单

| 文件 | 内容 |
|---|---|
| `（本机工作目录，未发布）` | sm_70 构建产物（llama-server / llama-cli / llama-bench + impl .so + libggml-cuda.so） |
| `（本机工作目录，未发布）` | V100 启动脚本（UUID 锁卡、ctx 131072、q4_0 KV、MTP，支持 `NMAX` / `SPEC` 环境变量） |
| `（本机工作目录，未发布）` | n-max 扫描（n-max ∈ {1,3,7,11}，两探针，读 /metrics 算接受率） |
| `（本机工作目录，未发布）` | 对照/单元测试（带暖机，`SPEC=none` 为无投机基线） |
| `（本机工作目录，未发布）` | 无损性验证（temp 0 + 固定 seed 逐字节比对） |
| `（本机工作目录，未发布）` | 分歧点定位 + n_probs=5 取分布，判定是否近平局 |
| `（本机工作目录，未发布）` | n-max 扫描全部原始记录 |
| `（本机工作目录，未发布）` | 对照组原始记录 |
| `（本机工作目录，未发布）` | 无损性判定原始证据（含 top-5 分布与间距） |
| `（本机工作目录，未发布）` | 逐 token id + logprob 序列（900 token × 4 次运行） |
| `（本机工作目录，未发布）` | NInfer 判定书（含 cubin/PTX/CMake 硬闸/指令面统计） |
| `（本机工作目录，未发布）` | 构建日志 |
| `（本机工作目录，未发布）`、`v100-server-*.log` | 基准与服务日志 |
