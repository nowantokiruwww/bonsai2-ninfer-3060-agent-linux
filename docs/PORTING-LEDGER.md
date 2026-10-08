# PORTING-LEDGER — 移植病历

> 每条固定五段：**现象（原文错误串） → 根因 → 解法 → 证据 → 是否 Linux 特有**。
> 这是本项目 GitHub 那条线的主要内容：把"移植中遇到的问题和解决方法"公开，
> 让 3080/3090 的人不用重新踩一遍。
>
> 版本：随 Phase 推进持续追加。

---

## L01 跨 fork 血缘错配（旧移植的根本死因）

- **现象**：`ninfer-serve: unknown tensor format: PQ2_0_G128`（322 个 tensor 报不支持；同一文件里 Q4G64_F16S 55、Q5G64_F16S 54、W8G32_F16S 7、Q6G64_F16S 1 却"支持"）；换个 kit 后变成 `[error] ninfer-serve: artifact magic is not NInfer v1 or v2`。
- **根因**：引擎 kit 来自 `Don-Chad/ninfer-3090`（v0.6.1-rtx3090，v1/v2 时代），模型工件来自 `iamwavecut/ninfer-all` 这条线。两个 fork 的**张量格式集合不同**，v0.6.1 既没有 `t2_g128_fp16`，也只认 v1/v2 容器魔数。**错的不是模型，是引擎。**
- **解法**：把血缘钉死——先校验工件的 sha256 是否等于发布值，再怀疑构建。本项目的模型校验值与 HF `SHA256SUMS` 逐字节一致（见 `evidence/model/model-identity.txt`），所以"格式不兼容"这个结论是误判。
- **闭环（数字对上了，2026-10-06 实测）**：读工件自带的 `conversion.json` 的 `formats` 字段，
  这个 v3 工件的张量格式清单是
  `bf16 627 / t2_g128_fp16 323 / fp32 96 / q4_g64_fp16 70 / q5_g64_fp16 54 / q8_g32_fp16 12 / q6_g64_fp16 1 / int32 1`。
  而旧 kit 报的是 `PQ2_0_G128` **322 个**。**同一批权重、同一个位置、数量几乎一模一样（322 vs 323）**，
  只是两个 fork 给同一个"三值 2-bit"格式起了不同的名字。
  另外直接读文件头：`4e494e4645520003…` = ASCII `NINFER` + `0x00` + **版本字节 `0x03`**，
  正是 `src/artifact/reader.cpp:31-34` 要求的 v3（它明确拒绝 v2）。
  → 至此 L01 不再是"推测"：**错的确实是引擎 fork，模型从头到尾没问题**。
- **证据**：`evidence/model/artifact-identity.txt`（格式清单 + 容器头十六进制）、`evidence/model/model-identity.txt`（sha256）；旧证据 `~/llm/报告/ninfer-v100-verdict.md` §3、`~/llm/报告/验收报告-2026-10-05.md` §三。
- **是否 Linux 特有**：否。是**多 fork 生态**问题，Windows 上同样会踩。

## L02 二进制被 RUNPATH 硬钉在机器本地的 CUDA 上

- **现象**：旧产物 `readelf -d apps/ninfer-serve` 的 `RUNPATH: [/usr/local/cuda-13.1/targets/x86_64-linux/lib]`；`ldd` 显示 `libcudart.so.13`、`libcublas.so.13`、`libcublasLt.so.13` 全部解析到 `/usr/local/cuda-13.1/…`。
- **根因**：CMake 在为 CUDA 链接时会把 CUDA 库目录写进 RUNPATH。构建时 `CMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc`，于是产物把机器本地路径**字符串级写死**——"用本机 CUDA 编的"这件事从"大概依赖"变成了"确定写死"。
- **解法**：构建期断言 `CUDA_HOME`/`CUDA_PATH`/`CUDA_ROOT`/`CUDACXX`/`CUDAToolkit_ROOT`/`CMAKE_PREFIX_PATH`/`PKG_CONFIG_PATH` 与 `PATH`/`LD_LIBRARY_PATH` 中不得出现项目外 CUDA；产物期用 `readelf -d` 查 RUNPATH、`ldd` 查真实解析，两者都必须落在项目内。白名单例外：`libcuda.so.1`（驱动加载器）来自系统属正常。
- **证据**：`evidence/isolation/readelf-dyn.txt`、`runpath.txt`、`ldd.txt`、`artefact-gate.txt`（本项目产物）；旧产物的反面样本见 `evidence/isolation/`。
- **是否 Linux 特有**：是（RUNPATH 是 ELF 机制；Windows 无对应物）。

## L03 device profile 被静默复用（第二条、且更隐蔽的污染渠道）

- **现象**：引擎在启动时"自动"用上一套调度表，跑出来的性能与按 `--device-profile off` 的编译期表不一致，且没有任何日志提示"我读了一个旧 profile"。
- **根因**：`docs/device-profiles.md:18-20` 的解析顺序是 `$NINFER_DEVICE_PROFILES` → `$XDG_CACHE_HOME/ninfer/device-profiles.json` → `~/.cache/ninfer/device-profiles.json`。本机**已存在** `~/.cache/ninfer/device-profiles.json`（7771 B）。而内置表只覆盖 RTX 3090/4090/5090/PRO 6000（`:21`），RTX 3060（28 SM）**没有内置 profile**，无内置表时引擎会在启动时现场标定并落盘（`:60-61`）——即"从零构建"会继承"旧移植"的调度表。
- **解法**：强制 `NINFER_DEVICE_PROFILES=<project>/profiles/device-profiles.json`；整轮实验前后断言 `~/.cache/ninfer/device-profiles.json` 的 mtime 与 sha256 不变。
- **证据**：`evidence/isolation/foreign-profile-baseline.txt`（`sha256=8df4a539eb3ef042f8e98c19266a2090dc9bfff959d9ad98f81b0faec6049087`，frozen_at 2026-10-06T18:48:22+0800）。
- **是否 Linux 特有**：否（Windows 上路径变成 `%LOCALAPPDATA%\ninfer\`，同样会踩）。

## L04 "测试数据与实际使用隔断"——测速脚本自身坏了

- **现象**：`health.sh --bench` 在任何机器上都报 `Expecting value: line 1 column 1`，永远测不出速度；而验收判定**正靠这条命令**。与此同时引擎日志里真实负载跑得好好的。
- **根因**：`printf '%s' "$out" | python3 - args <<'PY'` —— heredoc 抢占了 stdin，管道里的 JSON 被丢弃。另外验收报告写着 NInfer 路线"❌ 起不来"，但同一台机器 8 小时后的日志里有 `req#8 done | ... decode 112.5 tok/s | prefill 618.1 tok/s`，真实负载是 `19 messages / tools 63 / prompt 21,629 / cache 21,371 (98.8%)`。**脚本、引擎、模型三者血缘不一致，且测试口径（256 token 短问答）与真实负载（21K token 多轮工具调用）根本不是一回事。**
- **解法**：① 脚本修法——用环境变量传 JSON，不用 heredoc 抢 stdin；② 方法学修法——验收改成 agent 形状（见 `AGENT-EXPERIENCE.md`），并把"正确性/一致性"当一等指标。
- **证据**：`~/llm/报告/验收报告-2026-10-05.md` §四 bug 4；`~/llm/logs/ninfer-v3-3060.log`。
- **是否 Linux 特有**：否。是**工程纪律**问题。

## L05 组件化 CUDA 安装少件：nvcc 缺 `nvvm/bin/cicc`

- **现象**：CMake 在 `project()` 阶段就失败，编译器 ID 检测报
  `sh: 1: <cuda>/bin/../nvvm/bin/cicc: not found`，`--error 0x7f`。
- **根因**：用 NVIDIA 官方 redist 清单按组件安装时，`cuda_nvcc` 组件**不含** nvcc 的 C 前端；`cicc` 在 **`libnvvm`** 组件里。
- **解法**：组件清单加入 `libnvvm`（44,796,540 B，v13.1.80）；并在脚本里加前置断言 `[ -x <cuda>/nvvm/bin/cicc ]`，让这个错误以一句清晰的话暴露，而不是让 96 分钟的构建在 1 分钟后死掉。
- **证据**：`logs/20-cuda/*/003-*.log`、`config/toolchain.lock` 的 `[cuda.components]` 段。
- **是否 Linux 特有**：是（这是"免 root 组件化安装"这条 Linux 路线的特有坑；官方 `.run` 或 apt 不会遇到）。

## L06 组件化 CUDA 安装布局不匹配：库在 `lib/`，nvcc 找 `lib64/`

- **现象**：`/usr/bin/ld: 找不到 -lcudadevrt`、`/usr/bin/ld: 找不到 -lcudart_static`，`collect2: error: ld returned 1 exit status`。但这两个文件确实已经装进项目 CUDA 根了。
- **根因**：CUDA 13 的拆分组件把库放在 `<cuda>/lib/`，而 nvcc/CMake 的库搜索路径是 `<cuda>/lib64`（外加 `<cuda>/lib64/stubs`）。文件在 `lib/libcudadevrt.a` 与 `lib/libcudart_static.a`，链接器去 `lib64` 找，自然找不到。
- **解法**：合并完成后补 `ln -sfn lib <cuda>/lib64`（幂等），并把这一步写进 `scripts/20-cuda-fetch.sh` 的"布局修正"段。
- **证据**：`logs/20-cuda/*/`、`evidence/toolchain/`。
- **是否 Linux 特有**：是。

## L07 GitHub 大 pack 传输被中途掐断

- **现象**：`git clone --no-checkout https://github.com/iamwavecut/ninfer-all.git` 跑了 8m51s 后失败：
  `error: RPC 失败。curl 92 HTTP/2 stream 5 was not closed cleanly: CANCEL (err 8)`、
  `fetch-pack: unexpected disconnect while reading sideband packet`、`fatal: 过早的文件结束符（EOF）`。
- **根因**：与另一个大下载并发（当时 NVIDIA `.cn` 30MB 用了 8m38s ≈ 58 KB/s），链路被互相挤占；HTTP/2 在长传输上更容易被掐。
- **解法**：① **重传输必须串行**（单独测时 `.cn` 3.73 MB/s、hf-mirror 3.31 MB/s，说明源站没问题）；② git 强制 `-c http.version=HTTP/1.1 -c http.postBuffer=1073741824 -c core.compression=0`；③ 优先"按 SHA 浅取"——`git init` + `git fetch --depth 1 origin <sha>`，把体量降到最小。改后 33 秒完成。
- **证据**：`logs/40-sources/20261006-185041/001-*.log`（失败）、`logs/40-sources/20261006-190515/003-*.log`（成功）。
- **是否 Linux 特有**：否（但"并发挤占"这个教训在本环境特别容易复现）。

## L08 RTX 3060 在 12G 显存上的 KV 容量强依赖 `--kv-dtype`（禁止把 24576 当常量）

