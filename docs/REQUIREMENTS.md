# 环境依赖

这份文档回答一个问题：**在一台干净的机器上，要跑起这个仓库，需要先有什么。**

原则：越少越好。本仓库**不依赖** CUDA Toolkit、不依赖 pip、不依赖 Docker、不依赖任何 Python 第三方包。

---

## 1. 必须有

### 1.1 NVIDIA 显卡，compute capability 8.6

引擎只编译了 `sm_86` 内核。这不是配置项，是编译期的架构闸门。

| 卡 | compute capability | 能不能跑 |
|---|---|---|
| RTX 3060 / 3060 Ti | 8.6 | ✅ |
| RTX 3070 / 3070 Ti | 8.6 | ✅ |
| RTX 3080 / 3080 Ti | 8.6 | ✅ |
| RTX 3090 / 3090 Ti | 8.6 | ✅ |
| RTX 4090 | 8.9 | ❌ 没有 sm_89 内核 |
| V100 | 7.0 | ❌ 没有 sm_70 内核，且 CUDA 13 已不支持 compute_70 |

架构不对时的报错：

```
cudaErrorNoKernelImageForDevice: no kernel image is available for execution on the device
```

检查：

```bash
nvidia-smi --query-gpu=index,uuid,name,memory.total,compute_cap --format=csv
```

> **⚠ 设备序陷阱。** CUDA 运行时的设备编号和 `nvidia-smi` 的编号**可能是反的**。
> 多卡机器上必须用 UUID 锁卡，不能按序号。本项目实测过：不锁卡时引擎挑中了 V100（sm_70），
> 当场报 `cudaErrorNoKernelImageForDevice`（病历 L29）。
> 本仓库的 `app/env.sh` 会自动挑 `compute_cap=8.6` 且空闲最多的那张卡，也可在
> `config/runtime.env` 里手工指定 `GPU_UUID`。

### 1.2 显存 ≥ 12 GB

| 用途 | 占用 |
|---|---|
| 权重常驻 | 7.99 GiB |
| KV cache（默认 rk2v4-e8 @ 49,152） | 2.15 GiB |
| 运行时缓冲 | 约 0.3 GiB |
| **合计** | **约 10.8 GiB** |

12 GB 的卡跑得下，但**必须给桌面留余量**。桌面上开个浏览器，KV 容量上限就会往下掉，
所以默认取 49,152 而不是实测顶端的 76,768（病历 L21）。

### 1.3 NVIDIA 驱动 ≥ 580

本仓库当前发布的 CUDA 13.1 用户态运行库要求 NVIDIA 580 系列驱动；已端到端实测 **580.178.04**。低于 580 的驱动不受支持。

```bash
nvidia-smi --query-gpu=driver_version --format=csv,noheader
```

**不需要装 CUDA Toolkit。** 引擎载荷里自带 `libcudart.so.13`、`libcublas.so.13`、
`libcublasLt.so.13`、`libnvJitLink.so.13`，由 `LD_LIBRARY_PATH` 指向仓库内的 `runtime/lib/`。
唯一允许从系统里解析的是 `libcuda.so.1`（驱动自带，必须匹配内核模块）。

### 1.4 Linux x86_64

实测 Ubuntu 24.04.4，内核 7.0.0-38。其它发行版理论上都行，只要：

- 是 x86_64
- 有 `nvidia-smi`
- 有 `curl`
- 有 `tar` + `zstd`（解 Release 载荷用）

`systemd` 是**可选**的 —— 只有 `./scripts/install-service.sh` 需要它。日常用 `./start.sh` 不需要。

### 1.5 内存 ≥ 16 GB

权重加载时会有短暂的 host 缓冲（实测 `host_to_device_bytes = 8,581,032,448`，约 8 GB）。
内存不足会走 swap，加载时间从 30 秒变成几分钟。

```bash
free -h
```

### 1.6 磁盘 ≥ 15 GB

