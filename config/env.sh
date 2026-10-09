#!/usr/bin/env bash
# config/env.sh — 本项目唯一改动点（去黑盒化：每个输入都有来源、版本、哈希）
#
# 设计原则：
#   1. 所有外部输入在此声明，脚本不得硬编码路径或版本。
#   2. 每个输入都带来源 URL 与期望哈希；不匹配即失败。
#   3. 大件全部落在 $STORE 下（可用 BSTORE 环境变量迁到别的盘）。
#
# 用法：source config/env.sh

# ---------------------------------------------------------------------------
# 目录布局
# ---------------------------------------------------------------------------
export PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STORE="${BSTORE:-$PROJ/.store}"

export STORE_TOOLCHAIN="$STORE/toolchain"
export STORE_MODELS="$STORE/models"
export STORE_BUILD="$STORE/build"
export STORE_SRC="$STORE/src"
export STORE_REFS="$STORE/refs"          # 只读参照仓库（方法学）

# ---------------------------------------------------------------------------
# 引擎源码上游（唯一可行的线：Bonsai v3 工件需要的 t2_g128_fp16 / hadamard_signs
# 只存在于这条线；官方 Neroued/ninfer 会拒收该工件）
# ---------------------------------------------------------------------------
export NINFER_SRC_REPO="https://github.com/iamwavecut/ninfer-all.git"
export NINFER_SRC_COMMIT="796f985007775f4bc7cfde53804fa22e7d60dbf8"
export NINFER_SRC_VERSION="0.12.0-rtx3090"
export NINFER_SRC_DIR="$STORE_SRC/ninfer-all"

# 方法学参照仓库（只读；license = null，故其脚本一行不抄，仅引用口径）
export BENCH_REPO="https://github.com/suanrongqieqiezi/ninfer-rtx30-bench.git"
export BENCH_REPO_COMMIT="c2f882ba274af6d31e941e81b114300a1dc9a657"
export BENCH_REPO_DIR="$STORE_REFS/ninfer-rtx30-bench"

# ---------------------------------------------------------------------------
# 模型工件（官方发布 v3，HF/ModelScope 侧）
# ---------------------------------------------------------------------------
export NINFER_MODEL_NAME="Ternary-Bonsai-2-27B-ninfer-v3.ninfer"
export NINFER_MODEL_HF_REPO="WaveCut/Ternary-Bonsai-2-27B-NInfer-v3"
export NINFER_MODEL_HF_REVISION="b85b33627b27b9757a5a094fc74785a53e99f8ee"
export NINFER_MODEL_SHA256="cdc4810b0ff17c40d0f62cf214b6e0bcd08346e9eb05ca53371507037793c14a"
export NINFER_MODEL_BYTES="9520051456"
# huggingface.co 在本环境 DNS 污染/超时；hf-mirror.com 实测可达。
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export NINFER_MODEL_PATH="$STORE_MODELS/$NINFER_MODEL_NAME"

# ---------------------------------------------------------------------------
# CUDA 工具链（项目自带；地板 12.8 由 CMakeLists.txt:201-204 强制）
# ---------------------------------------------------------------------------
export NINFER_CUDA_FLOOR="12.8"
export NINFER_CUDA_VERSION="${NINFER_CUDA_VERSION:-13.1}"
export NINFER_CUDA_REDIST="${NINFER_CUDA_REDIST:-13.1.0}"      # redist 清单版本
export NINFER_CUDA_DIR="$STORE_TOOLCHAIN/cuda-$NINFER_CUDA_VERSION"
export NINFER_CUDA_MIRROR="https://developer.download.nvidia.cn/compute/cuda"
export NINFER_CUDA_REDIST_BASE="$NINFER_CUDA_MIRROR/redist"