- **现象**：bench 的 Windows 记录里 3060 用 `--kv-capacity 24576 --kv-dtype int8` 才能启动，并注明 `--kv-capacity auto` 会因 dflash2 草稿权重（9.10 GiB）多留 1 GiB 而**拒绝启动**。
- **根因**：容量上限由 KV dtype 位宽 × 层数 × 上下文长度共同决定，不是卡的常数。
- **反例证据**：本机旧服务在同一张 12G 卡上用 `--max-context 76768 --kv-capacity 76768 --kv-dtype rk2v4-e8` **跑通过**（`~/llm/logs/ninfer-v3-3060.log`），说明容量可以远大于 24576。
- **为什么 12G 卡能开这么大（结构原因）**：工件 `conversion.json` 的 `config.layer_types` 显示这是**混合注意力**模型
  （`Qwen3_5ForCausalLM`，64 层，hidden 5120，vocab 248320，`max_position_embeddings` 262144）：
  只有**部分层**是 `full_attention`，其余是 `linear_attention`（没有经典 KV cache）。
  所以真正吃 KV 显存的层数远少于层数总数——不看清这一点，就会以为"12G 跑 76K 上下文"是不可能的。
- **解法**：把 `(kv-dtype, kv-capacity)` 当**可行性门禁**实测扫描（`scripts/75-kv-gate.sh`），并分别记录"带桌面"与"TTY 无桌面"两种状态（桌面在 GPU0 占 ~922MiB）。bench 的 24576 只作为"要求对齐的目标值"。
- **实测结果（2026-10-06，带桌面态，判据＝能启动且连续 3 次 256-token 请求无错）**：

  | `--kv-dtype` | 最大稳定 `--kv-capacity` |
  |---|---|
  | `int8`（bench 用的档） | **32,768** |
  | `rk8v4` | **32,768** |
  | `rk4v4-e8` | **49,152** |
  | **`rk2v4-e8`** | **76,768** |

  → **bench 的 24576/int8 不是上限**；而旧移植用的 `76768 / rk2v4-e8` 与本门禁独立扫出的最大值**完全一致**
  （交叉验证通过）。结构原因见下：这是**混合注意力**模型，吃 KV 的层数远少于 64 层。
- **证据**：`results/kv-feasibility-desktop.json`、`evidence/kv-gate/`。
- **是否 Linux 特有**：否。

## L09 28 SM 的 RTX 3060 没有内置 device profile

- **现象**：Windows 侧记录需要 `NINFER_SM_COUNT` 覆盖为 28；本项目的源码线里**根本没有 `NINFER_SM_COUNT` 这个宏**（grep 无命中）。
- **根因**：这条线改用"按实测 device profile 选 route"的机制，`docs/device-profiles.md:21` 的内置表只有 3090/4090/5090/PRO 6000；`:38` 明确说 SM 数不同必须自行标定。
- **解法**：用仓库自带的 `ninfer-calibrate`（源码 `apps/calibrate/main.cpp`，CMake 目标见 `apps/CMakeLists.txt:40-41`，产物 `build-sm86/apps/ninfer-calibrate`）在 3060 上标定 28-SM profile，落盘到项目内（`scripts/70-calibrate.sh`）；并与 `--device-profile off` 的编译期表做双向对照。
- **证据**：`evidence/calibrate/`、`profiles/device-profiles.json`。
- **是否 Linux 特有**：否（是 fork 版本差异）。

## L10 构建并行度过高会触发内核 BugCheck

- **现象**：bench 的 Windows 记录：31.8 GB 物理内存用 `-j 24` 编译触发内核 BugCheck 死机；降 `-j 6` 稳定。
- **根因**：CUDA 编译单元内存占用巨大（本机单个产物 ~700MB，链接期更甚）。
- **解法**：本项目硬上限 `NINFER_JOBS=6`（本机仅 23Gi 内存）；`CMakeLists.txt:195-198` 已把 Ninja 链接池 `ninfer_link` 限成 1，保持不动。
- **证据**：`config/env.sh` 的 `NINFER_JOBS`；本机构建日志。
- **是否 Linux 特有**：否。

## L11 V100（sm_70）不可行——不是配置问题，是 kernel 移植工程

- **现象**：用 ninfer 自己的 sm_86 cubin 在 V100 上 `cuModuleLoad` 返回 `209 CUDA_ERROR_NO_BINARY_FOR_GPU`（3060 上返回 0）；`cuobjdump --list-elf` 只有 `sm_86.cubin`；`--list-ptx` 报 `No PTX file found to extract`。
- **根因**：无 sm_70 设备码、无 PTX 故无 JIT 回退；源码指令面大量使用 Volta 没有的能力（`cp.async` 43 文件、`ldmatrix` 74、`mma.sync` 15、`__nv_bfloat16` 452、`__CUDA_ARCH__` 回退分支全树仅 1 处）；且 CUDA 13 已移除 compute_70。
- **解法**：本项目把 V100 明确排除在范围外，并**按 UUID 锁卡**（CUDA 设备序与 nvidia-smi 相反：device0=V100、device1=3060），另加 `CUDA_DEVICE_ORDER=PCI_BUS_ID` 双保险。
- **证据**：旧 `~/llm/报告/ninfer-v100-verdict.md`；本项目 `evidence/baseline/`。
- **是否 Linux 特有**：否（硬件/架构问题）。

## L12 CLI 变体陷阱：跨 kit 的 flag 集合不同

- **现象**：按旧引擎的脚本写好的启动参数，换一套 kit 就报"未知参数"。实测差异：
  `--host-state-slots`、`--host-kv-mib`、`--log-level` 在某 kit（`Don-Chad/ninfer-3090` v0.6.1 系）**根本不存在**；
  `--spec dflash2` 只在部分线存在（另一套只有 `--spec dflash`，没有 `2`）。
- **根因**：NInfer 生态是"官方 + 多个 fork"的多线格局，每条线的 CLI 集合不同；
  照抄别人的命令行而不对账，就会把"参数不存在"误读成"引擎不支持这个功能"。
- **解法**：把它做成一步显式检查，而不是靠试。
  1. 静态对账（构建前就能做）：在源码里查每个 flag 的命中，见
     `evidence/serve/flag-surface-static.md`；
  2. 动态对账（构建后）：`scripts/55-flag-diff.sh` 用真实二进制的 `--help` +
     `strings` 兜底，产出 `evidence/serve/flag-diff.md`，逐条给出"接受/不接受 + 等价替换"。
- **本次结果（正面）**：bench 的 Windows 3060 命令里那 12 个 flag
  （`--host/--port/--model-id/--max-context/--kv-capacity/--kv-dtype/--max-concurrency/--no-thinking/--greedy/--spec/--draft-tokens/--lm-head-draft`）
  **在本项目的源码线上全部存在**；`--kv-dtype` 实际接受 9 种值
  （`bf16 fp8 int8 k8v4 nvfp4 rk2v4-e8 rk4v4 rk4v4-e8 rk8v4`），bench 用的 `int8` 在列。
  所以 bench 那条命令可以逐字沿用，只需去掉 `.exe`、Windows 续行符 `^`，以及把容量换成自己实测的值。
- **证据**：`evidence/serve/flag-surface-static.md`、`evidence/serve/flag-diff.md`。
- **是否 Linux 特有**：否。是 fork 生态问题。

## L13 构建成本是"双峰"的：重尾由 21 个 attention kernel TU 决定，且并行度被内存卡住

- **现象**：`-j 6` 编译到第 43 分钟时，前 496 个目标已完成，但吞吐掉到 **0.27 个目标/分钟**；
  `vmstat` 显示 CPU **id=41%**（四成空闲）而上下文切换约 14,000/s —— 典型的等内存而不是等 CPU。
  同一时刻 `free` 显示 23Gi 里用了 15Gi、**swap 已用 6.2GiB**。
- **根因（两件事叠加，主因不是内存）**：
  1. **成本双峰**。把本机那份历史完整构建日志（`~/src/ninfer-all/build-sm86/.ninja_log`，733 条）
     按"每个目标的 end−start"拆开看：**358 个目标在前 10 分钟完成、138 个在 10–20 分钟完成，
     之后每 10 分钟只完成 3–5 个，一直到 80 分钟；最后 165 个目标在 90–100 分钟里集中完成**。
     那 60 分钟的"平台期"全花在少数巨型翻译单元上，最慢的 5 个是：
     `small_t_i8_w3_h24_append.cu.o` **1100 s**、`w3_h16_append` 1079 s、`w5_h24_append` 1016 s、
     `w4_h24_append` 1011 s、`w4_h16_append` 1005 s（单文件 15–18 分钟）。
  2. **并行度被内存卡住**。实测单个 `ptxas` RSS 峰值 **~2.6 GB**、`cicc` ~0.9 GB；
     同机还有 `llama-server` 3.3 GB、`firefox` 0.9 GB、桌面约 1 GB。
     6 路并行 ≈ 17 GB 编译内存，超过可用余量 → swap 抖动，吞吐反而比 3 路更差。
- **解法**：
  - 把 `NINFER_JOBS` 从 6 降到 **3**（本机甜点；内存 <32GB 都别贪高），
    **增量续跑**（`ninja` 会跳过已完成目标）；
  - 停机前先**清掉"磁盘上有、但 `.ninja_log` 未记录完成"的 `.o`**，否则被中断的部分目标
    会因 mtime 更新而被当成最新，可能链进损坏的目标文件。
    做法：`awk -F'\t' '{print $4}' .ninja_log | sort -u` 与磁盘上的 `.o` 列表做 `comm -13`，差值即待删。
  - **ETA 要用历史日志反推，不要按目标数线性外推**：
    剩余 225 个目标里只有 **21 个是重目标（合计 270 分钟 CPU 时间）**，其余 204 个是轻目标
    （历史上约 15 个/分钟）。按重目标 2.5 路并行算，重尾 ≈ 108 分钟——这才是真实预算。
- **证据**：`evidence/build/memory-pressure-diagnosis.txt`。
- **给下一个人省一小时的建议**：`CMakeLists.txt:127-131` 有个 `NINFER_NVCC_SPLIT_COMPILE`
  （`add_compile_options($<$<COMPILE_LANGUAGE:CUDA>:--split-compile=N>)`），能把巨型 TU 的
  nvcc 前端拆成 N 份并行编译，正好打在重尾上。**但它是目录级全局选项**：
  中途打开会让 ninja 认为所有 CUDA 目标都脏了 → 已完成的 496 个目标全部重编（更亏）。
  所以要么**第一次配置就加** `-DNINFER_NVCC_SPLIT_COMPILE=4`，要么全程不动。
  本项目默认留空以保持与历史基线可比，并把该开关透出为 `NINFER_SPLIT_COMPILE`。
- **是否 Linux 特有**：否（但"内存决定并行上限"在 Linux 上更容易被 swap 抖动放大）。

## L14 服务端 CLI 有硬约束，且"未显式给 kv-capacity"的默认行为与 bench 描述不同

- **现象**：按常识写 `--max-context 大 --kv-capacity 小` 会被引擎直接拒绝；而 bench 记录的坑③说
  "`--kv-capacity auto` 会强制多留 1 GiB 导致 12G 卡拒启"——听起来像"不给容量更危险"，
  但在这条源码线上**不给容量的默认行为并不是 auto**。
