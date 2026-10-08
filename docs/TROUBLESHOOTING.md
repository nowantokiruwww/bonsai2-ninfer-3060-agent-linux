# 故障排查

按「你会看到什么」组织。每一条都来自实际踩过的坑，病历编号对应
[`PORTING-LEDGER.md`](PORTING-LEDGER.md)。

---

## A. 起不来

### A1 `cudaErrorNoKernelImageForDevice: no kernel image is available for execution on the device`

**含义**：引擎里没有这张卡架构的内核镜像。

**两个成因，先分清是哪个：**

**(a) 卡本身不是 sm_86。** 查：

```bash
nvidia-smi --query-gpu=name,compute_cap --format=csv
```

只有 `8.6` 能用（3060 / 3060 Ti / 3070 / 3070 Ti / 3080 / 3080 Ti / 3090 / 3090 Ti）。
4090 是 8.9，V100 是 7.0，都不行。

**(b) 卡是对的，但引擎挑错了卡。** 这是**多卡机器**上的经典事故，病历 L29。

CUDA 运行时的设备编号**和 `nvidia-smi` 的编号可能是反的**。不锁卡时，引擎可能挑中插在第二槽的那张 V100。

看引擎日志第一行：

```
engine | calibrating routes for nvidia-tesla-v100-sxm2-16gb-sm70 (80 SMs)
```

出现 `v100` 或 `sm70` 就是挑错了。修法：

```bash
# 看 UUID
nvidia-smi --query-gpu=index,uuid,name,compute_cap --format=csv

# 写进 config/runtime.env
GPU_UUID=GPU-<UUID>
```

或者直接让 `launcher.sh` 自己挑：

```bash
grep GPU_UUID config/runtime.env   # 空的话 ./check.sh 会提示
./check.sh
```

`app/env.sh` 的 `apply_gpu_lock()` 会拒绝非 `GPU-` 开头的值 —— 这是刻意的，
`CUDA_VISIBLE_DEVICES=0` 这种按序号的写法在多卡机器上不可靠。

> 为什么历史上会出这个事故：`config/runtime.env` 是 `source` 进来的，
> 但变量没有 `export`，子进程看不到 `CUDA_VISIBLE_DEVICES`，于是 CUDA 按自己的顺序挑了卡。
> 本仓库的 `app/env.sh` 全部用 `export`，并且有 `GPU-` 前缀守卫。

---

### A2 `unknown tensor format: PQ2_0_G128`

**含义**：你用的引擎和模型**不是同一条源码线**出来的工件。

这就是本项目历史上"移植失败"的真正原因（病历 L01）—— 不是 Linux 不兼容，是跨 fork 血缘错配。

背景：同一个三值 2-bit 格式，两个 fork 起了两个名字：

| 名字 | 出现处 | tensor 数 |
|---|---|---|
| `PQ2_0_G128` | Don-Chad/ninfer-3090 v0.6.1 | 322 |
| `t2_g128_fp16` | iamwavecut/ninfer-all | 323 |

模型文件本身没问题（sha256 与 HuggingFace 公布值逐字节一致）。**换对源码线，零改动就能加载。**

对本仓库：你**不应该**遇到这个错。如果遇到了，说明 `runtime/bin/ninfer-serve` 不是本仓库的载荷，
或者模型不是 `Ternary-Bonsai-2-27B-NInfer-v3`。查：

```bash
./scripts/fetch-runtime.sh --check
./scripts/fetch-model.sh --check
```

---

### A3 `libcudadevrt` / `libcudart.so.13: cannot open shared object file`

**含义**：`LD_LIBRARY_PATH` 没包含 `runtime/lib/`。

```bash
./check.sh          # 会打印实际解析到的库路径
ldd runtime/bin/ninfer-serve | grep -i cuda
```

正常情况：`libcudart` / `libcublas` / `libcublasLt` / `libnvJitLink` **全部**解析到
`runtime/lib/` 里。唯一允许来自系统的是 `libcuda.so.1`（驱动自带，必须匹配内核模块）。

本仓库的 `app/env.sh` 会 `export LD_LIBRARY_PATH="$ROOT/runtime/lib:..."`。
如果你手工跑二进制而没走 `launcher.sh`，就会缺这个变量。

---

### A4 端口被占 / `port 8098 is already in use`

```bash
./status.sh         # 先看是不是自己已经在跑
./stop.sh           # 干净地停

# 还有残留就找出来
ss -ltnp | grep 8098
pgrep -af ninfer-serve
```