# 组件化安装（免 root、逐件 sha256 校验）。NVIDIA 官方 redist 清单里每个组件
# 都带 linux-x86_64 的 relative_path / sha256 / size。
# 这是本项目"项目自带工具链"的实现方式：不装系统包、不用 5GB runfile。
# 注意：components 与版本耦合（清单里带精确版本号），改 NINFER_CUDA_REDIST 必须重跑。
# 后 7 个是随手带上的极小头文件组件（合计 <2MB），用来避免"少一个 header 就要重跑一轮"。
# libnvvm 是必需的：nvcc 的 C 前端在 libnvvm/ 里（bin/../nvvm/bin/cicc），
# cuda_nvcc 组件本身不含它 —— 见 PORTING-LEDGER「组件化 CUDA 少件」。
export NINFER_CUDA_COMPONENTS="${NINFER_CUDA_COMPONENTS:-\
cuda_nvcc cuda_crt cuda_cudart cuda_cccl cuda_culibos cuda_cuobjdump cuda_nvprune \
libcublas libnvjitlink libnvfatbin libnvvm \
cuda_nvtx cuda_profiler_api cuda_nvml_dev cuda_nvdisasm cuda_cuxxfilt cuda_opencl cuda_sandbox_dev}"

# 编译目标架构：RTX 3060/3080/3090 同为 sm_86
export NINFER_ARCH="${NINFER_ARCH:-86}"
# 并行度硬上限 6：bench 记录中 31.8GB 内存 -j 24 触发内核 BugCheck；本机仅 23Gi
export NINFER_JOBS="${NINFER_JOBS:-6}"

export CC_HOST="/usr/bin/gcc-13"
export CXX_HOST="/usr/bin/g++-13"

# ---------------------------------------------------------------------------
# GPU 选择：必须按 UUID，不能用序号
#   CUDA 运行时设备序与 nvidia-smi 相反（device0=V100 sm_70、device1=3060 sm_86）
# ---------------------------------------------------------------------------
export GPU_UUID_3060="${GPU_UUID_3060:-GPU-<redacted>}"
export GPU_UUID_V100="${GPU_UUID_V100:-GPU-<redacted>}"

# ---------------------------------------------------------------------------
# device profile 门禁：必须落在项目内，避免复用 ~/.cache/ninfer 里的旧 profile
# ---------------------------------------------------------------------------
export NINFER_DEVICE_PROFILES="$PROJ/profiles/device-profiles.json"
export FOREIGN_PROFILE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/ninfer/device-profiles.json"

# ---------------------------------------------------------------------------
# 服务与验收
# ---------------------------------------------------------------------------
export NINFER_HOST="127.0.0.1"
export NINFER_PORT="${NINFER_PORT:-8098}"
export NINFER_MODEL_ID="bonsai2-27b"
# KV 由 §4.2 门禁扫描决定，禁止预设 bench 的 24576
export KV_DTYPE="${KV_DTYPE:-}"
export KV_CAPACITY="${KV_CAPACITY:-}"
# 投机解码：默认对齐 bench 的 dflash2 K=7；NINFER_SPEC=none 则关掉
export NINFER_SPEC="${NINFER_SPEC:-dflash2}"
export NINFER_DRAFT="${NINFER_DRAFT:-7}"
# 思考预算 1024（不是 4096）：L28 实测定档，与 3060 生产服务一致。
# 4096 会让每个请求固定烧满 4096 个思考 token（固定任务墙钟 67.8s、真正写出文件 1/3）；
# 1024 是 44.2s、3/3。详见 PORTING-LEDGER.md 的 L28 与 L27。
# ⚠ 刻意**不加** --greedy、也不加 --no-thinking：两者组合会触发 L26 复读锁死。
export NINFER_EXTRA_FLAGS="${NINFER_EXTRA_FLAGS:---max-concurrency 1 --temperature 1.0 --top-p 0.95 --top-k 20 --default-reasoning-effort medium --default-thinking-budget 1024}"
export NINFER_VERSION="${NINFER_VERSION:-$(cat "$PROJ/VERSION" 2>/dev/null || echo 0.1.0)}"

# ---------------------------------------------------------------------------
# 构建产物
# ---------------------------------------------------------------------------
export BUILD_DIR="$STORE_BUILD/build-sm86"
export NINFER_SERVE="$BUILD_DIR/apps/ninfer-serve"
export NINFER_CALIBRATE="$BUILD_DIR/apps/ninfer-calibrate"

# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------
export PHASE="${PHASE:-}"
export LOG_ROOT="${LOG_ROOT:-}"