- **根因（静态读到 `src/serve/serve_options.cpp`）**：
  - `:1567` `if (options.max_context == 0) throw std::invalid_argument("--max-context must be positive");`
  - `:1568-1571` `if (options.kv_capacity.mode == KvCapacityMode::Explicit && options.kv_capacity.explicit_tokens < options.max_context) throw std::invalid_argument("--kv-capacity must be at least --max-context");` → **两者必须 ≥，相等可以**
  - `:1572-1573` `if (options.max_concurrency == 0 || options.max_concurrency > kMaximumConcurrency) throw std::invalid_argument("--max-concurrency must be in [1,8]");`
  - `:74` `--kv-capacity must be positive`；`:593` `--model-id must not be empty`；`:644` `--device-profile must be auto, off or calibrate`
  - `:1448-1454` **默认策略**：`if (!kv_capacity_explicit) { options.kv_capacity = options.context_cache.mode == ContextCacheMode::Hybrid ? KvCapacityPolicy::automatic() : KvCapacityPolicy::explicit_capacity(options.max_context); }`
    → 即：**未给 `--kv-capacity` 时，非 Hybrid 模式取 `max_context` 本身**，不是"auto 多留 1 GiB"。
  - `:206` 另有 `--kv-headroom-mib N`（auto 路径的余量旋钮）。
- **解法**：KV 门禁（`scripts/75-kv-gate.sh` + `agent/kvgate.py`）对每个档位都**同时**传
  `--max-context C --kv-capacity C`（相等，既满足 `≥` 又让容量成为唯一变量）；
  并把"未显式给容量的默认值 = max_context"作为**口径差异**写进 `METHODOLOGY.md`
  ——即 bench 那条坑在本线**不适用**，不能照抄它的结论。
- **证据**：`evidence/serve/serve-help.txt`、`evidence/serve/flag-diff.md`。
- **是否 Linux 特有**：否（fork 行为差异）。

## L15 解析工具输出必须 `LC_ALL=C`——本地化直接把门禁判反了

- **现象**：产物期污染门禁在 21:08 报 `verdict = FAIL`，并且打印出 `runpath = /值`。
  但同一份二进制手工用 `LC_ALL=C readelf -d` 看，RUNPATH 明明是
  `<项目>/.store/toolchain/cuda-13.1/lib`，`ldd` 里 `libcudart.so.13`/`libcublas.so.13`/`libcublasLt.so.13`
  也全部解析到项目内 —— **门禁把通过判成了失败**。
- **根因**：本机 locale 是中文，`readelf` 的输出被本地化（`Library runpath:` → 本地化文本）。
  脚本用的是 `readelf -d "$BIN" | grep -oE '/[^]]*' | head -1`，它抓的是**行内第一个斜杠到 `]`**，
  在中文行里抓到了本地化文本中的斜杠，于是得到 `/值` 这种垃圾，
  再拿去和项目路径前缀比较 → 必然 FAIL。
- **解法**：
  1. 所有解析工具输出的地方**强制 `LC_ALL=C`**；
  2. 不要用"抓第一个斜杠"这种脆弱写法，改为按括号关键字精确取：
     `LC_ALL=C readelf -d BIN | sed -n 's/.*(RUNPATH)[^[]*\[\(.*\)\].*/\1/p'`；
  3. 已按此修复 `scripts/50-build.sh`，并重新生成 `evidence/isolation/artefact-gate.txt`（PASS），
     在该文件里留了"曾误判 FAIL 及其原因"的说明，避免后来者对着旧结论排查。
- **为什么这条值得记**：**一个把 PASS 判成 FAIL 的脚本，比没有门禁更危险**——
  会让人去改本来正确的东西，或者干脆不信任门禁。凡是"拿工具输出做判定"的脚本都适用这条。
- **证据**：`evidence/isolation/artefact-gate.txt`、`evidence/isolation/runpath.txt`、`evidence/build/cuobjdump-elf.txt`。
- **是否 Linux 特有**：是（中文/非英文 locale 下的 GNU binutils 输出本地化）。

## L16 产物实际带 369 个 sm_86 cubin **以及** PTX（与预期不同，是好消息）

- **实测**：`cuobjdump -lelf apps/ninfer-serve` 输出 **369 个 cubin，全部 sm_86**（无 sm_120a / sm_89）；
  `cuobjdump -lptx` 输出**确有 PTX**（`device_calibration.sm_86.ptx`、`hyper_connection.sm_86.ptx`、
  `ple_inject.sm_86.ptx` …）。
- **为什么值得记**：本项目原以为 `CMAKE_CUDA_ARCHITECTURES=86` 只会生成 cubin、不带 PTX，
  于是"40/50 系能否靠 JIT 复用"被列为待定项。实测推翻了这个假设：**PTX 在**，
  所以较新架构的卡可以用同一份产物 JIT（PTX 向前兼容）。
- **证据**：`evidence/build/cuobjdump-elf.txt`、`evidence/build/cuobjdump-ptx.txt`。
- **是否 Linux 特有**：否。

## L17 投机解码**并非普遍无损**——bench 的"逐字节相同"只在可预测内容上成立

- **现象**：同 prompt、`temperature 0`、两臂 flags 完全相同（`--max-concurrency 1 --no-thinking --greedy`），
  只差一个 `--spec dflash2 --draft-tokens 7`：
  - `P1_repeat`（复读密集）：两臂 MD5 **相同**（`8e311aac…`）；
  - `P2_normal`（普通问答）：基线 `31357fec…` vs 投机 `e1f9ea65…`，**不同**。
- **排除测试性原因（关键）**：写了控制实验 `agent/correctness_control.py`，
  对**每个臂把同一个 prompt 连发 3 次**：
  | prompt | 基线 3 次 | 投机 3 次 | 臂内可复现 | 两臂一致 |
  |---|---|---|---|---|
  | P1_repeat | `8e311aac`×3 | `8e311aac`×3 | ✅ | ✅ |
  | P2_normal | `31357fec`×3 | `e1f9ea65`×3 | ✅ | ❌ |
  → **两臂各自完全可复现**，所以差异不是温度、不是 flags、不是服务抖动，**就是投机路径本身造成的**。
- **根因（机理）**：投机解码把若干草稿 token 放进**同一个验证批次**，其浮点累加次序与逐 token 解码不同；
  在少数 token 上 argmax 翻转，之后误差级联。内容越可预测（acceptance 越高）越不容易触发，
  所以复读密集内容看起来"无损"。本项目的 `--kv-dtype rk2v4-e8` 与 fork 的 route 表也影响这条边界。
- **解法 / 对外表述**：
  1. **不要写"投机无损"**，要写"在可预测内容上无损，在普通问答上会改变输出"；
  2. 给出取舍表：`P2_normal` 上投机带来 **1.91×** 端到端加速（36.5 → 69.8 tok/s），
     代价是输出可能与基线不同 → **要逐字节可复现的场景（回归/审计）用基线臂；追吞吐的交互场景用投机臂**；
  3. 把"两臂各自 3 次可复现"的控制实验固化成脚本，将来换卡/换 dtype 可复跑。
- **为什么这条最值钱**：bench 把"输出与基座逐字节相同"当成通用结论写进 README，
  而它**没有在普通内容上验证过**。这正是"测试数据与实际使用隔断"的另一面：
  **声称的无损性没被真实内容检验**。
- **证据**：`evidence/agent/control/correctness-control.json`、`results/agent-correctness-*.json`、`AGENT-EXPERIENCE.md` §4。
- **是否 Linux 特有**：否。是投机解码的数值性质。

## L18 正确性测试的公平性陷阱：`--no-thinking` 与 `--greedy` 必须两臂都加

- **现象**：第一次跑 correctness 得到 `lossless=False`，且 `P1_repeat` 两臂的 MD5 **都是 `d41d8cd98f00…`**。
- **根因**：`d41d8cd98f00b204e9800998ecf8427e` 是**空字符串的 MD5**。两个原因叠加：
  1. 两臂都**没有加 `--no-thinking`** → 思考模式开着时正文不在 `choices[0].message.content` 里，
     取到的 `content` 是空串，于是 MD5 变成空串哈希（看似"两臂一致"，其实是**空洞的一致**）；
  2. 两臂都**没有加 `--greedy`** → 采样未被强制成贪婪，输出本来就可能不同。
  更糟的是：我最初的 `start_server()` 只把"臂专属 flags"拼进命令行，
  **把公共 flags（`--max-concurrency 1 --no-thinking --greedy`）漏掉了**。
- **解法**：在 `agent/agent_accept.py` 里引入 `SERVE_EXTRA`（默认
  `--max-concurrency 1 --no-thinking --greedy`），**所有臂无条件拼上**，臂与臂之间只允许差投机相关 flag。
  修好后 `P1_repeat` 的 MD5 立刻变成真实值（`8e311aac…`）且两臂一致。
- **通用教训**：**A/B 测试里"公共配置"漏一项，就会把配置差异伪装成被测对象的差异**；
  而且**空输出的 MD5 相等**这种"假一致"极具欺骗性——判等前应先断言输出非空
  （本项目已在控制实验里显式记录 `chars`，避免再看走眼）。
- **证据**：`results/agent-correctness-20261006-213627.json`（坏）vs `agent-correctness-20261006-215313.json`（修好后）、`evidence/agent/control/`。
- **是否 Linux 特有**：否。

## L19 `--lm-head-draft` 解析通过但**启动失败**，且引擎不给原因

- **现象**：在可用配置（`--spec dflash2 --draft-tokens 7` + 可用 KV）上追加 `--lm-head-draft`
  （bench 的 Windows 命令里就有这个 flag），服务**起不来**：
  ```
  INFO  loading weights | 8.16 GiB
  INFO  weights ready | 8.16 GiB | 19.1s | 436.6 MiB/s
  ERROR startup failed | finalizing target | 32.0 ms
  ```
  两臂（含基线臂）都失败，说明不是与投机的组合问题。
- **根因**：未能定位——**引擎只给"finalizing target"，没有任何具体原因**。
  同类现象在别的 fork 上也出现过（`yangkang5303/ninfer-3090` 报告 `rk8v4` 是
  "解析能过、engine 构造期被拒"）。这类"接受了参数却在启动期失败且无诊断"的行为，
  正是让移植变成"黑盒"的东西。
- **解法 / 处置**：
  1. **本项目默认不带 `--lm-head-draft`**（`NINFER_EXTRA_FLAGS` 里没有它），
     实测可用的命令见 `README.md` 与 `AGENT-EXPERIENCE.md`；
  2. 把它登记为**已知不可用开关**，而不是"没试过"；
  3. 上游若要修，最低要求是**把 `finalizing target` 的具体原因打进日志**——
     没有诊断信息的启动失败无法被使用者排查。
- **顺带得到的强证据（正面）**：这次失败日志里明确打出
  `engine | device profile nvidia-geforce-rtx-3060-sm86: 67 routed keys (ninfer-calibrate on NVIDIA GeForce RTX 3060)`
  → **证明 28-SM 标定结果确实被引擎加载并生效**（而不是回落到编译期表）。
- **证据**：`evidence/agent/lm-head-draft/dflash2_k7.log`、`results/` 与 `evidence/agent/control/`。
- **是否 Linux 特有**：否。

## L20 打包后才会暴露的两个 bug：软链接入口失效 + EnvironmentFile 含空格值被拆

- **现象（都在"用发布物部署"时才出现）**：① `未知子命令: --foreground`，服务反复重启；
  ② 日志刷 `…/config/runtime.env: 行 26: dflash2: 未找到命令`。
