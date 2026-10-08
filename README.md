# bonsai2-ninfer-3060-agent-linux

**在单张 RTX 3060 12 GB 上跑 Ternary-Bonsai-2-27B 的完整、自包含部署仓库。**

不是跑分展示，也不是方法论摘要 —— 这是一个**克隆下来就能跑起来**的仓库：
引擎怎么编译的、每个参数为什么取这个值、踩过哪些坑、走了哪些弯路，全部写在仓库里。

```
./install.sh     # 拉引擎载荷 + 拉模型 + 自检（一次就好，模型 9.5 GB）
./start.sh       # 启动（第一次约 35 秒加载 7.99 GiB 权重）
./webui.sh       # 打开网页控制台：启停 / 实时日志 / 调参 / 每个请求的速度
```

然后把它接进你的 agent：`base_url = http://127.0.0.1:8098/v1`，模型名 `bonsai2-27b`。

> **本仓库已在真机上端到端跑通**（2026-10-08，RTX 3060 12 GB / 驱动 580.178.04）：
> `./scripts/fetch-runtime.sh --auto` → `./scripts/fetch-model.sh --from …` → `./install.sh` →
> `./start.sh`（就绪 32 秒）→ 真实 `/v1/chat/completions` 返回 168 tokens、`finish_reason: stop` →
> `./webui.sh` 的六个 API 端点与 SSE 日志流全部 200 → `./scripts/verify.sh` **全项通过**。
> 上面这段不是"应该能跑"，是跑过了。

---

## 目录

