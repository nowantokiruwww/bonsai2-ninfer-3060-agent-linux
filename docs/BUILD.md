# 从零编译引擎：完整配方

> 这份文档回答的是公开仓库里长期缺失的那一步：**引擎是怎么编出来的**。
> 之前只有 `docs/PORTING-LEDGER.md` 里的病历条目（L05/L06/L10/L13/L16），没有可执行配方。
> 现在配方在 `scripts/build/`，证据在 `evidence/`。

## 0. 前提

| 项 | 要求 | 来源 |
|---|---|---|
| GPU | sm_86（RTX 3060/3070/3080/3090） | 产物只有 sm_86 cubin，见 L11 |
| 驱动 | ≥ 580（实测 580.178.04） | `evidence/baseline/011-*.log` |
| 编译器 | gcc-13 / g++-13 | `evidence/toolchain/deps.txt` |
| 构建 | cmake ≥ 3.x + ninja | `evidence/baseline/023-*.log` |
| CUDA | **不需要系统装 CUDA** | 工具链由 `20-cuda-fetch.sh` 下载进 `.store/` |
| RAM | ≥ 23 GiB 时 `-j 6`；`-j 24` 曾触发内核 BugCheck | L13，`evidence/build/memory-pressure-diagnosis.txt` |

## 1. 上游血缘（为什么用这个 fork）

```
engine  = https://github.com/iamwavecut/ninfer-all.git  commit 796f985007775f4bc7cfde53804fa22e7d60dbf8  (VERSION 0.12.0-rtx3090)
method  = https://github.com/suanrongqieqiezi/ninfer-rtx30-bench.git  commit c2f882ba274af6d31e941e81b114300a1dc9a657
model   = WaveCut/Ternary-Bonsai-2-27B-NInfer-v3  revision b85b33627b27b9757a5a094fc74785a53e99f8ee
          Ternary-Bonsai-2-27B-ninfer-v3.ninfer  9,520,051,456 B
          sha256 cdc4810b0ff17c40d0f62cf214b6e0bcd08346e9eb05ca53371507037793c14a
```

官方 `Neroued/ninfer` 拒收这个工件：它需要 `t2_g128_fp16` 与 `hadamard_signs`，
只有上面这条线支持（L01）。方法学仓库 license 为 null，所以**它的脚本一行不抄**，只引用口径。

## 2. 工具链：项目自带 CUDA 13.1

`scripts/build/20-cuda-fetch.sh` 从 NVIDIA 官方 redist 清单取 17 个组件，逐件校验 sha256 与字节数，
解包后合并成常规布局。精确版本与哈希在 **`config/toolchain.lock`**：

```
requested_version = 13.1
redist_sha256     = 55304d9d831bb095d9594aab276f96d2f0e30919f4cc1b3f6ca78cdb5f643e11
floor             = 12.8   # CMakeLists.txt:201-204 强制
cuda_nvcc         v13.1.80  30,014,972 B
libcublas         v13.2.0.9 836,864,428 B
libnvjitlink      v13.1.80  55,647,596 B
libnvvm           v13.1.80  44,796,540 B
gpu_archs         compute_75 80 86 87 88 89 90 100 110 103 120 121
```

两个坑（病历里写过，这里是配方）：

- **`cuda_nvcc` 里没有 `cicc`** —— 它在 `libnvvm` 组件里。只装 nvcc 会编不了（L05）。
- **CUDA 13 的组件布局是 `lib/`，而 nvcc 期望 `lib64/`** —— 合并时需要建软链（L06）。

## 3. 编译

```bash
export CUDA_HOME="$STORE/toolchain/cuda-13.1"
export CUDACXX="$CUDA_HOME/bin/nvcc"
# PATH 里任何 /usr/local/cuda 或 ~/cuda 都要剔除，否则产物 RUNPATH 会指向外部

cmake -S "$STORE/src/ninfer-all" -B "$STORE/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/usr/bin/gcc-13 \
  -DCMAKE_CXX_COMPILER=/usr/bin/g++-13 \
  -DCMAKE_CUDA_COMPILER="$CUDACXX" \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 \
  -DCUDAToolkit_ROOT="$CUDA_HOME" \
  -DCMAKE_CUDA_ARCHITECTURES=86 \
  -DNINFER_BUILD_APPS=ON -DBUILD_TESTING=OFF -DNINFER_BUILD_BENCHMARKS=OFF

cmake --build "$STORE/build" --parallel 6      # 历史耗时 96.6 分钟
```