- **根因**：
  1. 五个入口 `fetch-model.sh`/`calibrate.sh`/`kvgate.sh`/`serve.sh`/`verify.sh` 都是
     `runtime-tools.sh` 的**符号链接**，靠**脚本名**承载子命令；但分发只看 `$1`，
     `serve.sh --foreground` 时 `$1` 是 `--foreground` → 落到 `*)` 分支。
     更糟的是**五个入口全部退化成打印帮助**——在工程目录里跑（`scripts/80-serve.sh`）永远发现不了。
  2. `SPEC_FLAGS=--spec dflash2 --draft-tokens 7` **没加引号**。该文件既被 `source`（bash 解析），
     又当 systemd 的 `EnvironmentFile`；bash 把它拆成 `SPEC_FLAGS=--spec` + 执行 `dflash2 …`。
- **解法**：① 分发改为**按 `$0` 的 basename 推断子命令**，systemd 单元改用显式 `runtime-tools.sh serve --foreground`；
  ② 含空格的值一律加引号（bash 与 systemd EnvironmentFile 都认）。
- **为什么值得记**：这两个**只在"用发布物部署"这条最少被走到的路径上暴露**——
  印证了 `PUBLISH-CHECKLIST.md` 里"必须在干净机器上跑一遍安装流程"不是形式主义。
- **证据**：`logs/97-deploy/`、`~/bonsai-ninfer-3060/logs/service.log*`（轮转留下的失败现场）。
- **是否 Linux 特有**：是（systemd EnvironmentFile 与 bash source 的双重语义）。

## L21 KV 上限**不是这张卡的常数**——随桌面当前占多少显存变化

- **现象**：同一套参数 `rk2v4-e8 @ 76768` + `dflash2 K=7`：
  2026-10-06 21:35（空闲 **11,278** MiB）**起得来**；2026-10-07 03:38（空闲 **10,810** MiB）
  **启动失败**，日志只有 `ERROR startup failed | finalizing target | 31.8 ms`。
- **排查**：受控二分 5 个变体，排除"模型符号链接""部署目录的 profile 副本"等猜测，定位到**显存**：

  | 变体 | 结果 |
  |---|---|
  | rk2v4-e8 @ 76768 + 投机 | ❌ |
  | rk4v4-e8 @ 49152 / int8 @ 8192 | ✅ |
  | **rk2v4-e8 @ 76768 关掉投机** | ✅（权重 6.70 GiB，而投机开着是 **7.99 GiB**） |

  再在空闲 10,810 MiB 下扫阶梯：`76768 ✗ / 65536 ✓ / 57344 ✓ / 49152 ✓`。
- **根因**：显存需求 = 权重（投机多占约 1.3 GiB）+ KV + workspace，而"放不放得下"取决于**当前空闲显存**。
  **"以前能起"绝不等于"现在能起"，一次门禁的结论不能当永久上限。**
- **解法**：① 部署档取 **`rk2v4-e8 @ 49152`**（在"空闲 11,278"与"空闲 10,810"两种桌面状态下都通过，
  有真实余量；`65536` 只在后一种下验证过）；② 前置检查按**已验证条件**卡门限
  （`VERIFIED_FREE_MIB=10810`，门限 10,600），而不是拿"总占用"当"需要的空闲量"
  （早先误用 11,000，会误拦本来能起的配置）；③ 服务配 `Restart=on-failure`。
- **证据**：`~/bonsai-ninfer-3060/config/runtime.env` 里的实测表、`logs/97-deploy/`。
- **是否 Linux 特有**：否（但"桌面与推理服务抢显存"在 Linux 桌面上特别常见）。

## L22 二进制的 RUNPATH 把包钉死在构建机上；解法是随包发 CUDA 运行库

- **现象**：`dist/<ver>/runtime/` 里的 `ninfer-serve`，`readelf -d` 的 RUNPATH 是
  `<project>/.store/toolchain/cuda-13.1/lib`（**构建时绝对路径**），而包里没有 `lib/`；
  换台机器或删掉工程目录，包直接起不来——"打包即用"只在构建机上成立。
- **根因**：CMake 为 CUDA 链接时把工具链库目录写进 ELF 的 RUNPATH（免掉 `LD_LIBRARY_PATH` 的好处），
  代价是**产物不可搬迁**。与 L02（污染构建指向 `/usr/local/cuda-*`）是同一机制的两种表现。
- **解法（不重编；`$ORIGIN` RPATH 方案要约 2h，留作后手）**：
  1. `make-package.sh` 用 `cp -L` 把 `libcudart.so.13`/`libcublas.so.13`/`libcublasLt.so.13`/`libnvJitLink.so.13`
     （合计 **667 MB**）拷进 `runtime/lib/`；
  2. `runtime-tools.sh` 与 systemd 单元**前置** `LD_LIBRARY_PATH=$PREFIX/lib`；
  3. `verify.sh` 增加硬检查：`ldd` 里 cudart/cublas/nvJitLink 必须解析到 `$PREFIX/lib`
     （实测输出 `PASS: CUDA 运行库解析到包内 …/lib（包可搬动）`）。
  4. 未随包发的照旧由发行版提供：FFmpeg 60/58、libcurl4、X11 栈（Dockerfile 的 runtime 阶段同此）。
- **代价**：`runtime` 从 2.0 G 涨到 2.6 G。
- **证据**：`dist/0.1.0/runtime/lib/`、`~/bonsai-ninfer-3060/verify.sh` 输出。
- **是否 Linux 特有**：是。

## L23 DSH 接入的两条硬约束（都来自实测，不是文档推测）

- **现象 / 约束**：
  1. 请求报 `PI_AI_ERROR: No API key for provider: <id>`；
  2. `contextWindow` 与服务端 `--max-context` 不一致时会以奇怪方式失败/截断。
- **根因**：DSH 的 patch 层里，非 pi-ai 目录内路由**必须显式 `api: openai-completions`**，
  且**必须声明一个能解析的 `apiKeyEnv`**；`contextWindow` 是本地模型必须手填的真实值，
  DSH 不会去问服务端（虽然 `/v1/models` 其实会返回 `context_length`）。
- **解法**：接入脚本 `scripts/98-dsh-integrate.sh` 从**部署的 `config/runtime.env`** 读
  `KV_CAPACITY` 去填 `contextWindow`，**不让两边各填一遍**；并先检查 `BONSAI2_3060_API_KEY`
  这个 ref 是否存在（只输出名字，不打印值）。引擎不校验密钥，缺失时填 `1` 即可
  —— 这与该 profile 里 llama-server 的既有先例一致。
- **顺带的事实**：接入前 DSH 里 `bonsai2-3060` 指向 `http://127.0.0.1:8901/v1`（旧移植端口），
  而旧 unit 早已 `disabled+inactive` → **那个模型一直指向死端点**。本次改成 8098 后才真正可用。
- **证据**：`evidence/deploy/dsh-integration.txt`、`evidence/deploy/dsh-e2e.txt`。
- **是否 Linux 特有**：否（DSH 侧配置契约）。

---

## L24 引擎对单次 SIGINT 不退出 → `KillSignal=SIGINT` 让每次停止等 63 秒并被 SIGKILL

- **现象**：`systemctl --user stop` 要 **63 秒**才返回；`journalctl` 里是
  `State 'stop-sigterm' timed out. Killing.` → `Killing process (ninfer-serve) with signal SIGKILL`
  → `Failed with result 'timeout'`。单元每次停止都落成 **failed**（不是 inactive）。
  服务日志最后一行是 `WARN  Press Ctrl+C again within 5 s to close`。
- **根因**：引擎的 SIGINT 处理器要求**按两次 Ctrl+C**（第二次在 5 秒内）才关闭；单次 SIGINT
  只是打印提示继续运行。而 systemd 的 `TimeoutStopSec=60` 到点就 SIGKILL。
  这不是 Linux 移植错误——旧移植部署的 unit 用的也是 `KillSignal=SIGINT`，所以**这个毛病一直存在**。
- **解法**：`KillSignal=SIGTERM`。实测 **stop 5 秒**、`is-active=inactive`（不再 failed）、
  显存立即释放。已写进 `scripts/97-deploy-service.sh` 生成的单元。
- **对使用者的一致性**：这意味着"手动开关"是可靠的——`stop` 5 秒干净退出，`start` 32–35 秒就绪。
- **证据**：`logs/97-deploy/*` 里的 `001-systemctl-user-stop-*.log`，以及两次对照实测
  （SIGINT 63 秒 + failed；SIGTERM 5 秒 + inactive）。
- **是否 Linux 特有**：是（systemd 语义；Windows 上不存在这个问题，这也是"Windows 侧看不出毛病"的一例）。

---

## L25 生成 `runtime.env` 的 heredoc 未加引号 → 注释里的反引号被当命令替换执行

- **现象**：部署时 stderr 冒出 `scripts/97-deploy-service.sh: 行 149: prefix: 没有那个文件或目录`；
  生成出来的 `runtime.env` 里**两条注释的正文整段消失**，
  其中一条正是最有价值的诊断信息 `ERROR startup failed | finalizing target | 31.8 ms`。
- **根因**：`cat > "$ENVF" <<EOF` 用的是**未加引号**的分隔符，所以文件内容会做变量展开
  **和命令替换**；注释里我用反引号引用报错原文，bash 就把反引号里的内容当命令执行、
  用其（空）输出替换 → 文字被吃掉，同时报 `prefix: 没有那个文件或目录`。
- **为什么不能简单改成 `<<'EOF'`**：这个文件必须展开 `$PREFIX`/`$HOME`/`$KV_CAPACITY` 等真实值，
  加了引号就全变成字面量。
- **解法**：注释里的反引号换成直角引号「」。已修，重新生成的 `runtime.env` 两行正文都在。
- **通用教训**：**在会展开的 heredoc 里写注释也要守纪律**——反引号、`$(`、`${` 一律要转义或换字符。
- **是否 Linux 特有**：否（bash 语义），但只在 Linux 部署路径上才被触发。

---

## L26 生产配置里的 `--no-thinking` 造成**复读锁死**：模型逐字节重复同一次工具调用、永不脱困

- **现象（2026-10-07 实战事故，DSH 会话 `session-bca733b8`）**：让模型改一行 SVG 属性
  （`x2=-8` → `x2="-8"`）。前 14 次 `edit` 的参数里 `old_string` 与 `new_string`
  **逐字节相同**，工具一直回 `Error: old_string and new_string must differ`；
  第 15 次正确并成功落盘后，**又连续 43 次**重复同一条已成功的调用，回执全是
  `Error: old_string was not found in "…/pelican_bike.html"`。全程 ~18 分钟，
  harness 注入的 `repeat-tool-reminder`（"You are repeating the exact same tool call…"）
  一共注入了 **10 次，10/10 被完全无视**，且模型永不自愈。
- **服务端日志的特征指纹**：连续 26 条请求的统计**逐字节相同**——
  `tool calls 1 | output 120 | cache 99.8% | mixed speculation accepted 112/116 (96.6%) | ngram 102/102 accepted, 7 rounds`。
  更早还有第二个固定态（`output 121`）。即输出被**冻结在一个吸引子里**，
  120 个 token 中有 102 个是从历史里逐字复制出来的。
