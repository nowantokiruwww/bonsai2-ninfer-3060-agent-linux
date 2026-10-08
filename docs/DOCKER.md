# 容器里跑

这个仓库能打成 Docker 镜像跑。但先说清楚**这个镜像装了什么、不装什么**，
因为这决定了你该怎么用它。

| 东西 | 在镜像里吗 | 为什么 |
|---|---|---|
| 引擎二进制 `ninfer-serve`（727 MB） | ✅ 在 | 这是本项目最核心的产物 |
| 引擎自带的 4 个 CUDA 运行库 | ✅ 在 | `cublas` / `cublasLt` / `cudart` / `nvJitLink` |
| 标定文件 `device-profiles.json` | ✅ 在 | 没有它引擎拒绝启动 |
| 131 个系统依赖库 | ✅ 在 | 从 `ldd` 反查出来的精确闭包，见下文 |
| 9.5 GB 模型权重 | ❌ 不在 | 挂载进去；或 `--with-model` 自己烤一个胖的 |
| NVIDIA 驱动 | ❌ 不在 | 驱动在内核里，容器不可能自带 |
| 编译器 / CUDA Toolkit | ❌ 不在 | 镜像是**运行**镜像，不在容器里编译 |

最后一条值得展开：本项目的引擎是在真机上从零编译、逐项验证过之后才打包的。
镜像里的那个二进制就是那个**已验证的产物**，不是现场编的。
所以镜像很小（相对而言，实测 **5.45 GB**），也没有 nvcc / gcc / cmake / vcpkg。

---

## 快速开始

```bash
# 1. 先让仓库有引擎载荷（如果还没做）
./scripts/fetch-runtime.sh --auto

# 2. 构建镜像
./docker/build.sh --base docker.m.daocloud.io/library/ubuntu:24.04

# 3. 跑
./docker/run.sh
```

跑起来之后打开 <http://127.0.0.1:8099/>，就是网页控制台，
和裸机跑 `./webui.sh` 得到的是同一个界面：启停、参数、日志、请求指标都在上面。

模型从宿主机的 `models/` 目录挂进去（只读），日志写到宿主机的 `logs/` 目录，
所以**容器删掉日志也还在**。

常用命令：

```bash
./docker/run.sh -d          # 后台跑
./docker/run.sh --lan -d    # 后台跑，并且允许局域网访问（见下一节）
./docker/run.sh logs        # 看容器日志
./docker/run.sh status      # 容器状态 + 两个端口探活
./docker/run.sh shell       # 进容器 bash（显卡已挂好，可以 ./start.sh 试）
./docker/run.sh stop        # 停
```

---

## 让局域网里的别的机器连过来

最常见的用法：**台式机插着 3060 出算力，笔记本连着它写代码**。
台式机跑这个容器，笔记本把这台机器当成一个 OpenAI 兼容的 API 用。

```bash
./docker/run.sh --lan -d
```

它会做三件事：

1. 端口映射从 `127.0.0.1:8098:8098` 变成 `8098:8098`（两个端口都开）。
2. 在宿主机上算出默认路由那张网卡的地址，通过 `BONSAI_ADVERTISE_IP` 传给容器。
3. 把 `BONSAI_LAN_EXPOSED=1` 传进容器，这样控制台才知道自己真的对外开着。

跑完终端会直接打出该用哪个地址：

```
[run] 对外地址 http://192.168.1.23:8098/v1
```

> ⚠ `192.168.1.23` 只是**示例**。你跑的时候打印的是**你自己机器的局域网 IP**，
> 每台机器都不一样。这个地址是 `docker/run.sh` 在宿主机上算出来、通过
> `BONSAI_ADVERTISE_IP` 传给容器的 —— 不是写死的。
>
> **注意它只是内网地址**：`--lan` 让端口开到本机所有网卡上，效果是"同一路由器
> 下面的设备能连"。公网**连不上** `192.168.x.x`（不可路由）。会变成公网可访问
> 只有一种情况：你在路由器上做了端口转发 / 开了 UPnP。本项目不做这个。

打开网页控制台（`http://127.0.0.1:8099/`），顶部会显示**完整的 API 地址**，
「接入方式」面板里有四条可以直接复制走的代码片段（curl / Python openai /
Python requests / 环境变量），而且因为是对外开放状态，面板会自动展开并顶上
一条橙色警告。

在笔记本那边，只要在一个网段里，把地址填进客户端就行：