`stop.sh` 是 SIGTERM + 最多等 20 秒 + SIGKILL。**不要用 `kill -INT`** ——
引擎的 SIGINT 处理器要求 5 秒内按两次 Ctrl+C 才退出，单次 SIGINT 会让它挂在
`WARN  Press Ctrl+C again within 5 s to close`（病历 L24）。

---

## B. 起来了但结果不对

### B1 请求返回 503

**这不是故障，是还没加载完。** 权重 7.99 GiB，从磁盘读大约 25–35 秒。

引擎**在权重加载完成之前就已经监听端口**。所以：

- 端口通了 ≠ 就绪
- `/v1/models` 返回 **503** = 还在 `loading weights`
- 返回 **200** = 真的好了

```bash
./status.sh         # endpoint_http 字段就是答案
tail -f logs/service.log
```

本项目历史上一个探针把 503 当成了成功，导致 20 次请求全部失败而没有任何报错（见
`docs/PARAMETERS.md` §6.2）。`app/launcher.sh` 的 `wait_ready()` 断言的是 **HTTP 200**。

---

### B2 `content` 是空的，但 HTTP 200，`finish_reason: "length"`

**含义**：思考预算把 `max_tokens` 烧光了，模型还在想，正文一个字都没写。

```
思考预算 1024 + max_tokens 900  →  三条全部 length + 空 content
```

**硬约束：思考预算 + 工具调用载荷（约 6,100 token） < `max_tokens`。**

agent 场景建议 `max_tokens ≥ 16384`。

`logs/request.jsonl` 里能看到实情：

```bash
grep request_done logs/request.jsonl | tail -1 | python3 -m json.tool | grep -E 'finish_reason|model_thinking_tokens|completion_tokens'
```

`model_thinking_tokens` ≈ 预算上限、`completion_tokens` 也 ≈ 预算上限，就是这个问题。

---

### B3 输出越来越慢，十分钟后几乎不动

两个独立成因：

**(a) 思考 token 越烧越多。** 思考文本是高熵推文，草稿模型预测不了，投机接受率从 90 %+ 掉到 20–40 %。
实测按思考 token 分桶：

| 思考 token | decode 中位 | 接受率 |
|---|---|---|
| 0 | 91.9 | — |
| 1–99 | 100.6 | — |
| 100–999 | 76.7 | — |
| **≥1000** | **56.5** | **33.8 %** |

修法：降 `--default-thinking-budget`。见 `docs/PARAMETERS.md` §3。

**(b) 上下文变长。** 实测：

| 上下文 token | decode 中位 |
|---|---|
| 0–4,000 | 104.9 |
| 4,000–12,000 | 60.0 |
| 12,000–20,000 | 72.0 |
| 20,000–30,000 | 58.9 |

这是第二层乘数，没有参数能修。要么缩短会话，要么接受。

---

### B4 中文输出特别慢（约 26 tok/s）

**这不是 bug，是这张卡的带宽地板。**

关掉投机解码后中文散文是 26.4 / 26.3 / 26.0 tok/s，
开着 `dflash2 K=7` 是 26.2 / 26.3 / 27.2 —— **逐位相同**。

原因：中文散文的投机接受率只有 **6 %**。`decode ≈ 地板 × (1 + 草稿数 × 接受率)`，
6 % 的接受率下，投机等于没开。

对比（同机同卡）：

| 流量 | 接受率 | decode |
|---|---|---|
| agent + 工具 | 52 % | 88.3 |
| 代码 | 37–40 % | 65–73 |
| 英文散文 | 17 % | 39–43 |
| **中文散文** | **6 %** | **26** |

**换任何服务端参数都没用。** 想提升只有换带宽更大的卡，或换一个能预测中文的草稿表。

（详细数据：`docs/params/REPORT-tune-ab-20261007.md`）

---

### B5 模型卡住，反复调用同一个工具，几十次不停

**这是复读死循环，病历 L26。** 触发条件是两个"安全"设置的组合：

- `--greedy` —— argmax，temperature 0，**没有任何随机逃逸**
- `--no-thinking` —— 关闭思考，**没有自省通道**

两者一起，模型对同一个错误回执的输出**逐字节相同**，永远出不来。

实测现场：改一行 SVG 属性，前 14 次 `edit` 调用的 `old_string` 与 `new_string` 逐字节相同，
工具回 `Error: old_string and new_string must differ`；第 15 次成功后**又连续重复 43 次**。
全程约 18 分钟，客户端注入的重复提醒 **10 次全部被无视**。

**修法：不要用 `--greedy`。** 用采样（`--temperature 1.0 --top-p 0.95 --top-k 20`）。

验证：