- **定位方法（可复用的四步）**：
  1. **一手取证**：会话转录是 zstd 压缩的 JSONL
     （`~/.dsh/sessions/<proj>/<session-id>/session.v4.jsonl.zstd`，`zstd -dc` 后按 `type` 分类）；
     关键记录类型 `tool/call`、`tool/result`、`agent/inbox/spliced`、`request/header`。
     曾出现 `compress` 调用因 `kind=content-not-array` 失败，说明**压缩摘要过长/格式错会整块丢弃**。
  2. **排除解析器冤枉模型**：把 `stream[].args` 的**原始流式文本**抠出来逐字节比对，
     确认 `old_string == new_string` 是**模型自己生成的**（不是 DSH/服务端解析或复制造成）。
  3. **小上下文复现**：`tailprobe.py`——先给 1 条"调用+失败回执"，再让模型走 3 轮。
     结果：填充 0 / 2,600 / 7,800 / 10,500 词（prompt 573 / 3,667 / 9,883 / 13,110）
     **行为完全一致**（r1/r2 都 `read`、r3 `read limit=30`）→ **长上下文不是病因**；
     另测 31 K 冷 prefill 下判 `x2=-8` 与 `x2="-8"` 是否相同，回答 `DIFFERENT`（正确）
     → **KV 量化 `rk2v4-e8` 也没有破坏这个微判别**。
  4. **找到阈值（决定性）**：`attractor.py`——**先塞 K 条完全相同的「edit 调用 + 失败回执」**，
     再让模型走 3 轮：
     | K | prompt | 结果 |
     |---|---|---|
     | 1 | 573 | r1/r2 `read`、r3 `read limit=30`，distinct=2 → **能恢复** |
     | 3 | 833 | 三轮同一个 `read`，distinct=1（轻度复读，但策略正确） |
     | **6** | **1,223** | **三轮逐字节重现那条失败的 `edit` 调用，无视紧随其后的错误回执** |
     | **10** | **1,743** | 同上 |
     即：**触发条件是"≥4–6 条完全相同的失败配对"，1.2 K token 的上下文就能完整复现**。
- **变量消元（每一步都重启服务实测）**：
  | 假设 | 操作 | 结果 |
  |---|---|---|
  | ngram 逐字复制草稿 | `--ngram-draft-tokens 0` | **证伪**：K≥4 仍全部锁死；代价是 decode 240 → 134–162 tok/s |
  | 缺 repetition penalty | `--presence-penalty 0.3 --frequency-penalty 0.6` | **证伪**：K≥4 仍锁死，且改写题退化输出 `"x2=-8"` |
  | 采样能逃逸 | 去掉 `--greedy`，`--temperature 0.3 --top-p 0.9` | **证伪**：仍**逐字节**锁死（分布尖峰到采样都逃不掉） |
  | **思考被关掉** | **移除 `--no-thinking`** | **成立**：K=3,4,5,6,8,12,16 **全部脱困**（`read`/`bash`），一次 LOCKED 都没有 |
- **根因**：`--greedy` 去掉了唯一随机逃逸，**`--no-thinking` 去掉了唯一自省通道**。
  两者叠加后，只要上下文里堆了若干条"相同调用 + 相同失败回执"，argmax 就恒等于那条调用，
  形成**只能靠新 token 才能打破、而新 token 又永远不会产生**的死循环。
  服务端的 penalty / temperature / 关投机**都改不动它**——这是一条**只能靠"让模型先想一下"**破的锁。
- **⚠️ 但"裸开思考"会立刻引入第二个故障：过度思考**。真实形状（DSH 63 个工具定义 +
  5,995 字符系统提示，`prompt 16,490`）下让模型做 A1 任务：
  `max_tokens=4096` → `out=4096 finish_reason=length`、**`reasoning_content` 11,882 字符、
  零工具调用**（全程在算坐标，一次都没动手）。
- **最终解法（已落盘 `config/runtime.env`）**：
  ```sh
  SPEC_FLAGS="--spec dflash2 --draft-tokens 7"          # ngram 恢复默认 15（关掉只有速度损失）
  EXTRA_FLAGS="--max-concurrency 1 --greedy --default-thinking-budget 512 \
               --request-log-jsonl $HOME/bonsai-ninfer-3060/logs/request.jsonl"
  ```
  **`--default-thinking-budget 512` = 给思考通道但限住它**（`--greedy` 保留，确定性不丢）。
  同一 A1 任务变成：**64.4 s、`out=4,627`、`finish_reason=tool_calls`、
  `write` 参数 10,706 字符、无 `</function>` 之类控制标签泄漏**。
- **代价（必须记账）**：思考文本不可被 dflash2 / ngram 预测，
  `mixed speculation accepted` 从 95%+ 掉到 **18–43%**，`decode` 从 ~240 tok/s 掉到 **~50–90 tok/s**。
  这是"正确性换吞吐"，在本机（单用户、agent 回路）是划算的。
- **DSH 侧没有反向开关（已查源码确认）**：`dsh-llm-pi-ai` 对 `reasoningEfforts: false`
  的模型注释原文是 "*omitting the reasoning option… a provider whose own default is to think
  would keep thinking with `off` selected*" —— 即 DSH 对声明为"非推理"的模型**根本不发思考字段**，
  引擎侧默认就是唯一开关。所以**修在引擎侧就够了，DSH 不用改**。
- **顺带发现的两处 DSH 侧脆弱点（未改，属上游）**：
  1. `dsh-repeat-tool-reminder` 只是**软提醒**，在被锁死时 10/10 无效 → 建议升级为硬熔断
     （第 N 次完全相同调用就直接终止本轮或强制注入一次 `read`）。
  2. `dsh-fs-observation-policy` 的 `editIntent` 以"本会话是否 **observe 过**"为准，
     而**成功的 `write` 本身就会建立 observed 状态**（`writeIntent`: 未见或确认不存在 ⇒
     `createIfAbsent`）；系统提示也明说 "…unless you just created or edited it in this session"。
     于是"**凭记忆 edit**"是被允许的——这正是本次事故第 1 步（`old_string` 靠回忆写错）的入口。
     对小位宽模型，**写完再改也强制先 read** 更划算。
- **证据**：`scripts/91-repeat-lock-probe.py`（新增门禁，判据 = 逐字节重现那条调用；
  修好后 K=3..20 全 PASS）；服务日志 `~/bonsai-ninfer-3060/logs/service.log`；
  现场会话 `~/.dsh/sessions/…/session-bca733b8-…/session.v4.jsonl.zstd`。
- **通用教训**：**不要把"为了 A/B 测试公平"而加的开关继承进生产配置**（见 L18）。
  `--greedy` 无害，`--no-thinking` 致命——它是**用能力换测试口径**，而 agent 回路恰恰最需要那段思考。
- **刻意保留的两处 `--no-thinking`（测试控制臂，不是生产路径）**：
  `agent/agent_accept.py:42,46`（`ACCEPT_SERVE_EXTRA`，A4 投机保真度对照）与
  `agent/kvgate.py:35`（KV 位宽对照，需要正文稳定落在 `choices[0].message.content` 里做逐字节比较）。
  两处都**故意**关思考：它们比的是"两次运行的输出是否逐字节相同"，思考文本只会干扰判据。
  ⚠️ 因此**跑 `90-agent-accept.sh correctness` / `kvgate.sh` 得到的服务配置与生产配置不同**，
  这是设计意图，不要"顺手统一"。
- **是否 Linux 特有**：否（是引擎 flag 语义），但只在"用 DSH 跑 agent 回路"时才暴露。
- **⚠️ 后续更正（2026-10-07，见 L27）**：本节当时写"`--greedy` 无害"是**错的**。
  `--greedy` 是"force temperature 0 (exact argmax)"，**没有任何随机逃逸路径**，正是本事故的
  放大器而非旁观者；且"greedy 保证逻辑一致性"的论据不成立——逐字节重复的思考本身就是
  机械、无价值的思考。生产配置已**删除 `--greedy`**，改用 `--temperature 1.0 --top-p 0.95 --top-k 20`。
  同时 `--default-thinking-budget` 的身份也从"限住过度思考"更正为"**收口机制**"（L27 §3）。

---

## L27 照抄 V100 的采样是正解，但"思考不限量"照抄不了（2026-10-07）

**触发**：用户提出"V100 虽然慢点，但智力都是在线的"，要求对比 3060(NInfer) 与
V100(llama.cpp-prism) 的参数，并**把 V100 的思考与采样参数照抄过来**。

**结论先行**：
1. **采样参数照抄——正确，已落地。** V100 的 `--temp 1.0 --top-p 0.95 --top-k 20` 换成
   ninfer 的 `--temperature 1.0 --top-p 0.95 --top-k 20`，并**删掉 `--greedy`**（L26 的根治）。
2. **"思考不限量"照抄——物理上做不到。** 两端在思考不限时都会把 `max_tokens` 烧光在思考里、
   `finish_reason=length`、**零工具调用**。这不是 ninfer 的缺陷。

### 27.1 两侧真实参数

| | V100 (llama.cpp-prism) | 3060 (NInfer, 对齐后) |
|---|---|---|
| 启动脚本 | `~/llm/scripts/start-v100-bonsai-prism.sh` | `config/runtime.env:22,29`（本节写于 L27 时，当时部署根在 `~/bonsai-ninfer-3060/`） |
| 端点 | `http://127.0.0.1:8913/v1`（pid 1090304） | `http://127.0.0.1:8098/v1` |
| 模型 | `Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf` | `bonsai2-27b` |
| 思考档位 | `--reasoning-effort medium` | `--default-reasoning-effort medium` |
| 思考预算 | （默认）`--reasoning-budget -1` = **不限** | `--default-thinking-budget 4096` ← **必须偏离**（**L28 已改为 1024**） |
| 采样 | `--temp 1.0 --top-p 0.95 --top-k 20` | `--temperature 1.0 --top-p 0.95 --top-k 20` |
| 投机 | `--spec-type draft-mtp --spec-draft-n-max 1` | `--spec dflash2 --draft-tokens 7`（**不可移植**） |
| 旧采样 | — | ~~`--greedy`~~ **已删除** |

`--greedy` 与显存无关：ninfer help 的 `SAMPLING & THINKING` 段，**纯采样开关，显存开销 0**。
它进入生产配置只是从 `agent/agent_accept.py` 的 `SERVE_EXTRA`（L18 为 A4 公平性而设）**继承**来的。

### 27.2 证据：不限思考 = 零输出（两端一致）

| 测试 | completion | reasoning | finish_reason | tool_calls |
|---|---|---|---|---|
| 3060 不限预算 @8192 | 8192 | 22,622 字符 | `length` | **0** |
| **V100 不限预算 @8192** | 8192 | 21,372 字符 | `length` | **0** |
| 3060 不限预算 @16384 | 16384 | 41,819 字符 | `length` | **0** |

**V100 一模一样**（它的 `--reasoning-budget` 默认 -1）。用户"V100 智力在线靠 medium+不限预算"
的前提**不成立**——功劳在**采样**。

**这不是复读**：对三份思考文本做行级去重，V100@8192 = 133/133、3060@16384 = 324/337、
3060@2048 = 101/102 —— 去重率 ≈ 1.0。模型真的在逐条设计 SVG 坐标，**只是永远画不完**。

### 27.3 `--default-thinking-budget` 的真实身份是"收口机制"，不是"质量帽"

```
--default-thinking-budget N     cap model-origin thinking of thinking requests
--thinking-budget-message TEXT  notice a request gets at its thinking budget;
                                the canonical </think> close is appended when missing
```