```bash
# 换成上面打印出来的那一条
export OPENAI_BASE_URL=http://192.168.1.23:8098/v1
export OPENAI_API_KEY=not-needed      # 引擎不校验 key，随便填
```

### ⚠ 这是没有鉴权的

引擎（和网页控制台）**都没有任何认证，也没有 TLS** —— 这是上游引擎的设计，
本项目没有在外面加壳。所以：

* 同网段里的**任何人**都能白用你的显卡，也能跟模型对话；
* 网页控制台的启停按钮、日志、`logs/request.jsonl` 里的请求内容也都对同网段可见；
* **只在你信得过的网络里这么用**（家里 / 自己拉的网线）。咖啡馆、公司访客
  WiFi 这类环境不要开。

收回来：

```bash
./docker/run.sh --local -d
```

（`--local` 会把端口映射恢复成只绑回环，并告诉容器 `BONSAI_LAN_EXPOSED=0`，
控制台里的警告随之消失。）

### 为什么需要那两个环境变量

容器里的引擎**必须**绑 `0.0.0.0`，否则 docker 的 `-p` 根本转发不进来；
但宿主机到底把端口开给谁，容器是看不见的（它只看得到自己那个网络命名空间，
地址是 `172.17.x.x` 的桥接地址，报出来对笔记本毫无用处）。所以：

| 变量 | 作用 |
|---|---|
| `BONSAI_LAN_EXPOSED` | `1`/`0`，直接告诉容器「你到底有没有对外开」，覆盖按 bind 地址猜的那套 |
| `BONSAI_ADVERTISE_IP` | 对外该报哪个 IP。不设的话容器会报自己的桥接地址 |

`./docker/run.sh` 帮你把两个都填好。手写 `docker run` 或走 compose 的时候要自己填
（`ADVERTISE_IP=... ./docker/run.sh --lan` 可以覆盖自动探测的结果）。

### 防火墙

如果宿主机开着 ufw，光开 `--lan` 还不够，得放行（`192.168.1.0/24` 换成你自己的网段）：

```bash
sudo ufw allow from 192.168.1.0/24 to any port 8098 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 8099 proto tcp
```

（把网段换成你自己的。`sudo ufw status` 看当前规则。）

### 客户端要用桌面客户端，不能用浏览器

引擎**不发 CORS 头**（实测 `OPTIONS` 预检返回 `404`）。所以笔记本那边得用
curl、Python、各种本地客户端这类**桌面客户端**；**浏览器里打开的第三方网页
直接 `fetch` 会被浏览器拦下来**，报的是看不懂的 CORS 错误。这不是配置问题，
引擎没实现这个能力。

### compose 里怎么开

`docker/compose.yml` 里把 `ports:` 两行前面的 `"127.0.0.1:"` 去掉，
再把 `BONSAI_LAN_EXPOSED` 改成 `"1"`、按需填 `BONSAI_ADVERTISE_IP`，注释里都写清楚了。

---

## 显卡怎么进容器

两条路，`docker/run.sh` 会自动选。

### 路线 A：装了 nvidia-container-toolkit（推荐）

脚本检测到 docker 的 runtime 列表里有 `nvidia`，就用 `--gpus all`。
这是官方路线，最省心。装法见
[NVIDIA Container Toolkit 安装指南](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)。

### 路线 B：没装 toolkit（本机就是这条）

脚本手工挂：

- 设备节点：`/dev/nvidiactl`、`/dev/nvidia-uvm`、`/dev/nvidia-uvm-tools`、
  `/dev/nvidia-modeset`、`/dev/nvidia0`…
- 驱动用户态库：`libcuda.so.580.178.04`、`libnvidia-ptxjitcompiler.so.580.178.04`、
  `libnvidia-nvvm.so.580.178.04`、`libnvidia-ml.so.580.178.04`
  —— 按实际版本号挂到容器里约定俗成的名字（`libcuda.so.1` 等）
- `/usr/bin/nvidia-smi`（可选，方便人看）

**驱动的用户态库必须来自宿主机**，因为它的版本要和宿主内核里的
`nvidia.ko` 严格一致。这也是为什么 Dockerfile 里刻意**不装**
`libnvidia-compute-580`。

官方 CUDA 镜像在没 toolkit 的时候走的也是这套办法，所以这不是野路子。

---

## 绝不按序号选卡

```bash
# 本机实测：
nvidia-smi -L                              # 0: RTX 3060   1: V100
CUDA_VISIBLE_DEVICES=0 ...                 # ← 引擎拿到的是 V100！
```