- [它是什么](#它是什么)
- [硬件与系统要求](#硬件与系统要求)
- [五分钟开始](#五分钟开始)
- [网页控制台](#网页控制台)
- [让笔记本用台式机的显卡](#让笔记本用台式机的显卡)
- [命令行怎么用](#命令行怎么用)
- [用 Docker 跑](#用-docker-跑)
- [参数怎么调](#参数怎么调)
- [速度的真相（先读这个）](#速度的真相先读这个)
- [仓库结构](#仓库结构)
- [版本演化：旧版本透明化](#版本演化旧版本透明化)
- [常见问题](#常见问题)
- [文档索引](#文档索引)
- [许可与归属](#许可与归属)

---

## 它是什么

一个把 **Ternary-Bonsai-2-27B**（三值量化 2-bit 权重，27B 参数）跑在**一张 RTX 3060 12 GB** 上的推理服务，
以及围绕它的一整套工程：从 CUDA 工具链、编译、标定、KV 量化门禁，到 agent 体验验收、参数调优和问题病历。

模型在这个组合下的实测表现：

| 项目 | 实测值 |
|---|---|
| 权重体积 | 7.99 GiB（9,520,051,456 B 的 `.ninfer` v3 工件） |
| KV 量化 | `rk2v4-e8` |
| 上下文上限（空卡） | 76,768 token |
| 上下文默认 | 49,152 token（桌面占用下稳妥值） |
| 投机解码 | `dflash2`，草稿窗口 7 |
| 纯解码吞吐（agent + 工具调用流量） | 中位 **202 tok/s**，投机接受率中位 **86 %** |
| 长上下文稳定性 | 到 **46,290 token** 无断崖 |
| 显存占用 | 稳态 11,032 MiB / 12,288 MiB |

> 吞吐数字必须连带**流量类型**一起看。中文散文只有 6 % 的投机接受率，实际约 26 tok/s；
> 见 [速度的真相](#速度的真相先读这个)。

---

## 硬件与系统要求

**必须有：一张 compute capability 8.6 的 NVIDIA 显卡。**

引擎只编译了 `sm_86` 内核（没有 PTX 回退到别的架构）。在别的卡上会直接报：

```
cudaErrorNoKernelImageForDevice: no kernel image is available for execution on the device
```

| 项目 | 要求 | 本项目实测环境 |
|---|---|---|
| GPU | **sm_86**：RTX 3060 / 3060 Ti / 3070 / 3080 / 3090 | RTX 3060 12 GB，28 SM |
| 显存 | ≥ 12 GB（含桌面占用） | 12,288 MiB |
| 驱动 | ≥ 570（本项目用 580.178.04） | 580.178.04 |
| 系统 | Linux x86_64（systemd 可选） | Ubuntu 24.04.4 |
| 内核 | 任意较新的 | 7.0.0-38 |
| 内存 | ≥ 16 GB 建议 | 23 GiB + 8 GiB swap |
| 磁盘 | ≥ 13 GB（载荷 2.6 GB + 模型 9.5 GB） | — |
| Python | 3.8+（**只用标准库，不需要 pip**） | 3.12.3 |

**不需要**：CUDA Toolkit、nvidia-container-toolkit、Docker、pip、任何 Python 第三方包。
CUDA 运行库（cuBLAS / nvJitLink / cudart）随引擎载荷一起发，由 `LD_LIBRARY_PATH` 指向仓库内的 `runtime/lib/`。

细节与逐条检查命令见 [`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md)。

---

## 五分钟开始

```bash
git clone https://github.com/nowantokiruwww/bonsai2-ninfer-3060-agent-linux.git
cd bonsai2-ninfer-3060-agent-linux

./install.sh          # ① 引擎载荷（2.6 GB，分 2 卷）② 模型（9.5 GB，HF 镜像）③ 自检
./start.sh            # 启动，约 35 秒
./webui.sh            # 浏览器打开 http://127.0.0.1:8099
```

国内网络下载模型慢或者 HF 不可达是常态，`config/release.env` 里默认用的是 `hf-mirror.com`。
模型下载**支持断点续传**：中断了直接重跑 `./scripts/fetch-model.sh` 就行。

已经在本机有引擎和模型的话，跳过下载：

```bash
./install.sh --runtime-from /path/to/runtime \
             --model-from   /path/to/Ternary-Bonsai-2-27B-ninfer-v3.ninfer
```

### 仓库里为什么不含引擎和模型

| 东西 | 体积 | 放在哪 |
|---|---|---|
| 引擎载荷（3 个二进制 + 4 个 CUDA 运行库 + 标定 profile） | 2.6 GB | GitHub **Release 附件**，切成 2 卷，`fetch-runtime.sh` 取回 |
| 模型权重 `.ninfer` | 9.5 GB | HuggingFace 镜像，`fetch-model.sh` 取回 |
| 源码 / 脚本 / 文档 | 5 MB | **就在仓库里** |

两个不同的平台限制，别搞混：

- **git 仓库**单文件上限 **100 MB** → 2.6 GB 和 9.5 GB 都进不了 git，这是为什么它们要外挂。
- **Release 附件**单文件上限 **2 GiB**（[官方文档](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)：*"must be under 2 GiB"*）
  → 载荷压缩后是 **2.06 GiB，正好超**，所以被切成 `…tar.zst.part1` / `…part2` 两卷。

分卷是纯粹的托管绕开手段，**没有删掉任何东西**。下载端会拼回整包再校验整包的 sha256，
单卷坏了只需重下那一卷（重跑 `./scripts/fetch-runtime.sh` 会跳过已下好的卷）。

**但仓库是自包含的**：所有脚本、所有路径都相对仓库根解析，不存在"只有作者本机才有"的依赖。
`./scripts/verify.sh` 会把这件事当成断言来检查。

<details>
<summary><b>维护者：重新打一个 Release（普通用户不用看）</b></summary>

改过 `runtime/` 里的东西（比如换了引擎构建）之后，才需要重发载荷：

```bash
./scripts/make-release.sh                    # 压缩 + 切卷 → dist/
export GITHUB_TOKEN=ghp_xxxxxxxx             # classic PAT，勾 repo 这一个 scope 就够
./scripts/publish-release.sh                 # 建 Release（若不存在）+ 传附件
```

`publish-release.sh` 会自己判断哪些附件已经传过并跳过，**传断了直接重跑就续传**。
它还会硬拦超过 2 GiB 的单文件——真超了就调大 `config/release.env` 里的
`RUNTIME_ASSET_PARTS` 再重跑 `make-release.sh`。

> **代理提醒**：能打开 GitHub 网页 ≠ `curl`/`git` 能通。浏览器读 GNOME 的代理设置，
> 命令行工具不读。要设 `export https_proxy=http://127.0.0.1:7890`（换成你自己的端口）。
> `git` 那边可以用 `git config --global http.https://github.com/.proxy http://127.0.0.1:7890`
> —— 只对 github.com 生效，不影响别的仓库。

</details>

---

## 网页控制台

```bash
./webui.sh                # 默认 127.0.0.1:8099
./webui.sh --port 9000
./webui.sh --lan          # 也让局域网里的笔记本打开（无鉴权，慎用）
```

纯 Python 标准库实现，无第三方依赖，默认只监听本机回环地址。界面上有五块：

- **状态栏** —— 运行状态、pid、运行时长、**完整 API 地址**（带一键复制）、KV 量化与容量、思考开关与预算、投机后端、显卡与空闲显存。
- **控制区** —— 预设档位下拉（`balanced` / `fast` / `think` / `deep` / `greedy`），可覆盖 KV 容量、KV 量化、投机参数、端口、**局域网开关**和任意追加参数；「启动 / 停止 / 重启 / 保存到 config」四个按钮。启动是异步的，输出实时回流到界面。
- **日志区** —— `logs/service.log` 的实时流（SSE），带关键字高亮、自动滚动、暂停、下载。
- **请求指标** —— 每个请求的 decode tok/s、投机接受率、思考 token 数、TTFT、`finish_reason`，5 秒刷新一次。
- **接入方式** —— 本机 / 局域网的全部 API 地址，以及可以直接复制走的 curl、Python（openai 库）、Python（requests 库）和环境变量片段。

再加一块折叠的**参数速查**，把「为什么中文散文到不了 120 tok/s」这类结论直接写进界面 ——
免得再走一遍弯路。

---

## 让笔记本用台式机的显卡

台式机插着 3060 出算力，笔记本连着它写代码 —— 这是这台机器最常见的用法。

**台式机（服务端）：**

```bash
./start.sh --lan          # 引擎绑 0.0.0.0，并且打印出该用哪个地址
./webui.sh --lan          # 控制台也一起对局域网开放（可选）
```

`./start.sh --lan` 会多打出一段：

```
  API      http://127.0.0.1:8098/v1
  API      http://192.168.1.23:8098/v1      ← 笔记本用这个
```

> ⚠ `192.168.1.23` 只是**示例**。你跑的时候这里打印的是**你自己台式机的局域网 IP**，
> 每台机器都不一样（`192.168.x.x` / `10.x.x.x` / `172.16-31.x.x` 这些是内网地址段）。
> 网页控制台里也能直接看到完整地址并一键复制，不用自己猜。
>
> **这不会把你的电脑暴露到公网。** `--lan` 做的是让引擎绑本机的所有网卡，
> 效果是"同一个路由器/交换机下面的设备能连" —— 笔记本、手机、同一 WiFi 上的人。
> 公网上的机器**连不上** `192.168.x.x`（这类地址不可路由，运营商的骨干网直接丢弃）。
> 唯一会变成公网可访问的情况是你在**路由器上做了端口转发 / 开了 UPnP** 把 8098 映射出去，
> 那是路由器侧的设置，本项目不做也不会替你做。
>
> 真正要警惕的是**同一个网吧/宿舍/办公室的 WiFi**：那里的人算"同一局域网"。
> 而且 `--lan` **只管这一次启动**，不会写进 `config/runtime.env`（和其他
> `./start.sh --xxx` 覆盖一样）。想让它长期生效，用网页控制台里的「局域网」开关 +
> 「保存到 config」，或者直接改 `config/runtime.env` 里的 `HOST`。默认值是安全的
> `127.0.0.1`（只有本机能连）—— 也就是说**重启之后会自动关回去**，这是故意的。

**笔记本（客户端）：**

```bash
# 把下面的地址换成台式机 ./start.sh --lan 打印出来的那一条
export OPENAI_BASE_URL=http://192.168.1.23:8098/v1
export OPENAI_API_KEY=not-needed      # 引擎不校验 key，随便填
```

**⚠ 引擎没有任何鉴权，也没有 TLS** —— 这是上游引擎的设计，本项目没有在外面加壳。
开了 `--lan` 就等于**把这张显卡借给整个局域网**：谁能连上谁就能用，网页控制台
的日志和 `logs/request.jsonl` 里的请求内容也一样看得见。只在家里 / 自己信得过的
网络里这么用。收回来：

```bash
./restart.sh --local      # 绑回 127.0.0.1
```

防火墙（如果用 ufw）—— `192.168.1.0/24` 换成你自己的网段：

```bash
sudo ufw allow from 192.168.1.0/24 to any port 8098 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 8099 proto tcp
```

**一个实测出来的坑**：引擎**不发 CORS 头**（`OPTIONS` 预检直接返回 404）。
所以笔记本这边要用 **桌面客户端** —— curl、Python、各种本地客户端都行；
**浏览器里打开的第三方网页直接 `fetch` 这个地址会被浏览器拦下来**，
报的是看不懂的 CORS 错误。这不是配置问题，引擎没实现。

Docker 下是同一套东西，`./docker/run.sh --lan` 会自动把宿主机的局域网地址
探出来传给容器（容器自己只看得见 `172.17.x.x` 的桥接地址，报出来没用）。
细节见 [docs/DOCKER.md](docs/DOCKER.md#让局域网里的别的机器连过来)。

---

## 命令行怎么用

不想开网页的话，顶层都是薄封装，直接跑：

```bash
./start.sh                          # 后台起 + 等就绪
./start.sh --preset fast            # 换预设档
./start.sh --ctx 76768              # 覆盖上下文（= KV 容量）
./start.sh --lan                    # 绑 0.0.0.0，让局域网连过来（⚠ 无鉴权）
./restart.sh --local                # 绑回 127.0.0.1
./status.sh                         # 看状态（含全部可访问地址）
./status.sh --json                  # 机器可读
./logs.sh -f                        # 跟日志
./stop.sh                           # 停止（SIGTERM，约 5 秒）
./restart.sh --preset balanced      # 重启
./presets.sh                        # 列出所有预设档
./check.sh                          # 只做前置检查，不启动
```

想看拼出来的完整引擎命令：

```bash
./app/launcher.sh cmd --preset balanced
```

接进你的客户端：

```bash
curl http://127.0.0.1:8098/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"bonsai2-27b","messages":[{"role":"user","content":"你好"}],"max_tokens":2048}'
```

### 开机自启（可选）

```bash
./scripts/install-service.sh                 # 装 systemd 用户服务并启动
./scripts/install-service.sh --no-start      # 只装不启动
./scripts/install-service.sh --remove        # 卸载
systemctl --user enable bonsai2-ninfer-3060-agent-linux   # 开机自启
sudo loginctl enable-linger $USER            # 不登录也保持运行
```

unit 里的路径是**安装时烘焙**的本仓库绝对路径，所以仓库挪了位置要重跑一次。

> unit 用的是 `KillSignal=SIGTERM`，不是默认的 `SIGINT`。
> 引擎的 `SIGINT` 处理要求「5 秒内按两次 Ctrl+C」，用 `SIGINT` 会导致每次停止都干等 60 秒超时再被 `SIGKILL`。

---

## 用 Docker 跑

```bash
./scripts/fetch-runtime.sh --auto                    # 先让仓库有引擎
./docker/build.sh --base docker.m.daocloud.io/library/ubuntu:24.04
./docker/run.sh                                      # 前台跑起来
./docker/run.sh --lan -d                             # 或者：让笔记本连过来
```

实测镜像 **5.45 GB**（`--with-model` 的胖镜像 **22.7 GB**）。

打开 <http://127.0.0.1:8099/> 就是同一个网页控制台。
模型从宿主机 `models/` 挂进去（只读），日志写到宿主机 `logs/`，**容器删掉日志还在**。

镜像里**有**引擎载荷（727 MB 二进制 + 4 个 CUDA 运行库 + 标定文件）和
131 个系统依赖库；**没有**驱动、没有 9.5 GB 权重、没有编译器 ——
镜像是运行镜像，不在容器里编译。

没装 `nvidia-container-toolkit` 也能跑：`docker/run.sh` 会自动退回到
「手工挂 `/dev/nvidia*` + 挂宿主机驱动库」的方案，并在启动时告诉你走了哪条路。
两条路都**按 UUID 锁卡**，绝不按序号。

`./docker/run.sh --lan` 会和裸机的 `./start.sh --lan` 一样把端口开给局域网，
区别是它会**把宿主机的真实局域网地址探出来传给容器** —— 容器自己只看得见
`172.17.x.x` 的桥接地址，报出来对笔记本没用。

细节（依赖闭包怎么算出来的、为什么引擎故意不做 PID 1、compose、排错）见
[`docs/DOCKER.md`](docs/DOCKER.md)。

---

## 参数怎么调

配置文件只有一个：**`config/runtime.env`**。也可以用 `./webui.sh` 或 `--persist` 改，不用手编。

### 两个真正有用的维度

**① 上下文 ↔ 显存余量**

KV 容量必须**实测**，不能猜。同一张卡上能开多大完全取决于当时桌面占了多少显存：

| KV 量化 | 空闲 11.3 GB 时上限 |
|---|---|
| `int8` / `rk8v4` | 32,768 |
| `rk4v4-e8` | 49,152 |
| **`rk2v4-e8`** | **76,768（阶梯顶端，实测值）** |

默认取 **49,152** 而不是 76,768 —— 因为上限是浮动的，桌面上开个浏览器就可能把它顶下去（病历 L21）。

**② 思考预算 ↔ 速度**

这是唯一能大幅改变**墙钟时间**的旋钮：

| 预算 | 同一任务墙钟（中位） | 说明 |
|---|---|---|
| 512 | 40.9 s | 最快，但实测单轮重复率最高（40 %） |
| **1024** | **44.2 s** | **生产默认**：速度 / 产出 / 稳健性三项都不吃亏 |
| 4096 | 67.8 s | 每个请求都会烧满 4096 个思考 token |

关键认知：**降预算不是"提速"，是"削尾巴"**。`decode tok/s` 几乎不随预算变化（58–83 全域），
变的是有多少 token 被烧在思考里。而且放开预算**并没有换来更好的产出** ——
4096 档三次里两次只发了个 48 字符的 `bash` 敷衍了事。

### 预设档

| 档位 | 思考 | 采样 | 适合 |
|---|---|---|---|
| `balanced` | 开，预算 1024，effort medium | V100 采样 | **默认**，生产档 |
| `fast` | 关 | V100 采样 | 代码/工具调用流量（65–88 tok/s）；中文散文反而更慢（26 vs 39） |
| `think` | 开，预算 4096 | V100 采样 | 需要长推理时 |
| `deep` | 开，预算 8192，effort high | V100 采样 | 最难的任务，慢 |
| `greedy` | 开，预算 1024 | `--greedy` | ⚠ **危险，见下** |

### ⚠ 两个会导致死循环 / 静默失败的组合

**1. `--greedy` + `--no-thinking` = 复读死循环。**

argmax 采样没有任何随机逃逸路径，关掉思考又堵死了唯一的自省通道，
模型会**逐字节重复同一次工具调用**。本项目实测过一次真实事故：

```
Error: old_string and new_string must differ     ← 连续 14 次，两个参数逐字节相同
（第 15 次碰巧成功之后，又连续重复了 43 次同一个调用）
```

全程 18 分钟，harness 注入的重复提醒被无视 10 次，从未自愈。
**生产配置绝对不要同时用这两个 flag**（病历 L26）。

**2. 思考预算 ≥ `max_tokens` = 正文为空，而且不报错。**

预算 1024 配 `max_tokens: 900`，模型会把 900 个配额全烧在思考里，
返回 `finish_reason: "length"` 和**空字符串的 `content`**，HTTP 200，一声不吭。

**硬约束：思考预算 + 工具调用载荷（约 6,100 token） < `max_tokens`。**

完整推导、六臂矩阵和复现命令见 [`docs/PARAMETERS.md`](docs/PARAMETERS.md)
与 [`docs/params/REPORT-param-audit-20261007.md`](docs/params/REPORT-param-audit-20261007.md)。

---

## 速度的真相（先读这个）

**单流 decode 的地板大约 26 tok/s。这是显存带宽，不是配置问题。**

7.99 GiB 权重每生成一个 token 就要完整读一遍，RTX 3060 的带宽约 300 GB/s，
算下来就是每秒二十几个 token。实测佐证：把投机解码**完全关掉**，中文散文是 26.4 / 26.3 / 26.0 tok/s；
开着 `dflash2 K=7` 是 26.2 / 26.3 / 27.2 tok/s —— **逐位相同**。

所以那些 120+、200 的数字是哪来的？**全部来自投机解码被接受。**

```
decode ≈ 地板(≈26) × (1 + 草稿数 × 接受率)
```

| 流量类型 | 投机接受率 | 实测 decode |
|---|---|---|
| agent + 工具调用 | 52 % | 88.3 tok/s |
| 代码 | 37–40 % | 65–73 tok/s |
| 英文散文 | 17 % | 39–43 tok/s |
| 中文散文 | **6 %** | **26 tok/s** |
| 旧的 `--no-thinking` 部署（agent 流量） | 95 % | ~200 tok/s |

**结论：中文散文在这张卡上到不了 120 tok/s，换任何服务端参数都没用。**
带宽地板 + 草稿模型预测不了中文散文，这两个原因服务端参数都治不了。

想真正提升，只有两条路：**换带宽更大的卡**，或者**换一个能预测中文的草稿表**。

> 这也是本项目把 `--no-thinking` 从生产配置里拿掉的代价：
> 老配置在 agent 流量上接受率 95 %、约 200 tok/s，但会复读死循环（L26）；
> 现在用采样 + 思考预算收口，接受率降到 45–52 %，约 80–88 tok/s，换来的是不再卡死。
> **这个取舍是刻意的。**

---

## 仓库结构

```
bonsai2-ninfer-3060-agent-linux/
├── install.sh                  一键安装（载荷 + 模型 + 自检）
├── start.sh stop.sh restart.sh status.sh logs.sh presets.sh check.sh
├── webui.sh                    网页控制台入口
│
├── app/                        引擎生命周期（纯 bash，无依赖）
│   ├── env.sh                  路径解析 / 显卡自动探测与 UUID 锁卡 / 默认值
│   ├── presets.env             五个预设档 + 采样与思考 flag 的组装规则
│   └── launcher.sh             启停 / 状态 / 参数拼装（唯一实现）
│
├── webui/
│   ├── server.py               后端（纯标准库 HTTP + SSE）
│   └── static/                 前端（原生 JS，无框架无 CDN）
│
├── scripts/
│   ├── lib.sh                  日志 / 下载 / 校验助手
│   ├── fetch-runtime.sh        取引擎载荷（Release / 本地目录 / URL）
│   ├── fetch-model.sh          取模型（HF 镜像，断点续传 + sha256）
│   ├── install-service.sh      systemd 用户服务
│   ├── verify.sh               自检：证明仓库自包含
│   ├── make-release.sh         打 Release 附件（压缩 + 分卷）
│   └── publish-release.sh      把附件传到 GitHub Release（要 GITHUB_TOKEN）
│
├── config/
│   ├── runtime.env             运行配置（唯一调参入口，install 时生成）
│   └── release.env             下载地址（默认已指向本仓库 Release，一般不用改）
│
├── docker/
│   ├── Dockerfile              运行镜像（131 个系统依赖的精确闭包）
│   ├── entrypoint.sh           容器选卡 / 生成配置 / 起进程并收尾
│   ├── run.sh                  宿主机侧启动器（自动在 --gpus 与手工挂载间选路）
│   ├── build.sh                构建（--base / --with-model）
│   └── compose.yml             等价的 compose 写法
│
├── docs/
│   ├── REQUIREMENTS.md         环境依赖逐条说明
│   ├── PARAMETERS.md           参数调优指南
│   ├── TROUBLESHOOTING.md      常见问题
│   ├── DOCKER.md               容器：依赖怎么算的、为什么引擎不做 PID 1
│   ├── PORTING-LEDGER.md       ★ 31 条移植病历（最有价值的一份）
│   ├── AGENT-EXPERIENCE.md     agent 场景验收（A1–A8）
│   ├── LINEAGE.md              上游血缘：哪个 fork、哪个 commit、为什么
│   ├── METHODOLOGY.md          方法论：怎么保证结论可信
│   └── params/                 两份参数实测报告（原始数据与结论）
│
├── runtime/                    ← 安装后出现：引擎载荷（bin/ lib/ agent/ profiles/）
├── models/                     ← 安装后出现：模型权重
└── logs/                       service.log / request.jsonl
```

**`runtime/` 和 `models/` 一开始是空的**，`install.sh` 会把它们填上。

---

## 版本演化：旧版本透明化

这套参数不是一次定下来的。之前踩过的每个坑都留在病历里，参数也改过好几轮。
下面把**旧版本**也列出来 —— 这样你看到旧配置时不会以为是笔误，也知道为什么不能退回去。

| 时间 | 旧版本 | 现在 | 为什么改 | 病历 |
|---|---|---|---|---|
| 10-07 13:21 | `--no-thinking --greedy` | 采样（`t=1.0 / p=0.95 / k=20`） | argmax + 无思考通道 = 复读死循环，实测连续 43 次重复同一调用 | L26 |
| 10-07 14:54 | 思考不限量 / 预算 4096 | 预算 1024 | 不限量时模型把 `max_tokens` 全烧在思考里、零工具调用；4096 每个请求烧满 4096 token | L27 / L28 |
| 10-07 20:0x | KV 容量 76,768 | 49,152 | 76,768 只在空卡成立，桌面一占显存就失败 | L21 |
| 10-07 20:0x | 三处脚本兜底值 4096 | 1024 | 兜底值和实际配置不一致，会静默改变行为 | L28 / L30 |

还有一处**行为**层面的旧版本：`package/entrypoint.sh`（Docker 路径）早期不检查
`CUDA_VISIBLE_DEVICES` 是不是 UUID 开头。CUDA 的设备序和 `nvidia-smi` **相反**，
不锁 UUID 会挑到机器上另一张卡 —— 本项目实测挑中了 V100（sm_70），当场报
`cudaErrorNoKernelImageForDevice`（L29）。现在非 `GPU-` 开头直接拒绝启动。

**所有旧版本文件都按时间戳存档，一个都没删。**

---

## 常见问题

**Q：`/v1/models` 返回 503，是不是坏了？**

不是。引擎在**权重加载完成之前就已经监听端口**，这期间 `/v1/models` 回 503。
第一次启动要 30–40 秒。**判就绪必须看 HTTP 200，不能只看端口通** ——
本项目踩过这个坑，探针把 503 当成就绪，结果 20 次请求全部连接失败。

**Q：报 `cudaErrorNoKernelImageForDevice`。**

说明挑到了非 sm_86 的卡。检查 `config/runtime.env` 里的 `GPU_UUID`，
或者用 `./app/launcher.sh cmd` 看拼出来的命令。CUDA 运行时设备序和 `nvidia-smi` 相反，
所以**必须按 UUID 锁卡**，不能按序号。

**Q：中文输出很慢，只有二十几 tok/s。**

这是显存带宽地板，不是故障。见 [速度的真相](#速度的真相先读这个)。

**Q：模型输出一直在思考，最后什么都没输出。**

`max_tokens` 不够。思考预算 + 工具调用载荷（约 6,100 token）必须**显著小于** `max_tokens`。

**Q：`./stop.sh` 很慢 / 卡住。**

不该慢。`./stop.sh` 用 `SIGTERM`，正常 5 秒内退出。
如果你自己用 `SIGINT`（`kill -INT`）停，引擎会要求 5 秒内按两次，否则要等 60 秒超时。

更多见 [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)。

---

## 文档索引

| 文档 | 内容 |
|---|---|
| [`docs/PORTING-LEDGER.md`](docs/PORTING-LEDGER.md) | **31 条移植病历** —— 每一条都是真实踩过的坑：现象、根因、解法、证据、通用教训 |
| [`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md) | 环境依赖逐条说明与检查命令 |
| [`docs/PARAMETERS.md`](docs/PARAMETERS.md) | 参数调优：两个维度、预设档、实测矩阵 |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | 常见问题与排查顺序 |
| [`docs/DOCKER.md`](docs/DOCKER.md) | 容器运行：依赖闭包怎么算、显卡怎么进容器、为什么引擎不做 PID 1、compose |
| [`docs/AGENT-EXPERIENCE.md`](docs/AGENT-EXPERIENCE.md) | agent 场景验收 A1–A8（工具调用、长上下文、稳定性、复读门禁） |
| [`docs/LINEAGE.md`](docs/LINEAGE.md) | 上游血缘：`Neroued/ninfer` → … → `iamwavecut/ninfer-all`，以及为什么必须换源码线 |
| [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md) | 方法论：去黑盒化、可重放、三道门禁 |
| [`docs/params/REPORT-param-audit-20261007.md`](docs/params/REPORT-param-audit-20261007.md) | 参数审计：六臂矩阵、探针、503 陷阱 |
| [`docs/params/REPORT-tune-ab-20261007.md`](docs/params/REPORT-tune-ab-20261007.md) | 三臂 A/B：带宽地板的推算过程 |

---

## 许可与归属

本仓库以 **Apache License 2.0** 发布，见 [`LICENSE`](LICENSE)。

`NOTICE` 里列出了三处第三方归属：引擎上游、模型、以及一个只作方法论参照的仓库。
**本仓库零源码改动** —— 引擎是上游 commit 直接编译的，没有 patch。

模型权重有它自己的许可证，使用前请看模型主页。

---

## 关于这个项目

最初的动机很简单：在 Windows 上跑通过的一套东西，搬到 Linux 之后
「测试的数据和实际使用出现了隔断，有很多离谱的暗病」。

于是推倒重来：从编译 ninfer 起步，不依赖本机任何已有安装；
每个输入都记 sha256、每处源码改动都做成可重放的 patch、每个结论都要能复现。
最后查出来的根因不是 Linux 不兼容，而是**跨 fork 的血缘错配** ——
两个 fork 给同一个三值 2-bit 格式起了不同的名字，
旧的那套用错了源码线，于是 `unknown tensor format: PQ2_0_G128`。

这条已经写进 [`docs/PORTING-LEDGER.md`](docs/PORTING-LEDGER.md) 的 L01。
剩下 29 条，也都在里面。