构建成本是双峰的：21 个 attention kernel TU 是重尾（L10/L13）。

## 4. 产物门禁（必须跑，不能跳过）

```bash
LC_ALL=C readelf -d "$BIN" | grep -E 'RUNPATH|RPATH'   # RUNPATH 必须落在项目内
ldd "$BIN" | grep -E 'libcudart|libcublas|libnvjitlink' | grep -v "$CUDA_HOME"   # 必须为空
cuobjdump -lelf "$BIN"    # 必须全是 sm_86
cuobjdump -lptx "$BIN"    # 如实记录有无 PTX
```

结果证据：`evidence/isolation/runpath.txt`、`evidence/isolation/ldd.txt`、
`evidence/build/cuobjdump-elf.txt`、`evidence/build/cuobjdump-ptx.txt`。

必须 `LC_ALL=C`：非英文 locale 下 readelf 把 "Library runpath" 本地化，
`grep -oE '/[^]]*'` 会抓到本地化文本里的斜杠，实测得到 `runpath = /值` → 误判 FAIL（L15）。

**只有 `libcuda.so.1` 来自系统驱动**，其余 CUDA 库全部自带。这就是为什么换一台机器
（不同驱动 userland）还能跑：RUNPATH 硬钉在项目内（L02/L22）。

产物身份：`evidence/build/binary-identity.txt`（sha256 与 `scripts/fetch-runtime.sh` 里的
`KNOWN_NINFER_SERVE_SHA` 对得上）。

## 5. 标定与 KV 门禁

3060 没有内置设备 profile（28 SM），必须标定：

```bash
bash scripts/build/70-calibrate.sh     # 产出 evidence/calibrate/device-profiles.json
bash scripts/build/75-kv-gate.sh       # 逐 kv-dtype × 逐容量实测
```

KV 容量不是常数：它取决于 `--kv-dtype` 和当时桌面显存占用。`24576` 只是某个时刻的值（L08/L21）。
实测矩阵在 `evidence/kv-gate/runs/`：`int8-24576/32768/49152`、`rk2v4-e8-24576/49152/65536/76768`、
`rk4v4-e8-*`、`rk8v4-*`。生产选 `rk2v4-e8` + 49152。

## 6. 为什么 V100 编不出来

不是"没优化"，是**架构不可达**（L11）：

- `cuModuleLoad` 返回 `209 CUDA_ERROR_NO_BINARY_FOR_GPU`
- 产物只有 sm_86 cubin，没有 PTX → 无法 JIT 回退
- 源码里 `cp.async` 43 处、`ldmatrix` 74 处、`mma.sync` 15 处、`__nv_bfloat16` 452 处
- 全树只有 1 个 `__CUDA_ARCH__` 回退分支
- CUDA 13 已移除 `compute_70`

顺带一个设备顺序陷阱：`CUDA device0 = V100, device1 = 3060`，与 `nvidia-smi` 顺序相反。
按 index 选卡会选错。修法：按 UUID 锁卡 + `CUDA_DEVICE_ORDER=PCI_BUS_ID`。

## 7. 复现的诚实边界

这份配方能复现**编译**，但以下数字依赖当时那台机器：

- KV 容量随桌面显存占用变化
- 96.6 分钟编译耗时随内存/核数变化
- 吞吐（202 tok/s agent 流量 / 26 tok/s 中文散文地板）随驱动与桌面负载变化

中文散文 26 tok/s 的地板是显存带宽：8 GiB ÷ ~300 GB/s ≈ 26–37 tok/s（L29）。
投机解码在 6% 接受率下是纯 no-op：spec off 26.4/26.3/26.0 vs spec on 26.2/26.3/27.2。