CUDA 运行时看到的设备顺序和 `nvidia-smi` 是**反的**。所以本项目的所有入口
（裸机 `app/env.sh`、容器 `docker/run.sh`、`docker/entrypoint.sh`）一律
**按 UUID 锁卡**，并且拒绝 `GPU-` 之外的任何值：

```
[run] 锁卡 GPU-de9cb363-62f6-d10e-9cd0-26d071ac1974
```

容器的 `entrypoint.sh` 有两级兜底，因为它可能没有 `nvidia-smi`：

1. `$GPU_UUID`（`docker/run.sh` 传进来的）
2. 扫 `/proc/driver/nvidia/gpus/*/information`，**挑型号里带 `RTX`/`GeForce` 的那张**

第 2 条是实测可用的：只要设备节点挂进去了，这个文件在容器里就能读到，
里面直接写着 `Model:` 和 `GPU UUID:`。本机实测输出：

```
0000:25:00.0   NVIDIA GeForce RTX 3060       GPU-de9cb363-62f6-d10e-9cd0-26d071ac1974
0000:26:00.0   Tesla V100-SXM2-16GB          GPU-b0834d81-085f-e807-9991-89e04ecb37cb
```

---

## 依赖是怎么算出来的

`runtime/bin/ninfer-serve` 不只是一段 CUDA 代码。它链了 ffmpeg 全家
（`libavcodec` / `libavformat` / `libavutil` / `libswscale` / `libswresample`，
用于图像与音频预处理）、cairo + pango（渲染）、X11 客户端库、librsvg、
libzmq、OpenCL…… 缺任何一个的症状都是：

```
error while loading shared libraries: libXXX.so.N: cannot open shared object file
```

而且它只报**第一个**缺的，你得一个个试。所以这些包不是手写的，是算出来的：

```bash
cd <仓库>
LD_LIBRARY_PATH="$PWD/runtime/lib" ldd runtime/bin/ninfer-serve \
  | grep -oE '/[^ ]+\.so[^ ]*' | sort -u \
  | while read -r so; do
      r=$(readlink -f "$so")            # 必须解软链，否则 dpkg -S 匹配不到
      dpkg -S "$r" 2>/dev/null | head -1 | cut -d: -f1
    done | sort -u
```

得到 **131 个包**，已经内联写在 `docker/Dockerfile` 里。
**升级引擎之后应该重跑一次这个命令**，看闭包有没有变。

`readlink -f` 那一步不是可选的 —— 直接拿 `ldd` 的路径去问 `dpkg -S`，
`/lib/x86_64-linux-gnu/...` 这种经 `/lib → /usr/lib` 软链的路径会匹配不到，
结果就是静默漏包，构建成功、运行时报错。

---

## 自定义参数

容器里生成的 `config/runtime.env` 用的是生产默认值
（`rk2v4-e8` / 49152 / 思考 1024 / medium / 温度 1.0 / top-p 0.95 / top-k 20）。
想改，**挂一份自己的**覆盖掉：

```bash
docker run ... -v /path/to/my-runtime.env:/app/config/runtime.env:ro ...
```

或者直接改 `docker/entrypoint.sh` 里生成的那段。**已经存在的
`/app/config/runtime.env` 不会被覆盖**，所以两种办法都稳。

容器里也可以直接用命令行调参器：

```bash
./docker/run.sh shell
cd /app && ./start.sh --preset fast          # 思考关掉，最快
cd /app && ./presets.sh                      # 看五档预设
```

---

## 想要一个自包含的胖镜像

```bash
./docker/build.sh --with-model
```

会把 `models/` 里的 9.5 GB 权重也 COPY 进镜像。

**实测**（2026-10-08，本机）：成品 **22.7 GB**（普通镜像是 5.45 GB）。
比"12 GB"这个拍脑袋的估算大一倍，因为 9.5 GB 的权重在镜像层里是完整一份，
不跟 `runtime/` 共享层。构建日志里会有一行确认：

```
with-model: 模型已烘进镜像 (9520051456 字节)
```

**注意 `.dockerignore` 默认挡住了 `models/`**（这是对的：默认构建的上下文只该有
2.6 GB）。走这条路时 `docker/build.sh` 会**临时改写 `.dockerignore`** 放行模型、
把原来的备份成 `.dockerignore.bak-build`，构建结束（无论成败）自动还原。