| 内容 | 体积 |
|---|---|
| 引擎载荷（解包后） | 2.6 GB |
| 引擎 Release 分卷（安装缓存） | 2.06 GiB |
| 模型权重 | 9.5 GB |
| 日志 | 增长，可轮转 |

安装期间需要同时容纳解包后的引擎、Release 分卷缓存和模型；下载完成后可删除 `./.cache/runtime-*.tar.zst.part*` 释放约 2.06 GiB。

`models/` 和 `runtime/` 必须在**同一个文件系统**上才能用硬链接省空间（`fetch-model.sh --from` 会自动尝试）。

### 1.7 Python 3.8+

**只用标准库。** 网页控制台（`webui/server.py`）用的是 `http.server` + `json` + `subprocess`，
一个第三方包都不需要，也不需要 venv 或 pip。

```bash
python3 --version
```

> 这一点是刻意的：很多部署环境根本没有 pip，或者不允许联网装包。
> 本项目所有脚本都是 bash + Python 标准库。

### 1.8 网络（只在安装阶段需要）

| 要下载的东西 | 默认地址 | 备注 |
|---|---|---|
| 引擎载荷 2.6 GB | GitHub Release | 也可用 `--runtime-from` 从本地拷 |
| 模型 9.5 GB | `https://hf-mirror.com` | `huggingface.co` 在国内常常不可达 |

两个下载都**支持断点续传**，中断后重跑同一条命令即可。

装完之后运行阶段**完全离线**，不联网。

---

## 2. 明确不需要

| 不需要 | 为什么 |
|---|---|
| CUDA Toolkit / nvcc | 引擎已经编译好了，运行库随载荷发 |
| pip / venv / 任何 Python 包 | 全部代码是 bash + Python 标准库 |
| Docker / nvidia-container-toolkit | 直接跑二进制 |
| root 权限 | 全部装在本仓库目录内 |
| vcpkg | 依赖已经静态链进二进制 |
| 编译工具链 | 除非你要自己重新编译引擎 |

---

## 3. 逐条检查命令

复制粘贴就能跑：

```bash
echo "== 系统 =="
uname -srm
lsb_release -d 2>/dev/null || cat /etc/os-release | head -2

echo "== 显卡 =="
nvidia-smi --query-gpu=index,uuid,name,memory.total,memory.free,compute_cap \
           --format=csv

echo "== 驱动 =="
nvidia-smi --query-gpu=driver_version --format=csv,noheader

echo "== 内存 =="
free -h

echo "== 磁盘 =="
df -h .

echo "== 工具 =="
for c in curl tar zstd python3 nvidia-smi; do
  printf '%-12s %s\n' "$c" "$(command -v $c || echo '缺失')"
done

echo "== Python 版本 =="
python3 --version
```

如果这里全绿，`./install.sh` 就应该能一路跑通。

---

## 4. 本仓库自带的自检

```bash
./scripts/verify.sh     # 不需要引擎在跑：检查仓库自包含、语法、可执行位、README 命令可解析
./check.sh              # 检查载荷/模型/显卡是否就位
./tests/smoke.sh        # 端到端：起引擎 → 发一个真实请求 → 校验 → 停
```

`scripts/verify.sh` 里有一条纪律检查特别重要：**扫描全仓库，不允许出现仓库外的绝对路径**。
因为别人 clone 下来只拿得到仓库里的东西，任何写死在维护者本机 HOME 下的路径都跑不通。

---

## 5. 如果你要自己重新编译引擎

本仓库**不做这件事**，它只用已经构建好的载荷。想复现整个构建过程（约 100 分钟，
CUDA 13.1 逐组件 sha256 校验，免 root），见 [`METHODOLOGY.md`](METHODOLOGY.md)
与 [`PORTING-LEDGER.md`](PORTING-LEDGER.md) —— 那里面记了完整的工具链获取方式、
编译参数、以及两个会把构建时间从 20 分钟拖到 80 分钟的坑（L13）。