```bash
grep -c -- '--greedy' config/runtime.env    # 应该是 0
./status.sh                                  # spec/sampling 字段会显示实际配置
```

本仓库的 `presets.env` 里保留了一个 `greedy` 档，**只为复现这个事故**，界面上是红色警告。

---

## C. 日志相关

### C1 日志在哪

| 文件 | 内容 |
|---|---|
| `logs/service.log` | 引擎的完整输出（启动、权重加载、每个请求的摘要） |
| `logs/request.jsonl` | 每个请求的结构化指标（JSON Lines，schema_version 28） |
| `logs/tune-*.log` | 调参试档时的记录 |

三种看法：

```bash
./logs.sh                      # 跟随 service.log（Ctrl+C 退出）
./logs.sh --requests 20        # 最近 20 条请求指标
./webui.sh                     # 浏览器里看，最方便
```

或者：

```bash
tail -f logs/service.log
tail -f logs/request.jsonl | python3 -m json.tool --json-lines
```

### C2 为什么以前"看不到日志"

`logs/` 一直都在（`service.log` + `request.jsonl` + 轮转档），
但历史上是用 systemd 跑的，stdout 被 systemd 收走写进文件，终端里什么都看不到；
有个脚本会弹 `gnome-terminal` 窗口 tail 日志，但那个窗口容易被浏览器挡在后面，
而且它用 `flock` 防重复弹窗，第二次调用就静默了。

**本仓库默认把日志直接打在终端**（`./start.sh` 前台模式），网页控制台里也有实时跟随。

---

## D. 显存相关

### D1 启动时报显存不足 / `/v1/models` 一直 503，日志停在 `loading weights`

KV cache 要预留一大块。默认 `KV_CAPACITY=49152` + `rk2v4-e8` 约 2.15 GiB。
桌面上开了浏览器 / IDE / 视频，可用显存会掉下来。

```bash
nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv
```

修法：调小 KV 容量（牺牲上下文长度）。

```bash
./stop.sh
./start.sh --ctx 32768
```

各量化的实测上限（**空卡**，RTX 3060 12 GB）：

| KV 量化 | 上限 |
|---|---|
| `int8` / `rk8v4` | 32,768 |
| `rk4v4-e8` | 49,152 |
| `rk2v4-e8` | 76,768 |

**必须实测，不能猜。** 病历 L21：上限随桌面占用浮动，同一张卡昨天能开 76,768，今天可能只到 49,152。

用网页控制台改了 KV 容量之后，记得**重启引擎**才生效。

---

## E. 安装相关

### E1 `nvidia-smi: command not found`

没有 NVIDIA 驱动。装驱动（需要 root），重启后再试。**不需要装 CUDA Toolkit**。

### E2 模型下载中断

```bash
./scripts/fetch-model.sh        # 直接重跑，支持断点续传
```

如果哈希校验失败：

```bash
rm -f models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer
./scripts/fetch-model.sh
```

想用本机已有的模型（省一次 9.5 GB 下载）：

```bash
./install.sh --model-from /path/to/Ternary-Bonsai-2-27B-ninfer-v3.ninfer
```

### E3 载荷下载慢 / 下不动

用本机已有的部署：

```bash
./scripts/fetch-runtime.sh --from /path/to/已有部署
./scripts/fetch-runtime.sh --from /path/to/dist/0.1.0/runtime
```

脚本会先自动在几个常见位置找（本地缓存、同级目录里的旧打包产物），找不到再让你用 `--from` 指定。

---

## F. 自检

三条命令，按顺序：

```bash
./scripts/verify.sh     # 仓库本身是否自包含、语法对不对、README 命令能不能解析
./check.sh              # 载荷 / 模型 / 显卡 / KV 是否就位
./tests/smoke.sh        # 真起一次引擎 + 发一个真实请求 + 校验 + 停掉
```

`tests/smoke.sh` 是最有信息量的一条 —— 它会把整个链路走一遍，
失败时打印的日志片段通常直接指向根因。

若三条都过、速度却不理想，那不是故障，是流量类型的物理限制（见 §B4）。

---

## G. 还有问题？

收集这些信息再排查：

```bash
./status.sh --json > /tmp/status.json
nvidia-smi > /tmp/gpu.txt
tail -200 logs/service.log > /tmp/serve.log
cp logs/request.jsonl /tmp/req.jsonl
```

`./status.sh --json` 里包含 `endpoint_http`、`kv_dtype`、`kv_capacity`、
`sampling`、`spec`、`gpu_uuid`、`gpu_free_mib`，基本一眼能看出配置和运行态是否一致。