预算到点，服务端**主动补 `<｜end▁of▁thinking｜>` 强制关闭思考**，把模型推去作答。没有它，
模型在这个任务上**没有任何收口信号**。

**硬约束**（模型写一个 HTML 的 `write` 载荷 ≈ **6,100 token**，实测 `raw call0 length` 16,800 字符）：

```
思考预算 + 工具调用载荷(≈6100) ≤ max_tokens
```

### 27.4 实测矩阵

| 思考预算 | max_tokens | 结果 |
|---|---|---|
| 不限 | 8192 | ❌ 零工具调用 |
| 不限 | 16384 | ❌ 零工具调用 |
| 4096 | 8192 | ❌ `malformed_tool_call{"intended_function":"write","error":"The output ended before the tool call was closed"}` |
| 2048 | 8192 | ❌ 同上 |
| 1024 | 8192 | ❌ 同上 |
| **512** | **8192** | ✅ `finish_reason=tool_calls`，思考 537、write 内容 **12,800 字符**、尾部完整 |
| **4096** | **16384** | ✅ `finish_reason=tool_calls`，思考 4,121、write 内容 7,516 字符 |

→ 产生两个可选档位：**A**（512 + 8192，零 DSH 改动）/ **B**（4096 + 16384，思考慷慨）。
**用户选 B。**

> 注意 512 那次写出的 HTML 反而**更长**（12,800 vs 7,516 字符）：单样本下"思考更多 → 产物更好"
> 不成立。预算大小主要影响**收口安全性**，不是直接的质量旋钮。

### 27.5 运行期取证（说明采样真的生效）

`logs/request.jsonl` 的 `request_start`：

```json
"enable_thinking": true, "effective_thinking_budget": null, "requested_reasoning_effort": null,
"tool_count": 63, "requested_output_tokens_source": "client",
"sampling": {"temperature": 1.0, "top_k": 20, "top_p": 0.949999988079071, "seed": <每请求随机>, ...}
```

`--request-log-jsonl` 只写 `server_start / request_start / request_done / throughput` 四类事件，
**不含 prompt 正文**，可安全常开，是排查这类问题的关键开关（默认关闭）。

### 27.6 落盘清单

- 部署态 `~/bonsai-ninfer-3060/config/runtime.env:47-54`：`EXTRA_FLAGS` = 档位 B + 3 行注释
  说明"为什么不能照抄不限"；备份 `runtime.env.bak-20261007-135617-v100-align`。
- DSH `~/.dsh/profiles/web/cordis.patch.yml:92,99`：`bonsai2-3060` 的 `maxTokens` /
  `defaultMaxTokens` `8192 → 16384`（`contextWindow` 保持 49152）；备份
  `cordis.patch.yml.bak-20261007-145319-v100-align`。**需 DSH 重启 / 新会话才生效。**
- **生产默认值同步 9 文件 / 10 处**（旧串 → 新串），全部 `.bak-<ts>-v100-align`：
  - 工程仓：`config/env.sh:104`、`package/runtime-tools.sh:99`、`package/entrypoint.sh:15,26`、
    `package/install-runtime.sh:81`、`scripts/80-serve.sh:51`、`scripts/97-deploy-service.sh:190`
  - 部署仓：`config/env.sh:104`、`runtime-tools.sh:99`、`install-runtime.sh:81`
- **刻意不动的控制臂**（保持 `--no-thinking --greedy`，见 L26 理由，**新增一处**）：
  `agent/agent_accept.py:46`、`agent/kvgate.py:35`、`agent/correctness_control.py:40`。
- 探针提示文字更新为 L27 口径：`scripts/91-repeat-lock-probe.py:157-160` 与部署仓
  `agent/91-repeat-lock-probe.py:157-160`。

### 27.7 门禁回归与判读

`python3 scripts/91-repeat-lock-probe.py --ks 4,6,10 --rounds 4 --max-tokens 8192`

⚠ **必须显式放大 `--max-tokens`**：预算 4096 时脚本默认的 900 会被思考吃光，测不出东西。

三次独立运行、3 K × 4 轮 = 36 轮**全部 `[PASS]`**（仅 run 2 的 K=10 首轮出现一次 `EDIT-OTHER`，
那是模型改了**别的**字段，属正常策略调整）。

另有一次 `--rounds 2` 的运行在 K=4 第 1 轮判出 `LOCKED(byte-identical repeat)`，**第 2 轮立刻恢复**
`OK(bash)`。**判读：这不是 L26 那种锁死**（L26 现场是 43 次连续相同、永不恢复）。采样开起来后
偶发单次重复属抖动；**门禁的 per-round 二值判据在采样态下偏严**——它把"是否曾经重复过一次"
当成锁死，而真正的锁死签名是"**跨轮持续重复且不恢复**"。门禁本身暂不改（改判据需先积累更多
采样态样本）。

### 27.8 通用教训

1. **`--greedy` 不是"更确定"，是"没有逃逸路径"**。追求逐字节确定性的代价是：一旦落入吸引子，
   模型**永不自愈**。生产配置要的是**能恢复**，不是**可复现的错**。
2. **"思考不限量"听起来更安全，实际会让 agent 完全停摆**。一个"到点强制收口"的机制是
   必需品，不是质量妥协。
3. **思考预算必须与 `max_tokens` 成对出现**。单独调预算、不动 `max_tokens`，只会把故障从
   "无限思考"变成"工具调用被截断"（malformed），更难诊断。
4. **照抄"别人能跑"的参数前，先确认那个参数在他那边是否真的在起作用**。V100 的"不限思考"
   从来没被验证过——它只是**默认值**，而默认值不代表跑通。
5. **同一条命令行的两个"看起来一样"的脚本要分清"当前"与"已退役"**（本次因混淆二者，
   给出了错误对照表，被用户当场纠正）。写文档时**逐条标注状态**，不要靠记忆。

### 27.9 对 V100 的推论与处置（已于 2026-10-07 完成）

`v100-bonsai` provider 原本同样是 `maxTokens: 8192` + 思考不限。按 §27.2，**它存在与 3060
修复前同款的零输出隐患**——只要遇到需要长工具调用载荷的生成任务就会触发。**已按同一思路反向
收口，并做了改前/改后实测**（prompt = "穷举 8 皇后全部 92 解并逐个验证"，刻意诱导长思考）：

| 阶段 | 引擎 | max_tokens | finish_reason | completion | 思考段字符 | 正文字符 | 耗时 |
|---|---|---|---|---|---|---|---|
| 改前 | 无限思考 | 8192 | **length** | 8192 | 18913 | **0** | 115.2 s |
| 改前 | 无限思考 | 32768 | **length** | 32768 | 26361 | 27173 | 545.8 s |
| 改后 | `--reasoning-budget 8192` | 32768 | **stop** | 26392 | 16748 | **24017** | 416.3 s |
| 改后 | `--reasoning-budget 8192` | 8192 | **length** | 8192 | 11129 | **0** | 115.5 s |

1. **无限思考下，给多少 `max_tokens` 就烧多少**：8192 → 正文 0 字符；32768 → 思考吃掉前约
   三分之一才开始写正文，正文又把剩下的烧完，仍是 `length`，而且单次 9.1 分钟。**只提高
   `maxTokens` 不解决问题**——这条对两端都成立，是 §27.2 硬约束的另一面。
2. `--reasoning-budget` 生效：同上限下 `finish_reason` 由 `length` → **`stop`**，正文非空。
3. **预算必须与 `max_tokens` 配对**（上表第 4 行）：预算 8192 而 `max_tokens` 也是 8192 时，
   预算本身就把额度吃光，依旧零输出。
4. 最终取值：引擎预算 **8192** + `v100-bonsai.maxTokens` **32768**（= 3060 的 16384 的两倍，
   与 131072 窗口相称）；`timeoutMs` 300000→**900000**（实测 416 s，5 分钟墙会失败）。

**跨引擎教训（同批处理 `v100-qwen38` 时发现）**：两个模型虽然同族，用的却是**两个不同的
二进制**，能力集不同——

| | bonsai（prism 构建） | qwen38（v100-sm70 构建） |
|---|---|---|
| 二进制 | `~/llm/llama-prism-sm70/build/bin/llama-server`（0.2.0-dev / `6bfcd79`） | `~/llm/v100-sm70/llama-server`（`9611` / `02182fc5b`） |
| `--reasoning-effort` | ✅ | ❌ **不支持** |
| `--reasoning-budget` | ✅ | ✅ |

→ qwen38 脚本**只能**加 `--reasoning-budget 4096`，加了 `--reasoning-effort` 会起不来。
判断某个 flag 是否存在，必须对**那个构建自己的** `--help` 求证（本次还踩到 `grep -c --
"--flag"` 把 `--flag` 当选项解析而误报 0 的坑，改用 `grep -c -e "--flag"` 或先存 help 文件）。

回滚：`~/llm/scripts/start-v100-bonsai-prism.sh.bak-20261007-162127-reasoning-budget`、
`start-v100-qwen38.sh.bak-20261007-162127-reasoning-budget`、
`~/.dsh/profiles/web/cordis.patch.yml.bak-20261007-162329-v100-budget`。

---

## L28 用户报告"掉到 40 tok/s"：这是**打开思考的既定代价**，主杠杆是思考预算而不是投机

**现象**：2026-10-07 用户报告速度只剩 ~40 token/s，并怀疑"是不是把投机改成普通 mtp 了"。

**第一步先排除自己的嫌疑（对账）**：

- 运行中进程 cmdline 全程是 `--spec dflash2 --draft-tokens 7` —— **投机没被动过**。
- `~/bonsai-ninfer-3060/logs/service.log` 的 `命令:` 行显示该服务共 **14 次启动**：
  **12:11:57 是我的部署**，其后 **13:04:06 / 13:05:25 / 13:06:34 / 13:08:32 / 13:10:35 / 13:11:32 /
  13:14:21 / 13:56:32 / 14:08:40 / 14:11:31 / 14:14:06 / 14:16:42 / 14:18:53 全部是另一会话改的**。
  `config/runtime.env` mtime = `2026-10-07 14:54:59`，unit 文件 mtime 仍是 `12:11:57`。
- 我部署的 `EXTRA_FLAGS` = `--max-concurrency 1 --no-thinking --greedy`；
  现在 = `--max-concurrency 1 --temperature 1.0 --top-p 0.95 --top-k 20 --default-reasoning-effort medium
  --default-thinking-budget 4096 --request-log-jsonl …`。
  **两者之差就是 L26 修复（把思考打开、去掉 --greedy）+ L27 档位对齐 V100 + 取证开关。**
  KV（`rk2v4-e8 @ 49152`）与投机（`dflash2 K=7`）完全未变。

**机制（两个因素相乘，全部量化过）**：

1. **思考文本是高熵推理，草稿模型预测不了。** `logs/request.jsonl` 按思考量分桶：

   | 思考 tok | n | decode 中位 | 接受率 | 输出 tok 中位 |
   |---|---|---|---|---|
   | 0（thinking off） | 62 | 91.9 | 44.2% | 61 |
   | 1–99 | 88 | 100.6 | 44.2% | 60 |
   | 100–999 | 15 | 76.7 | 32.5% | 607 |
   | **≥1,000** | **17** | **56.5** | **33.8%** | **5,287** |

   旧部署（8901，`--no-thinking`）**812/812 条全 thinking off**；新部署 415 条里只有 231 条 off。
   **思路径 0% → 44%**，这就是主因。

