# NInfer 能否在 Tesla V100-SXM2-16GB 上运行 —— 判定书

- 日期：2026-10-06
- 结论：**不能。** 不是编译选项问题，是 kernel 移植工程问题。
- 判定依据：静态证据（cubin/PTX/CMake 硬闸/指令面统计）+ 实机证伪（用 ninfer 自己的 sm_86 cubin 在 V100 上做驱动层加载）。
- 原始证据文件：`（本机工作目录，未发布）`

## 0. 硬件事实

| | nvidia-smi index | UUID | compute capability | 显存 |
|---|---|---|---|---|
| RTX 3060 | 0 | `GPU-<redacted>` | 8.6 | 12288 MiB |
| Tesla V100-SXM2-16GB | 1 | `GPU-<redacted>` | **7.0** | 16384 MiB |

⚠ **CUDA 运行时的设备序号与 nvidia-smi 序号相反**：不带 `CUDA_VISIBLE_DEVICES` 时，CUDA device 0 = V100、device 1 = RTX 3060。任何脚本都必须按 **UUID** 锁卡（本机既有脚本用 `lib-common.sh` 的 `pin_gpu` 就是为此）。

## 1. 决定性实机证伪

从 `ninfer-serve` 里 `cuobjdump -xelf` 抽出的**它自己的** `ninfer-serve.1.sm_86.cubin`（614 MB），用驱动 API `cuModuleLoad` 在两块卡上各加载一次：

```
-- V100 (GPU-<redacted>-…, compute capability 7.0)
device 0 = Tesla V100-SXM2-16GB  (compute capability 7.0)
cuModuleLoad(ninfer-serve.1.sm_86.cubin) -> 209  name=CUDA_ERROR_NO_BINARY_FOR_GPU
                                              str=no kernel image is available for execution on the device
exit=1

-- RTX 3060 (GPU-<redacted>-…, compute capability 8.6) —— 对照组
device 0 = NVIDIA GeForce RTX 3060  (compute capability 8.6)
cuModuleLoad(ninfer-serve.1.sm_86.cubin) -> 0  name=CUDA_SUCCESS  str=no error
exit=0
```

同一份二进制、同一个 cubin，3060 加载成功、V100 返回 `CUDA_ERROR_NO_BINARY_FOR_GPU`。这是最终判定。

## 2. 为什么没有补救空间

1. **包里没有 sm_70 设备码**
   ```
   $ cuobjdump --list-elf kit/bin/ninfer-serve
   ELF file 1: ninfer-serve.1.sm_86.cubin
   ELF file 2: ninfer-serve.2.sm_86.cubin
   ```
   `kit/bin/ninfer` 同样只有 2 个 sm_86。**只有 sm_86。**
2. **没有 PTX，所以没有 JIT 回退**
   ```
   $ cuobjdump --list-ptx kit/bin/ninfer-serve
   cuobjdump info : No PTX file found to extract from '…/ninfer-serve'.
   ```
   PTX 只能向前兼容（低版 PTX → 高算力卡），即使有 PTX 也无法降到 sm_70。
3. **源码显式拒绝非 80/86/89/120a**（`~/src/ninfer-all/CMakeLists.txt:5-17`）
   ```cmake
   if(NOT CMAKE_CUDA_ARCHITECTURES MATCHES "^(80|86|89|120a)$")
       message(FATAL_ERROR "NInfer supports CMAKE_CUDA_ARCHITECTURES=80, 86, 89 or 120a; got '${CMAKE_CUDA_ARCHITECTURES}'")
   ```
   注释给出的理由是：sm_80(GA100) 之所以被接受，是因为它 **"shares the sm_86 instruction set the kernels use"** —— Volta 不共享这套指令集。
