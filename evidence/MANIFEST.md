# MANIFEST — 输入与产物的身份

生成时间：2026-10-07T04:01:23+0800
说明：本文件由 `scripts/95-manifest.sh` 生成。**任何数字离开这张表都无法追溯。**

## 1. 输入

| 输入 | 标识 | 值 |
|---|---|---|
| 引擎源码仓库 | repo | `https://github.com/iamwavecut/ninfer-all.git` |
| 引擎源码 commit | sha | `796f985007775f4bc7cfde53804fa22e7d60dbf8` |
| 引擎源码版本 | VERSION | `0.12.0-rtx3090` |
| 引擎源码树 | tree | `91c8c547e860449d5cb4b69f68c31c1000c4a917` |
| 方法学参照仓库 | repo | `https://github.com/suanrongqieqiezi/ninfer-rtx30-bench.git` |
| 方法学参照 commit | sha | `c2f882ba274af6d31e941e81b114300a1dc9a657` |
| 模型仓库 | repo | `WaveCut/Ternary-Bonsai-2-27B-NInfer-v3` |
| 模型 revision | sha | `b85b33627b27b9757a5a094fc74785a53e99f8ee` |
| 模型 sha256 | sha256 | `cdc4810b0ff17c40d0f62cf214b6e0bcd08346e9eb05ca53371507037793c14a` |
| 模型字节数 | bytes | `9520051456` |
| CUDA redist 清单 | sha256 | `55304d9d831bb095d9594aab276f96d2f0e30919f4cc1b3f6ca78cdb5f643e11` |

## 2. 工具链（精确版本见 `config/toolchain.lock`）

| 项 | 值 |
|---|---|
| CUDA | 13.1（redist 13.1.0，地板 12.8） |
| nvcc | `/home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux/.store/toolchain/cuda-13.1/bin/nvcc` |
| nvcc release | `release 13.1` |
| 目标架构 | sm_86 |
| host CC | `/usr/bin/gcc-13` / `/usr/bin/g++-13` |
| 构建并行度 | 6 |

## 3. 构建产物

| 产物 | 字节 | sha256 |
|---|---|---|
| `ninfer` | 724588968 | `73123b32b5f91cc110e4ae787ed8b70c4a06fcbf93cafa9d09ce976ae6f47a29` |
| `ninfer-serve` | 727945672 | `7ebf2ebf6c086f0f135f97090825c0a8a0a05fd02ffc9199c5faf9dc6cc6d574` |
| `ninfer-calibrate` | 613776584 | `e2ff5e50699652d212615ff104871081449fe1d4b785483eadbdeb401a200e3c` |
| `ninfer-perplexity` | 724515800 | `b15e5a15762605a5f3d80de4d89c771c5ada1d6c9b876ec6a44629e73ac01ff7` |

（Release 构建默认不保证 bit-reproducible，故这些 sha256 标识的是**本次构建**，不是唯一可能的结果。）

## 4. device profile（每张卡不同）

| 项 | 值 |
|---|---|
| 路径 | `/home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux/profiles/device-profiles.json` |
| 字节 | 7953 |
| sha256 | `737c5f29c549f75a229ad8c56f3f710155856d2c598f737bd1843586cffdb924` |
| GPU | RTX 3060 / sm_86 / 28 SM / `GPU-<redacted>-62f6-d10e-9cd0-26d071ac1974` |

## 5. 结果

| 文件 | sha256 |
|---|---|
| `agent-context-20261006-213902.json` | `c47eae3845fcd7657a3d062d298714ef1f19c824141c933ba7a821f9a20896af` |
| `agent-correctness-20261006-214435.json` | `5cbb9c6ac7c46601c2ce03f64fd8aa4b26bb4a891685986b28e54df66f0cc452` |
| `agent-correctness-20261006-215313.json` | `84881d110b7b8327c42051157cea9868057f44ae7ad15cf8387e83cc987eca72` |
| `agent-loop-20261006-213627.json` | `3319adff251bb141861c2bcaec55d39318c854486ce6e3774d87211b24984407` |
| `agent-loop-20261006-213928.json` | `8d654268501677cd6d36d1d6c10180434a0785b58fabd5ab061d41ab62b4b11a` |
| `agent-stability-20261006-213928.json` | `97618393236fec92cd74f40a5b7824cc5335b0f7086e719ba5e426e6e46cb7e2` |
| `kv-feasibility-desktop.json` | `375e9d2a46dc7c9e8248058bf177c0d65b19c7b586480488d7a7fe8310c382e1` |

## 6. 补丁

**零补丁。** 源码未做任何修改 —— 见 `patches/README.md`（这本身是结论的一部分）。

## 7. 环境记账

| 项 | 值 |
|---|---|
| 主机 | <user>-MS-7B89 |
| 内核 | 7.0.0-38-generic |
| 驱动 | 580.178.04 |
| 3060 PCIe | 2, 4 |