2. **上下文越长，decode 越慢**（真实 DSH 会话 prompt 20K–33K）：
   `ctx 27338 → 42.6 tok/s`、`ctx 22682 → 43.7`、`ctx 19843 → 53.3`。
   **用户说的"40 tok/s"就落在这一格**。对照：`ctx 20425` 在**预算 512** 下是 **93.9 tok/s** ——
   同量级上下文，降预算后 decode 翻倍多，因为**接受率是被生成内容决定的**（思考越少越可预测）。

3. **硬件已排除**：`nvidia-smi` 1912 MHz（max 2100）、48°C、47.79 W / 170 W、util 61%，
   `Clocks Event Reasons` 的 SW Power Cap / HW Slowdown / HW Thermal / HW Power Brake 全部 Not Active。

**关键定量结论：`decode tok/s` 几乎不随思考预算变（58–83 全域），变的是"被烧掉多少 token"。**
固定 DSH 形态 agent 任务、`medium`、`K=7`、每档 3 次（`scripts/93-param-frontier.sh`）：

| 预算 | 3 次墙钟（s） | 中位 | 真正写出文件 | decode 中位 | 接受率中位 |
|---|---|---|---|---|---|
| 512 | 40.9 / 47.4 / 37.6 | 40.9 | 2/3 | 66.5 | 40.0% |
| **1024** | 44.2 / 57.2 / 42.4 | **44.2** | **3/3** | 81.7 | 42.7% |
| 2048 | 36.5 / 36.6 / 63.2 | 36.6 | 1/3 | 82.6 | 42.0% |
| 4096（当时的现状） | 56.5 / 67.8 / 124.4 | **67.8** | 1/3 | 63.9 | 39.3% |

**反直觉但可复现：放开预算并没有换来更好的产出**（4096 三次里两次只发了个 48 字符的 `bash` 敷衍）。

**ngram 不是速度旋钮（纠正旧注释）**：在 ≥1,000 思考档里 ngram 只占全部接受 token 的 **5.0%**
（`ngram 接受 251 / ngram 草稿 795`）。它在 L26 里的角色是**复读放大器**，与速度无关。
`--ngram-draft-tokens` 在开 `--spec` 时**默认就是 15（开）**；早先 `runtime.env` 里那句
"这里显式关掉（0 = 关闭）"是 13:0x 中间态残留，**与事实不符，已改**（且它引用的 "L24" 应为 L26）。

**复读风险用重复探针判开（新增 `scripts/94-lock-probe-repeat.sh`）**：
`93-param-frontier.sh` 里只跑 1 次探针的 PASS/FAIL **不足以裁决档位**——四档里都出现过 FAIL。
每档重复 5 次（15 个判据）后：

| 预算 | 单轮 LOCKED | 锁死率 | 探针 PASS/FAIL | **真锁死（≥3 轮连续不恢复）** |
|---|---|---|---|---|
| 512 | 6/15 | **40.0%** | 2 / 3 | **0** |
| **1024** | 2/15 | **13.3%** | 4 / 1 | **0** |
| 2048 | 4/15 | 26.7% | 3 / 2 | **0** |
| 4096 | 2/15 | **13.3%** | 4 / 1 | **0** |

→ ① **降预算是安全的**：四档真锁死均为 0，没有哪一档会重回 L26 的"连续 43 次不恢复"吸引子。
② **预算最低的 512 反而单轮重复率最高（40%）**——思考余量被压掉后，模型没有机会发现"上一次失败了"，
就把上一次的动作照抄一遍。（n=15，倾向性证据。）

**决策**：生产默认 `--default-thinking-budget` **4096 → 1024**（`medium` 不变）。
1024 是唯一在「速度 / 产出 / 复读稳健性」三项上都不吃亏的档位：比 4096 快 ~1.5×、
产出 3/3 扎实、重复率与 4096 并列最低。512 虽最快但 40% 的重复率不支持它当默认。

**新测量工具（纯标准库，本机 python3 无 pip）**：

- `scripts/92-thinking-throughput.py`：按 `server_instance_id` 配对 `request_start`/`request_done`，
  按「思考开关 / 预算 / 草稿窗口 / backend」分桶出 `decode tok/s 中位 / 接受率 / 思考 tok / 输出 tok / TTFT`。
- `scripts/93-param-frontier.sh`：矩阵实测台，**刻意不走 systemd**，用与 unit 相同的环境前台拉起引擎、
  **每臂独立 `--request-log-jsonl`**，逐臂跑固定任务 + 探针，产出 `evidence/params/frontier-<ts>/`。
- `scripts/94-lock-probe-repeat.sh`：探针重复测量台，把"单轮抖动"与"真锁死"分开。

**另一个必须记住的测量陷阱**：引擎**在权重加载完成之前就已经在监听端口**，此时 `/v1/models` 回 **503**。
用 `curl -s … >/dev/null` 判"有没有回话"会以为已就绪 → 20 次探针全部 rc=2、
引擎日志停在 `loading weights | 7.99 GiB`。
**就绪判据必须判 HTTP 200（`curl -o /dev/null -w '%{http_code}'`），不能只判连接成功。**

**回滚**：改 `config/runtime.env` 一行（`--default-thinking-budget`）后重启。
本仓库里就是 `./restart.sh`（或 `systemctl --user restart bonsai2-ninfer-3060.service`）。
四档都实测可用。本轮改动前 `runtime.env` 由 `97-deploy-service.sh` 模板重新生成
（生成器已同步成本档参数与正确注释）—— 那个脚本属于旧工程 `*.retired`，
本仓库已改为 `install.sh` 生成、`app/presets.env` 提供档位。

---

## L29 **"关掉思考"并不提速中文散文**：单流 decode 的地板是显存带宽，而超过它的部分全部来自投机（2026-10-07）

**现象**：用户说"中文散文的速度还是没有变"，并记得"之前很容易突破 120 token/s"。
L28 把预算从 4096 降到 1024 之后，中文散文的体感确实**没有变化**。这一条解释了为什么。

**三臂实测**（同一台机、同一张卡、`rk2v4-e8 @ 49152`、`k=7`、V100 采样 `t=1.0/p=0.95/k=20`，
每臂引擎独立重启；原始数据 `evidence/params/tune-ab-20261007/request.jsonl`）：

| 请求类型 | fast = `--no-thinking` | balanced = 思考 1024 | 关投机 + `--no-thinking` |
|---|---|---|---|
| 中文散文 ~400 字 | **26.3** tok/s（接受率 **6.1%**） | 39.1 / 57.9 / 50.6（接受率 14.6 / 27.4 / 22.9%） | **26.3** tok/s（接受率 0%） |
| 英文散文 ~400 词 | 39.5（17.5%） | 42.7（17.7%） | — |
| 代码（写 Python 函数） | 64.7（37.4%） | 72.7（40.0%） | — |
| agent + tools（英文写 SVG） | **88.3**（52.4%） | 80.8（45.2%） | — |

**结论一（最重要）：这台风扇的"裸速度"就是 ~26 tok/s。**
把投机整个关掉（`--spec none`），中文散文是 **26.4 / 26.3 / 26.0 tok/s** —— 与开着 dflash2 K=7
（26.2 / 26.3 / 27.2）**逐位相同**。也就是说中文散文上"多算的 7 个草稿"与"被接受的 6%"正好抵消，
投机在中文上是个**零和**操作。

**结论二：120+ tok/s 从来不是"这张卡的 decode 速度"，而是"投机接受率 × 带宽地板"。**
模型本体 9.5 GB / 常驻 7.99 GiB，单流每产一个 token 都要把权重读一遍：
约 8 GiB ÷ ~300 GB/s ≈ **26–37 tok/s**，这正是上表的地板。
每轮投机产出约 `1 + K×接受率` 个 token，所以

- 接受率 95%（旧部署的 DSH 代码/工具流量）→ ≈ 7.7× → **~200 tok/s**（A3 自报中位 202.1）；
- 接受率 52%（agent + tools）→ 实测 **88.3**；
- 接受率 6%（中文散文）→ 被自身开销吃掉 → **26**。

**所以用户记忆里的 120+ 是代码/英文/工具流量上的数字**；中文散文在这张卡上**从来到不了 120**，
而且**任何服务端开关都改变不了**——因为瓶颈是显存带宽，不是调度、不是预算、不是投机档。
`--no-thinking` 在中文散文上甚至**更慢**（26.3 vs balanced 中位 50.6），
因为思考文本（英文推理）的接受率反而比中文散文高。

**结论三：想提升中文场景只有两条真路**（都不是本项目的服务端参数）：
① 换更宽的卡（带宽∝速度）；② 改用能预测中文的草稿模型/表（现有 dflash2 对中文无效）。

**顺带钉住一个静默失败陷阱**：balanced 档下用 `max_tokens=900` 发中文散文，
三条请求全部 `finish_reason=length`、`content` **0 字符** —— 1024 的思考预算把 900 全烧光了。
**思考预算必须显著小于 `max_tokens`**（L27 的硬约束），否则用户拿到的是空正文而没有任何报错。
DSH 发 `max_tokens=16384` 所以碰不到，但任何"小 max_tokens + 思考开"的组合都会中招。

**结论四（调参器自己的坑，已修）：`source` 进来的锁卡变量必须再 `export` 出去。**
`scripts/96-tune-serve.sh` 第一版只 `. config/runtime.env`（把 `CUDA_VISIBLE_DEVICES` 变成 shell 变量）
而没有 `export`，于是引擎的环境里根本没有这个变量 → **它按 CUDA 自己的设备序挑中了 V100**，
日志 `engine | calibrating routes for nvidia-tesla-v100-sxm2-16gb-sm70 (80 SMs)` →
`cudaErrorNoKernelImageForDevice`（本产物只有 sm_86，没有 sm_70 的 cubin，所以当场死掉、没有造成损害）。
`profiles/device-profiles.json` 事后校验 sha256 与冻结基线一致、未被写脏。
现在脚本显式 `export CUDA_VISIBLE_DEVICES / CUDA_DEVICE_ORDER=PCI_BUS_ID / NINFER_DEVICE_PROFILES / LD_LIBRARY_PATH`，
并且在 `CUDA_VISIBLE_DEVICES` **不以 `GPU-` 开头时拒绝启动**（宁可起不来，也不要跑到别的卡上）。
`package/runtime-tools.sh` 一直是 export 的，只有新写的调参器漏了 —— **复制启动逻辑时要连 export 一起复制。**

**回滚**：无参数改动，本条只记录测量结论。复跑：`~/bonsai-ninfer-3060/tune.sh fast|balanced`，
产出的 `logs/request.jsonl` 用 `scripts/92-thinking-throughput.py` 或
`python3 /tmp/parse_req.py <jsonl> <offset>` 解析。

---

## L30 "只读验证"停掉了生产服务 + 参数兜底值漏改：**仓库与运行态的漂移要靠断言看住**（2026-10-08）

**现象（两件事，同一条根）：**

1. 为了验证"生成器能否逐字节重放部署的 `runtime.env` / unit"，跑了
   `bash scripts/97-deploy-service.sh --dry-run`。命令返回 `rc=0`、输出全是
   `(dry-run) …`，看起来完全无害。但**3060 上正在跑的 ninfer 服务被停掉了**：
   `systemctl --user is-active` 变 `inactive`、`/v1/models` 变 `http=000`。