4. **kernel 真的用了 Volta 没有的硬件能力**（`~/src/ninfer-all` 源码扫描，按命中文件数）
   | 指令/类型 | 命中的文件数 | sm_70 支持 |
   |---|---|---|
   | `cp.async`（异步拷贝） | 43 | ✗（sm_80+） |
   | `ldmatrix` | 74 | ✗（sm_75+） |
   | `mma.sync` | 15 | ✗（sm_80+ 形态） |
   | `__nv_bfloat16` | 452 | ✗（Volta 无 bf16） |
   | `__CUDA_ARCH__` 判断（回退分支） | **全树仅 1 处** | — |
   最后一行是关键：几乎没有 arch 回退分支，说明代码库从未为老架构设计过。
5. **连编译都编不出来**：本机只有 CUDA **13.1.115**，`nvcc --list-gpu-arch` = `75 80 86 87 88 89 90 100 103 110 120 121`，**没有 compute_70**（CUDA 13.0 起移除 Volta）。要编 sm_70 必须先有 CUDA ≤12.9 工具链。
6. **旁证（上游自己的态度）**：`RELEASE_NOTES_0.12.0.md` 把 GA100/sm_80 称为 *"an **unmeasured** compatibility target"*，还专门开了分支 `feat/sm80-cmp170hx-probe` + 判定脚本 `scripts/sm80-probe/probe.sh` 来回答「这块租来的 GPU 值不值得移植」。**连 sm_80 都还是待移植/待测量状态，sm_70 只会更远。**

## 3. 顺带发现：现有那个 `.ninfer` 模型本身也加载不了

```
$ ninfer-serve （本机工作目录，未发布） --max-context 1024 --kv-capacity 1024
[info]  ninfer-serve: loading model...
[error] ninfer-serve: artifact magic is not NInfer v1 or v2
```

这与 `（本机工作目录，未发布）` §三 记录的结论一致且更早触发：该文件头部魔数不是 NInfer v1/v2，之前用 `ninfer-serve` 跑时表现为 `unknown tensor format: PQ2_0_G128`（322 个 tensor）。根因是 **kit 来自 `Don-Chad/ninfer-3090`（v0.6.1-rtx3090），模型来自 `iamwavecut/ninfer-all`，两个 fork 的格式集合不同**。所以这条路在 **3060 上也是断的**，与 V100 无关。

## 4. 如果一定要在 V100 上跑 ninfer，需要做什么

按 `scripts/sm80-probe/probe.sh` 的思路新开一条 sm_70 移植线，而不是改配置：

1. 建 CUDA ≤12.9 工具链环境（`arch=70`）。
2. 把 43 个文件的 `cp.async` 换成同步/双缓冲拷贝，74 个文件的 `ldmatrix` 换成 `ld.shared` + 手写 layout，15 处 `mma.sync` 换成 V100 的 `wmma`/HMMA（或退回 SIMT），把 452 处 bf16 路径替换为 fp16 路径并补 `__CUDA_ARCH__` 回退分支。
3. 重新做数值验证与调优（V100 的 smem/寄存器/带宽特性与 Ampere 差异很大，tile 表要重调）。

量级判断：**这是数周级别的 kernel 移植 + 调优项目**，不是本次「卸卡 + 试试能不能跑」的范围。

## 5. 建议

- **V100 不要走 ninfer**，走 llama.cpp 线（见 `bonsai-on-v100-*.md` 的实测记录）。
- **3060 侧若要恢复 NInfer 主路线**（历史基线 82–137 tok/s），需要补的是**格式匹配**，不是架构：
  - 用 `iamwavecut/ninfer-all` 的引擎（Docker 镜像 `ghcr.io/iamwavecut/ninfer-all:latest`，内含 sm_86 + sm_120a 两个 build），或
  - 用 `（本机工作目录，未发布）` 里的重打包工具把权重转成 kit 认识的格式。
- `~/src/ninfer-all/scripts/sm80-probe/probe.sh` 这套判定框架可以原样复用于 sm_70 的可行性答辩，但当前证据已经足以否掉它。