这里没有用 `docker/Dockerfile.dockerignore` 那种「按 Dockerfile 生效的忽略文件」
写法 —— 那是 BuildKit 的特性，**本机没装 buildx 插件、走的是经典构建器**，
不会生效。而它的失败方式是**静默的**：镜像建出来了，模型没进去。
所以 Dockerfile 里额外加了一条断言，`--with-model=1` 但模型没进上下文时
**直接构建失败**。

副作用：这一路会让构建上下文涨到约 12 GB，构建器要把它整体打包发给 daemon，
第一次会比较慢（本机实测约 10 分钟）。22.7 GB 的镜像也不好推不好拉，
除非你要做离线分发，否则建议用挂载。

---

## 故障排查

### 容器日志里 `urls_for_bind: command not found` / `is_lan_exposed: command not found`

**这是镜像构建时的脚本 bug，不是你操作错了**（本项目自己踩过，病历 L31）。

含义是 `docker/entrypoint.sh` 里那行 `. "$ROOT/app/env.sh"` 没被执行到 —— 典型成因是
生成 `config/runtime.env` 的 heredoc **没在该闭合的地方闭合**，把后面几行
本该执行的语句当成文本写进了配置文件。

**好在这种镜像其实还能用**（引擎配置是对的），只是容器不会打印对外地址、
也不会打局域网警告。想确认自己拿到的是不是修过的版本：

```bash
docker run --rm --entrypoint bash bonsai2-ninfer-3060:0.1.0 \
  -c 'grep -n "command -v urls_for_bind" /app/docker/entrypoint.sh'
```

有输出 = 已修（脚本里带了自检，真出问题会直接 `die` 并说清原因）；
没输出 = 旧镜像，`./docker/build.sh --no-cache` 重建即可。

### 容器起着，但 `/v1/models` 一直 503

503 表示**权重还在加载**，不是故障。首次加载约 30 秒（宿主机实测 28–35 秒，
取决于磁盘）。`docker/run.sh status` 会显示 http 码。

### `CUDA error: no CUDA-capable device is detected`

设备节点没挂进去。检查：

```bash
./docker/run.sh shell
ls -l /dev/nvidia*
cat /proc/driver/nvidia/gpus/*/information
```

如果 `/proc/driver/nvidia` 是空的，说明 `--device` 没生效，回到
「显卡怎么进容器」那一节。

### `error while loading shared libraries: libcuda.so.1`

驱动库没挂进去，或者版本号没对上。宿主机上：

```bash
ls /usr/lib/x86_64-linux-gnu/libcuda.so.*
```

拿到的版本号和 `docker/compose.yml` / `docker/run.sh` 里挂的对照一下。

### 容器里 `nvidia-smi` 报错但引擎正常

`nvidia-smi` 只是个可选的便利工具。引擎只需要设备节点和 `libcuda.so.1`，
不需要它。`docker/run.sh` 里那是 `[ -x /usr/bin/nvidia-smi ] &&` 条件挂载。

### 拉不动 `ubuntu:24.04`

`docker.io` 在国内经常不通。换镜像站：

```bash
./docker/build.sh --base docker.m.daocloud.io/library/ubuntu:24.04
```

本机实测可达的：`docker.m.daocloud.io`、`docker.1ms.run`、
`registry.cn-hangzhou.aliyuncs.com`、`docker.nju.edu.cn`。

---

## 为什么引擎不做容器的 PID 1

**故意的。** 如果引擎是 PID 1，网页控制台的「停止」按钮就控制不了它
（PID 1 在容器里对信号有特殊语义）。所以 `entrypoint.sh` 的 `serve` 模式下：

- 网页控制台后台跑
- 引擎由控制台/`launcher.sh` 后台跑
- entrypoint 保持存活并 `trap` 信号，收到 `SIGTERM` 时调 `launcher.sh stop` 收尾

这样**你在网页上点停止，引擎就真的停**，点启动就真的起。
代价是 entrypoint 多了一个保活循环，这是值得的。

---

## compose

`docker/compose.yml` 是 `docker/run.sh` 的等价物，用的是**手工挂载**方案
（不需要 toolkit）。用之前要改两处成你自己的：

- `devices:` 里的 `/dev/nvidia0` —— 改成 3060 对应的那个节点
- `GPU_UUID` —— 改成本机 3060 的 UUID

```bash
docker compose -f docker/compose.yml up -d
docker compose -f docker/compose.yml logs -f
docker compose -f docker/compose.yml down
```

如果本机装了 toolkit，把 `devices:` 和那几个驱动库挂载删掉，换成
`deploy.resources.reservations.devices`，注释里写了。