2. 顺带发现参数有 **3 处兜底值仍写着旧的 `4096`**：
   `config/env.sh:104`、`scripts/80-serve.sh:51`、`package/entrypoint.sh:15,26`。
   它们在 L28 把生产档定成 `--default-thinking-budget 1024` 时被漏掉，
   而且**已经漏进发布物**（`dist/0.1.0/runtime/config/env.sh`、
   `dist/0.1.0/porting/scripts/80-serve.sh` 都带着 4096）。

**根因：**

1. `97-deploy-service.sh` 的第 0 步是"若本单元已在跑，先停掉（幂等重部署）"，
   这一段**没有判 `DRY`**。于是 `--dry-run` 只跳过了第 4/5/6 步的**写文件**，
   却在第 0 步做了**最重的副作用**——停服务。实测代价：服务中断，
   需要重新 `systemctl --user start` 并等 28 s 就绪。
2. 参数在 6 个文件里各有一份默认值（`config/env.sh`、`scripts/80-serve.sh`、
   `package/runtime-tools.sh`、`package/install-runtime.sh`、`package/entrypoint.sh`、
   `scripts/97-deploy-service.sh` 的生成模板）。**它们之间没有任何自动一致性检查**，
   改一处必须靠人肉记全 —— 实际就漏了 3 处。

**解法：**

1. `97-deploy-service.sh` 第 0 步加 `DRY` 短路；顺带把前置检查也做成 dry-run 感知：
   - 端口被**本单元自己**占着时，dry-run 视为正常（否则"服务在跑时验证生成器"永远失败）；
   - 空闲显存低于门限时，若差额来自本单元自己，dry-run 不做门限判定。
   现在 `--dry-run` 是**真只读**：`rc=0`、不碰服务、不写文件（实测服务保持 `active` + `http=200`）。
2. 3 处 `4096` 全部改 `1024`，并在 `config/env.sh` / `scripts/80-serve.sh` 的注释里
   写明"必须与运行态一致"。
3. **新增 `scripts/86-verify-live-match.sh`**：读运行进程的真实
   `/proc/<MainPID>/cmdline`（不是读配置文件猜），与仓库声明逐项对账，7 组共 **54 项断言**：
   - 0) 服务状态 + MainPID + cmdline 可读；
   - 1) 部署根 `runtime.env` 可读；
   - 2) 运行 cmdline 的**每个 flag** ≡ `runtime.env` 声明（双向：多了/少了都报），
        外加 L26 安全门（运行态不得出现 `--greedy` / `--no-thinking`）；
   - 3) `config/env.sh` 的 `NINFER_EXTRA_FLAGS` / `NINFER_SPEC`+`NINFER_DRAFT` ≡ 运行态
        （`--request-log-jsonl <path>` 只在运行态有，比较时剥掉），且 KV 必须保持空值；
   - 4) `97-deploy-service.sh` **生成模板**里的预算/采样/投机/KV ≡ 运行态（专防再次漏改）；
   - 5) 部署根 15 个文件 ≡ 仓库对应文件（`cmp` 逐字节）；
   - 6) 3 个二进制 ≡ 构建产物、`device-profiles.json` ≡ 冻结基线；
   - 7) 全仓扫描"有效参数位是否还有旧值"。
   退出码 `0=PASS / 1=漂移 / 2=服务没在跑`。**当前 54/54 PASS。**

**证据：**

```
$ bash scripts/86-verify-live-match.sh
  [ok]   服务 bonsai2-ninfer-3060.service = active
  [ok]   MainPID=10467
  [ok]   已读取真实 cmdline（15 个 --flag）
  …（共 54 项）…
结论：PASS —— 本仓库与 3060 上正在运行的服务一致（54 项全过）
```

**通用教训：**

1. **`--dry-run` 必须连"停服务"这种副作用一起跳过**。只跳过"写文件"是不够的 ——
   用户对 dry-run 的信任是"绝对不动现状"，破坏一次就没了。设计 CLI 时先问：
   "这一步在 dry-run 下会不会改变**外部可见状态**（进程、端口、显存、网络）？"
2. **同一语义的参数散落在 N 个文件里 = 一定会漂移**。要么收敛到单一来源，
   要么写一条**读真实运行态**的断言把它钉住。**读进程的 cmdline，不要读配置猜配置。**
3. **"仓库 ≡ 运行态"要能一条命令证明**，否则文档里的"当前配置"会悄悄过期，
   而读者会照着一份过期文档去调试。
4. 这类漂移的发现方式很朴素：**把运行态与仓库逐项列出来对照**，
   别依赖"我记得改过了"。本次三处 `4096` 全是靠对照捞出来的，不是靠回忆。

---

## L31 heredoc 没闭合 → 代码被当成**文本**写进配置文件，而不执行（2026-10-08）

**症状。** 容器跑起来看着一切正常：引擎绑 `0.0.0.0`、`/v1/models` 200、
真实请求能出结果、webUI 也能开。唯一不对劲的是容器日志里孤零零两行：

```
/app/docker/entrypoint.sh: line 189: urls_for_bind: command not found
/app/docker/entrypoint.sh: line 196: is_lan_exposed: command not found
```

这两个函数明明定义在 `app/env.sh` 里，而 `docker/entrypoint.sh:112` 就写着
`. "$ROOT/app/env.sh"`。

**根因。** `docker/entrypoint.sh:96` 的 `cat > "$ENVF" <<EOF` **一直到 `:132` 才 EOF**，
而 `:103–:131` 本该是**要执行的语句**：

```sh
cat > "$ENVF" <<EOF
# …注释…
HOST=${HOST:-0.0.0.0}        # ← 这几行不是数据，是代码
PORT=${PORT:-8098}
MODEL_ID=${MODEL_ID:-bonsai2-27b}
. "$ROOT/app/env.sh"         # ← 元凶
GPU_UUID=$GPU_UUID
KV_DTYPE=${KV_DTYPE:-rk2v4-e8}
SPEC_FLAGS="${SPEC_FLAGS:---spec dflash2 --draft-tokens 7}"
EXTRA_FLAGS="${EXTRA_FLAGS:---max-concurrency 1 … $ROOT/logs/request.jsonl}"
EOF
```

它们全被当作**文本写进了 `config/runtime.env`**。

**为什么没炸、反而"能用"。** 两件事凑巧救了它：

1. 未加引号的 heredoc 会做参数展开，`${KV_DTYPE:-rk2v4-e8}` 在**写入时**就被替换成
   `rk2v4-e8` —— 所以生成的 `runtime.env` 内容**恰好是对的**，引擎读到的配置没毛病。
2. `. "/app/app/env.sh"` 这行作为**文本**落在了 `runtime.env` 里，
   而 `app/launcher.sh:21` 会 source 这份文件 → **launcher 反倒意外拿到了那两个函数**
   （所以 `start_engine` 里的 `show_access` 打印三条 API 地址完全正常），
   只有 `entrypoint.sh` 自己从头到尾没 source 到 env.sh。

**这就是它难发现的原因：坏掉的那一半被另一半的巧合掩盖了。**
错误信息只在 `start_webui()`（唯一的、直接调用 env.sh 函数的地方）里冒出来两行。

**修法。** 把 heredoc 恢复成**纯数据**，所有语句移到 `EOF` 之后；
默认值用 `: "${KV_DTYPE:=rk2v4-e8}"` 这类写法在 heredoc **之前**算好，
heredoc 里只写 `${KV_DTYPE}`：

```sh
: "${KV_DTYPE:=rk2v4-e8}"
: "${SPEC_FLAGS:=--spec dflash2 --draft-tokens 7}"
. "$ROOT/app/env.sh"
cat > "$ENVF" <<EOF
HOST=${HOST}
KV_DTYPE=${KV_DTYPE}
SPEC_FLAGS="${SPEC_FLAGS}"
EOF
```

并加一条**自检**，让同类错误以后响亮地死掉而不是静默降级：

```sh
. "$ROOT/app/env.sh"
command -v urls_for_bind >/dev/null 2>&1 \
  || die "app/env.sh 没有被 source 到（urls_for_bind 未定义）"
```

**教训。**

1. **`bash -n` 抓不到这个。** 脚本语法完全合法，坏的是**语义**（代码落在数据区里）。
   "语法检查通过"不等于"这行会执行"。
2. **heredoc 是执行流里的一个洞**。写长 heredoc 时，习惯性在 `EOF` 之后立刻
   `echo`/`grep` 确认一下边界，或者干脆把模板挪进单独的文件
   （`cat file.tmpl`）—— 那就根本没有"闭没闭合"这回事。
3. **巧合能跑通 ≠ 设计对**。本例里"能用"完全依赖 heredoc 的展开时机和
   `launcher.sh` 会 source 同一个文件这两个偶然事实。
   判断一个改法是否安全，要看它**依赖了多少个巧合**。
4. **调用外部函数前先 `command -v` 自检**，成本一行，
   把"两行莫名其妙的 command not found"变成"一条带诊断的 die"。
5. 顺带记下同一族的 L25：那个 heredoc 是**没加引号导致反引号被执行**。
   同一份文件里两个 heredoc，一个"多执行了不该执行的"，一个"少执行了该执行的" ——
   heredoc 的边界与引号是这类脚本里最值得盯的两处。

---

## 工具链与环境事实（供 3080/3090 复用）

| 项 | 本机实测 |
|---|---|
| OS / 内核 | Ubuntu 24.04.4 LTS / 7.0.0-38-generic |
| CPU / 内存 | AMD Ryzen 5 2600X 6c12t / 23 GiB + 8 GiB swap |
| GPU | RTX 3060 12GB（sm_86，28 SM，UUID `GPU-de9cb363-62f6-d10e-9cd0-26d071ac1974`） |
| 驱动 | 580.178.04（Secure Boot disabled） |
| **PCIe（idle）** | **Gen1 ×4，max Gen2 ×16** ← 链路是 prefill 的关键限制，需在负载下复采样 |
| CUDA | 项目自带 13.1（redist 13.1.0，组件化，`compute_86` 在列，无 `compute_70`） |
| 宿主编译器 | `/usr/bin/gcc-13`、`/usr/bin/g++-13` |
| 构建并行度 | `-j 6`（硬上限） |
| 引擎源码 | `iamwavecut/ninfer-all` @ `796f985007775f4bc7cfde53804fa22e7d60dbf8`（`VERSION` 0.12.0-rtx3090） |
| 方法学参照 | `suanrongqieqiezi/ninfer-rtx30-bench` @ `c2f882ba274af6d31e941e81b114300a1dc9a657`（只读；license=null，不抄代码） |
| 模型 | `WaveCut/Ternary-Bonsai-2-27B-NInfer-v3` / 9,520,051,456 B / sha256 `cdc4810b…c14a` |

**换到 3080 / 3090 要改什么**：`config/env.sh` 里 `NINFER_CUDA_ARCH=86`（不变）、GPU UUID、`NINFER_JOBS`（按内存调）、以及**每张卡都必须重跑 `scripts/70-calibrate.sh`**（SM 数不同，调度表不同）；KV 门禁（`scripts/75-kv-gate.sh`）也要按各自显存重跑。引擎源码与 CUDA 版本可以完全不变。
