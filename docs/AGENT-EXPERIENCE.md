# AGENT-EXPERIENCE — agent 体验验收报告（实测）

> 本项目的**主验收**。不是跑分：指标必须能预测真实使用。
> 立项理由：旧移植的"测试数据与实际使用隔断"——测试测 256 token 短问答，
> 真实负载却是 `19 messages / tools 63 / prompt 21,629 / cache 21,371 (98.8%)` 的多轮工具调用。

**状态**：✅ 已实测完成（2026-10-06 21:35–21:57，RTX 3060 12GB，desktop 会话）

---

## 0. 被验对象

| 项 | 值 |
|---|---|
| 引擎二进制 | `.store/build/build-sm86/apps/ninfer-serve` |
| 二进制大小 / sha256 | **727,945,672 B** / `7ebf2ebf6c086f0f135f97090825c0a8a0a05fd02ffc9199c5faf9dc6cc6d574` |
| 设备码证据 | `cuobjdump -lelf` → **369 个 cubin，全部 `sm_86`**；`-lptx` → **有 PTX** |
| 引擎源码 | `iamwavecut/ninfer-all` @ `796f985007775f4bc7cfde53804fa22e7d60dbf8`（工作树干净，**零补丁**） |
| 模型 | `Ternary-Bonsai-2-27B-ninfer-v3.ninfer`，9,520,051,456 B，sha256 `cdc4810b…c14a`（容器头 `NINFER\x00\x03` = v3） |
| CUDA | 项目自带 **13.1**（redist 13.1.0，18 组件逐件 sha256 校验；地板 12.8） |
| 宿主编译器 | GCC 13.3.0 |
| GPU | RTX 3060 12GB / sm_86 / **28 SM** / UUID `GPU-<UUID>` |
| 驱动 | 580.178.04（Secure Boot disabled） |
| device profile | `profiles/device-profiles.json`：`hardware_class=nvidia-geforce-rtx-3060-sm86`、**`multiprocessors=28`**、`origin=ninfer-calibrate on NVIDIA GeForce RTX 3060`、**67 条 route** |
| KV 设定 | `--kv-dtype rk2v4-e8`、`--kv-capacity 76768`（由 §4.2 门禁实测，**不是抄来的 24576**） |
| 投机设定 | `--spec dflash2 --draft-tokens 7`；对照臂完全不加 `--spec` |
| 其他 flag（两臂相同） | `--max-concurrency 1 --no-thinking --greedy` |

### 环境记账（不写这些，数字就没有可比性）

| 项 | idle | 负载下复采样 |
|---|---|---|
| 3060 PCIe link | **Gen1 ×4（max Gen2 ×16）** | **仍是 Gen1 ×4**（不是省电降速，是真实链路） |
| V100 PCIe link | Gen3 ×16 | Gen3 ×16 |
| 桌面占用（GPU0） | ~922–1077 MiB | ~971 MiB |
| 服务期 GPU0 占用 | — | **10,993–11,032 MiB / 12,288 MiB** |

---

## 1. A1 主验收：真实 agent 回路 —— ✅ 通过

**方法**：`agent/agent_accept.py loop`；**63 个**工具 schema + 13,125 字符 system prompt（约 3.3K token）+ **50 轮**连续工具调用。

| 指标 | 结果 |
|---|---|
| 完成轮数 | **50 / 50**（无失败、无超时） |
| 工具调用总数 | 50 |
| **合法工具调用** | **50**（工具名 100% 在给定 schema 内、参数 100% 可被 JSON 解析） |
| 非法 | **0** |
| 首轮 wall / prompt / cached | 9.901 s / 8,403 tok / **0** |
| 末轮 wall / prompt / cached | **0.481 s** / 11,140 tok / **11,111（99.7% 前缀缓存命中）** |
| 平均每轮 wall | **0.670 s** |
| 显存 before → after | **11,032 → 11,032 MiB（零增长）** |

**读法**：第一次请求要付 8.4K token 的 prefill（9.9 s）；此后每轮只需增量 prefill，
**前缀缓存命中 99.7%**，于是**每一步 agent 动作的交互延迟降到 0.5 秒以内**。
这才是 agent 体验的真实指标——不是"能跑多少 tok/s"，而是"每一步要等多久"。

## 2. A2 长上下文边界 —— ✅ 无断崖

**方法**：`agent/agent_accept.py context`（流式测 TTFT 与 decode）

| 目标上下文 | 实测 prompt_tokens | TTFT | decode |
|---|---|---|---|
| 8K | 7,730 | 8.56 s | 47.7 tok/s |
| 16K | 15,442 | 17.69 s | 45.3 tok/s |
| 24K | 23,154 | 27.69 s | 44.1 tok/s |
| 32K | 30,866 | 38.43 s | 42.1 tok/s |
| **49K** | **46,290** | **62.37 s** | **39.0 tok/s** |

**结论**：
- TTFT 随上下文**近似线性**（约 1.1–1.35 ms/token prefill，即边际 prefill ≈ 740–900 tok/s），**没有拐点**；
- decode 从 47.7 缓降到 39.0（−18%），**没有崩塌**；
- 本机 3060 在**带桌面的 12G 卡**上能跑到 **4.6 万 token 上下文**仍有可用速度。

⚠ 本机 3060 处于 **PCIe Gen1×4**，prefill 明显受链路限制（更大链路会更快）。**该限制不可跨机横比。**

## 3. A3 长时间稳定性 —— ✅ 无漂移、无泄漏

**方法**：`agent/agent_accept.py stability`（连续 ≥50 轮，比较前 5 轮与后 5 轮）

| 指标 | 前 5 轮均值 | 后 5 轮均值 | 判定 |
|---|---|---|---|
| 每轮 wall | 0.716 s | **0.510 s** | **变快**（缓存变热），无退化 |
| prompt_tokens | 8,522.6 | 11,030.0 | 随会话自然增长 |
| 显存占用 | 10,993 MiB | **10,993 MiB** | **零增长，无泄漏** |

## 4. A4 正确性（投机是否无损）—— ❌ **不通过：普通问答上投机改变了输出**

**方法**：`agent/agent_accept.py correctness`（两臂各自起服务，同 prompt、`temperature 0`）
＋ **控制实验** `agent/correctness_control.py`（每臂把同一 prompt 连发 3 次，先判定"引擎自身是否可复现"）

### 控制实验结果（决定性的）

| prompt | 基线臂 3 次 MD5 | 投机臂 3 次 MD5 | 臂内可复现 | 两臂是否一致 |
|---|---|---|---|---|
| `P1_repeat`（复读密集） | `8e311aac` ×3 | `8e311aac` ×3 | ✅ 是 | ✅ **一致（逐字节相同）** |
| `P2_normal`（普通问答） | `31357fec` ×3 | `e1f9ea65` ×3 | ✅ 是 | ❌ **不一致** |

### 结论（严格表述）

- **两个臂各自都是可复现的**（同配置连发 3 次逐字节一致）→ 排除了"温度/flags/服务非确定"等测试性原因；
- **复读密集内容：投机无损**（acceptance 高，草稿几乎全中，输出与基线逐字节相同）；
- **普通问答内容：投机有损** —— 两臂各自稳定，但**输出不同**。

也就是说：**bench 那句"输出与基座逐字节相同"在本构建/本卡上并不普遍成立。**
它只在高度可预测的内容上成立。这与"投机解码的验证是批处理的、浮点累加次序不同，
在某些 token 上会翻转 argmax、之后误差级联"的机理一致。
本项目的 `--kv-dtype rk2v4-e8` 与 fork 的 route 表都会影响这条边界。

**这条必须作为结论对外写清**，不能像 bench 那样只写"逐字节相同"。
（`AGENT-EXPERIENCE` 的这条结论也就是用户最初说的"测试数据与实际使用隔断"的另一面：
**声称的无损性没有在真实内容上验证过**。）

### 计价取舍

| 口径 | 基线臂（无投机） | 投机臂（dflash2 K=7） | 倍率 |
|---|---|---|---|
| `P2_normal` 端到端 tok/s | 36.5 | **69.8** | **1.91×** |
| `P1_repeat` 输出 | 逐字节相同 | 逐字节相同 | 无损 |

→ 投机在**普通问答上也有近 2× 收益**，代价是**输出可能与基线不同**。
是否接受这个代价，取决于用途：**要求逐字节可复现的场景（回归测试、审计算）必须用基线臂；
追求吞吐的交互场景可用投机臂。** 这个取舍必须由使用者决定，而不是被一句"无损"掩盖。

## 5. A5 冷启动与就绪

| 指标 | 值 |
|---|---|
| 进程启动 → `/v1/models` 200 | **约 22–30 秒**（KV 门禁 16 次起停实测） |
| 首次请求 TTFT（8.4K prompt） | 9.9 s（含 prefill） |
| 反复重启稳定性 | KV 门禁共起停 16 次（4 种 dtype × 最多 4 档），**无一次卡死** |

## 6. A6 环境记账

见 §0 表格。补充：**3060 在负载下仍是 Gen1×4**（不是省电降速），这是本机 prefill 的硬上限。

---

## 7. KV 容量可行性门禁（§4.2 实测结果，带桌面态）

| `--kv-dtype` | 最大稳定 `--kv-capacity` |
|---|---|
| `int8`（bench 用的档） | **32,768** |
| `rk8v4` | **32,768** |
| `rk4v4-e8` | **49,152** |
| **`rk2v4-e8`** | **76,768** |

- 判据：能启动 **且** 连续 3 次 256-token 请求无错；失败档位（如 `rk4v4-e8 @ 65536`）连同引擎原文一起留在 `results/kv-feasibility-desktop.json`。
- **bench 的 `24576 / int8` 不是上限**：同一张 12G 卡上 `int8` 能到 32,768，`rk2v4-e8` 能到 **76,768**。
- **交叉验证**：本机旧移植的 systemd unit 用的是 `--kv-capacity 76768 --kv-dtype rk2v4-e8`，
  与本门禁独立扫出的最大值**完全一致**——说明门禁测对了。
- 结构原因：工件 `config.layer_types` 是**混合注意力**（部分层 `full_attention`，其余 `linear_attention`
  无经典 KV cache），所以吃 KV 的层数远少于 64 层。

## 8. 引擎自报吞吐（地面真相，取自服务端日志）

| 指标 | n | 中位 | min | max |
|---|---|---|---|---|
| 每请求 `decode` | 121 | **202.1 tok/s** | 0.2 | 206.8 |
| 每请求 `prefill` | 149 | **228.5 tok/s** | 5.8 | 958.2 |
| 投机接受率 `accepted N/M` | 105 | **86.2%**（均值 77.0%） | — | — |
| ngram 接受率 | 96 | 均值 **92.9%** | — | — |

> ⚠ **口径**：引擎自报的 `decode` 是**纯解码速率**（不含 prefill、不含请求开销）；
> 而本项目端到端测出的 36.5–69.8 tok/s 包含整请求开销。两者**不可混用**。
> bench 的 3060 参照"中位 108.7 tok/s"未说明其口径，故**只作量级参照，不作结论**。

## 9. 与 bench 的坐标对照

| 口径 | bench（Windows 3060，另一台机器） | 本项目（Linux 3060，本机） |
|---|---|---|
| decode（DFlash2 K=7） | 中位 108.7 tok/s | **202.1 tok/s**（引擎自报，口径见 §8） |
| prefill | 640 tok/s | 228.5 tok/s 中位（**但本机 Gen1×4，不可比**） |
| 投机接受率 | 未给（只给"逐字节相同"） | **86.2% 中位** |
| 正确性 | "输出与基座逐字节相同" | **复读密集：一致；普通问答：不一致** |
| `--kv-capacity` 上限 | 24576（int8） | **32768（int8）/ 76768（rk2v4-e8）** |
| 起动方式 | 预编译包 | **从源码编译，369 个 sm_86 cubin + PTX** |

**不可比性声明**：bench 的数字来自另一台机器（不同工具链、不同坑位）；本机 3060 链路为 Gen1×4，
prefill 尤其不可比。agent 回路指标（A1–A3）在 bench 中无对应项。

---

## 10. 结论：三个立项问题的回答

**Q1：这套东西在 Linux 上能不能从零搭起来并跑通？**
**能，且零源码改动。** 从空白基线（Phase 0）→ 项目自带 CUDA（组件化、逐件 sha256）→ 锁 commit 源码 →
sm_86 编译（721 个目标，369 个 sm_86 cubin + PTX）→ 模型哈希校验 → 28-SM 标定（67 条 route）→
KV 门禁 → 起服务 → agent 验收，全链可复现。唯一必须现场做的是 **calibration**（28 SM 无内置表）。

**Q2：能跑多快、多稳？**
- agent 回路：50/50 轮、工具调用 100% 合法、**每步交互延迟 <0.5 s**（前缀缓存 99.7%）、显存零增长；
- 长上下文：到 4.6 万 token 无断崖；引擎自报纯解码中位 **202.1 tok/s**；
- 12G 显存下最优 KV 组合：`rk2v4-e8` @ **76,768 token**。

**Q3：上次失败是 Linux 不兼容，还是移植问题？**
**是移植问题（跨 fork 血缘错配），不是 Linux 不兼容。** 证据链：
1. 工件本身完全正确（sha256 = 官方值、容器头 `NINFER\x00\x03` = v3）；
2. 上次的 `unknown tensor format: PQ2_0_G128`（**322** 个）与工件真实主力格式 `t2_g128_fp16`（**323** 个）
   是同一批权重、同一个位置，**只是两个 fork 给同一个三字 2-bit 格式起了不同名字**；
3. 换到正确源码线后，**一行源码都不用改**就编出并能加载该工件。

**同时必须诚实披露一条新发现的"暗病"**：投机解码在本构建/本卡上**并非普遍无损**
（复读密集一致、普通问答不一致）。bench 的"逐字节相同"结论没有在普通内容上验证过。
这条不影响"能跑通"，但影响"能不能把投机输出当作可复现基线"——已在 §4 给出取舍建议。

---

## 11. 部署、启动脚本与接入 DSH（2026-10-07）

### 11.1 部署形态

| 项 | 值 |
|---|---|
| 部署根 | `仓库根（本仓库）`（纯 ASCII；发布物整目录拷过去，不在工程目录里跑） |
| 服务 | user systemd `bonsai2-ninfer-3060.service`：`Type=simple`、`Restart=on-failure`、`KillSignal=SIGINT` |
| 启动命令 | `scripts/build/96-tune-serve.sh / 载荷包内 runtime-tools.sh serve --foreground`（前台；日志由 systemd 追加到 `logs/service.log`） |
| 端点 | `http://127.0.0.1:8098/v1`；`/v1/models` → `id=bonsai2-27b`、`context_length=49152` |
| 就绪耗时 | **31–33 秒**（权重 7.99 GiB，约 440 MiB/s） |
| 显存 | 服务起来后 3060 总占用 10,750 / 12,288 MiB（余量约 1.1 GiB） |
| 调参入口 | **唯一一个文件**：`config/runtime.env（由 ./install.sh 生成，不进版本库）` |

### 11.2 端到端验证（真的 DSH agent，不是只 ping 端口）

`scripts/build/99-verify-dsh.sh` 用 `dsh --profile headless --patch <临时 overlay>` 跑一次真实任务
（要求模型调用 shell 工具执行 `echo bonsai-ninfer-ok`），并与服务端日志**双向对账**：

| 检查 | 结果 |
|---|---|
| dsh 退出码 | **0** |
| dsh 输出 | `bonsai-ninfer-ok` ← 说明 shell 工具**真的执行了** |
| 服务端请求 | `req#1`(2 messages) → `req#2`(**tools 24, tool calls 1**，prompt 5,757，TTFT 7.4 s，decode 132.5 tok/s，dflash2 accepted 41/63) → `req#3`(prompt 5,828，**cache 5,805 (99.6%)**，TTFT 404 ms，decode 124.2 tok/s) |
| 判定 | **PASS**（证据 `evidence/deploy/dsh-e2e.txt`） |

证明的是完整 agent 回路（提示 → 工具调用 → 工具结果 → 复述）走本地服务，而不是只有 `/v1/models` 活着。

### 11.3 接入 DSH 的改动（最小化）

- 只改**一个已存在**的 provider 条目：`bonsai2-3060` 的 `baseURL` 从
  `http://127.0.0.1:8901/v1`（**旧移植端口；旧 unit 早已 disabled+inactive，所以它一直指向死端点**）
  改为 `http://127.0.0.1:8098/v1`；`contextWindow` 与服务端 `--max-context` 同步为 `49152`。
- **未新增** provider / 模型卡片；**未改**默认模型（仍是 `deepseek-official/deepseek-flash`）。
- 校验：`dsh --profile web --dump-config` 里出现新 `baseURL` 与 `contextWindow`。
- **待你操作**：重启 `dsh web` 后 GUI 模型选择器才会看到变化（重启会中断本会话，故未代做）。

### 11.4 部署过程中暴露并修掉的问题（都只在"用发布物部署"时出现）

1. `未知子命令: --foreground` —— 五个软链接入口靠**脚本名**承载子命令，而分发只看 `$1`，
   导致**五个入口全部退化成打印帮助**；在工程目录里跑永远发现不了。
2. `runtime.env: 行 26: dflash2: 未找到命令` —— 含空格的值没加引号，被 bash `source` 拆成"赋值 + 执行命令"。
3. **`rk2v4-e8 @ 76768` 起不来了** —— 不是回归，是**显存**：桌面占用变化使可用显存从 11,278 降到
   10,810 MiB。受控二分定位后改用 `49152 @ rk2v4-e8`（在两种桌面状态下都验证通过）。
4. 二进制 RUNPATH 钉在构建路径、包内无 CUDA 运行库 → 补 `runtime/lib/`（667 MB）+ `LD_LIBRARY_PATH`；
   现在 `verify.sh` 输出 `PASS: CUDA 运行库解析到包内（包可搬动）`。

详见 `PORTING-LEDGER.md` 的 **L20 / L21 / L22 / L23**。

## 12. A7 复读锁死门禁（2026-10-07 实战事故 → 修复 → 回归）—— ✅ 已修，PASS

**起因**：真实 DSH agent 会话里出现"智力故障"观感——模型改了 58 次同一行 SVG 属性，
其中 14 次 `old_string` 与 `new_string` 逐字节相同（工具回 `must differ`），
随后 **43 次**重复一条**早已成功**的调用（回执全是 `old_string was not found`）……
全程 18 分钟，harness 的重复告警注入 10 次、10/10 被无视。

**这是一条此前验收没覆盖的失败模式**：A1（回路能跑通）、A2（长上下文无断崖）、
A3（长时间无漂移）、A5（冷启动）都过了，但它们都**没有构造"同一条失败调用被反复堆进上下文"**。
于是补了 A7 门禁：`scripts/build/91-repeat-lock-probe.py`。

### 12.1 结论先行

| 项 | 结果 |
|---|---|
| 触发条件 | 上下文中出现 **≥4–6 条完全相同**的「工具调用 + 失败回执」配对 |
| 复现规模 | **1.2 K token 上下文即可完整复现**（不需要长上下文） |
| 是否硬件/显存/驱动 | 否 |
| 是否长上下文 / KV 量化 `rk2v4-e8` | 否（31 K 冷 prefill 仍能正确判 `x2=-8` vs `x2="-8"`） |
| 是否权重不认识引号 | 否（模型最初的 edit 意图是正当的） |
| **根因** | **`--no-thinking`（生产配置继承自 L18 的测试用 `SERVE_EXTRA`）+ `--greedy`** |
| 唯一有效解 | **移除 `--no-thinking`** + **`--default-thinking-budget 512`**（否则过度思考） |
| 无效解（都实测过） | 关 ngram、presence/frequency penalty、temperature 0.3 + top-p 0.9 |

### 12.2 最终配置（`config/runtime.env`，已落盘并重启验证）

```sh
SPEC_FLAGS="--spec dflash2 --draft-tokens 7"
EXTRA_FLAGS="--max-concurrency 1 --greedy --default-thinking-budget 512 \
             --request-log-jsonl $HOME/bonsai-ninfer-3060/logs/request.jsonl"
```

要点：`--greedy` **保留**（确定性不丢）；`--no-thinking` **移除**（给自省通道）；
`--default-thinking-budget 512` **限住思考**（防止把预算全烧在推理里）；
`--request-log-jsonl` 常开（全精度请求/响应落盘，等价于"下次故障自带黑匣子"）。

### 12.3 修复后回归（全部实测）

| 测试 | 判据 | 结果 |
|---|---|---|
| A7 锁死阈值 | K=3,4,5,6,8,12,16,20，只要逐字节重现那条调用即 FAIL | **全 PASS**，模型改换策略（`read`/`bash`/别的 `edit`） |
| A7 真实形状 | DSH 63 工具 + 5,995 字符系统提示，K=10 饱和历史走 3 轮 | `read` → `bash cat -A` → `bash ls && wc`，**无锁死、无控制标签泄漏** |
| A1 主回路（真实形状） | 原始任务"创建鹈鹕骑自行车的 SVG 动画 HTML" | 64.4 s、`out=4,627`、`finish_reason=tool_calls`、`write` 参数 10,706 字符、无泄漏 |
| A4 确定性 | 同一 payload 连发 5 次 | MD5 **全部相同**（`--greedy` 保住了确定性口径） |

### 12.4 代价（必须记账）

思考文本不可被 dflash2 / ngram 预测：`mixed speculation accepted` 从 **95%+ → 18–43%**，
`decode` 从 **~240 tok/s → ~50–90 tok/s**。属于"正确性换吞吐"，
在本机这种单用户 agent 回路下是划算的；**若要重新提速，不能靠关思考，只能换更宽的卡或更小的 KV 位宽**。

### 12.5 两个反直觉的实测点

1. **采样也逃不掉**：`temperature 0.3 + top-p 0.9`（去掉 `--greedy`）下，
   模型仍然**逐字节**重复那条调用——吸引子的概率质量尖到采样都无法偏出。
   所以"加点温度就好了"是错的。
2. **过度思考是第二个坑**：裸开思考后，同一 A1 任务在 `max_tokens=4096` 下
   `finish_reason=length`、`reasoning_content` 11,882 字符、**零工具调用**。
   必须配 `--default-thinking-budget`，否则等于用"复读锁死"换"只说不做"。

### 12.6 DSH 侧（结论：不用改，但有两处建议）

- **不用改**：`dsh-llm-pi-ai` 对 `reasoningEfforts: false` 的模型**根本不发思考字段**
  （源码注释原文："*omitting the reasoning option… a provider whose own default is to think
  would keep thinking with `off` selected*"），所以**引擎侧默认就是唯一开关**。
- **建议上游硬化**（本次未改）：① `dsh-repeat-tool-reminder` 从软提醒升级为硬熔断；
  ② `dsh-fs-observation-policy` 里成功的 `write` 会建立 observed 状态，使"写完不 read 直接 edit"合法
  （系统提示也如此声明）——这正是"凭记忆 edit 写错 `old_string`"的入口，对小位宽模型建议收紧。

详见 `PORTING-LEDGER.md` 的 **L26**。

> ⚠️ **本节档位已被 §13 取代**：`--greedy` 与 `--default-thinking-budget 512` 都已不是生产值。
> 本节保留为事故现场记录，**不要按 §12.2 恢复配置**。

---

## 13. A7 后续：档位对齐 V100，以及 `--greedy` 的根治（2026-10-07 追加）—— ✅ 已落地

### 13.1 结论先行

用户要求"把 V100/llama.cpp-prism 的思考和采样参数照抄到 3060"。**照抄采样是对的，
照抄"思考不限量"做不到**——两端在思考不限时都会零工具调用。详见 `PORTING-LEDGER.md` 的 **L27**。

### 13.2 最终配置（`config/runtime.env:22,29`）

```
SPEC_FLAGS="--spec dflash2 --draft-tokens 7"
EXTRA_FLAGS="--max-concurrency 1 --temperature 1.0 --top-p 0.95 --top-k 20 \
             --default-reasoning-effort medium --default-thinking-budget 1024 \
             --request-log-jsonl <仓库根>/logs/request.jsonl"
```

> ⚠ 思考预算是 **1024**，**不是 L27 当初选的 4096** —— L28 按「速度 / 产出 /
> 复读稳健性」三项实测后改的，见 13.5。本节其余数字（矩阵、墙钟）都是**实测记录**，
> 说的是"某档位测得多少"，不是"现在跑的是哪档"。

若你也用 DSH 接这个服务，需要把这个模型的 `maxTokens` / `defaultMaxTokens`
提到 `16384`（作者本机是 `本机 harness 配置文件（未发布；摘录见下文）第 92、99 行`，
路径只是举例，按你自己的 profile 改）。**需 DSH 重启 / 新会话才生效。**

### 13.3 V100 ↔ 3060 参数映射

| V100 / llama.cpp-prism | 3060 / NInfer |
|---|---|
| `--reasoning-effort medium` | `--default-reasoning-effort medium` |
| `--reasoning-budget -1`（默认不限） | **`--default-thinking-budget 1024`**（必须偏离；L27 时曾是 4096） |
| `--temp 1.0 --top-p 0.95 --top-k 20` | `--temperature 1.0 --top-p 0.95 --top-k 20` |
| `--spec-type draft-mtp --spec-draft-n-max 1` | `--spec dflash2 --draft-tokens 7`（**不可移植**） |
| （无 `--seed`） | （不传 `--seed` = fresh per request） |

### 13.4 为什么"不限思考"是照抄不了的

| 测试 | reasoning | finish_reason | tool_calls |
|---|---|---|---|
| 3060 不限预算 @8192 | 22,622 字符 | `length` | **0** |
| **V100 不限预算 @8192** | 21,372 字符 | `length` | **0** |
| 3060 不限预算 @16384 | 41,819 字符 | `length` | **0** |

**V100 完全相同** → 不是 ninfer 缺陷。而且这**不是复读**：思考文本行去重率
V100@8192 = 133/133、3060@16384 = 324/337 —— 模型真的在设计 SVG 坐标，**只是永远画不完**。

`--default-thinking-budget` 的真实身份是**收口机制**：到点服务端主动补 `</think>` 逼模型作答
（help：*the canonical `</think>` close is appended when missing*）。硬约束：

```
思考预算 + 工具调用载荷(≈6100 tok) ≤ max_tokens
```

### 13.5 实测矩阵（同一条 payload，逐档重启）

| 预算 | max_tokens | 结果 |
|---|---|---|
| 不限 | 8192 / 16384 | ❌ 零工具调用 |
| 4096 / 2048 / 1024 | 8192 | ❌ `malformed_tool_call`（工具调用被截断） |
| **512** | **8192** | ✅ 收口，write 内容 12,800 字符 |
| **4096** | **16384** | ✅ 收口，write 内容 7,516 字符 |

→ 档位 A（512/8192，零 DSH 改动） vs 档位 B（4096/16384）。**用户选 B。**

### 13.6 对 §12.5 第 1 条的更正（重要）

§12.5 写"加点温度就好了是错的"——**那个结论的测法有问题**：`--greedy` 的语义是
**"force temperature 0 (exact argmax)"**，只要 `--greedy` 还在命令行里，**`--temperature`
无论设多少都被强制归零**。所以"在 `--greedy` 还在时加温度"必然无效。

正确顺序是**先删 `--greedy`，再谈温度**。删除 `--greedy` 后（`temp 1.0`），
§13.7 的 36 轮门禁全 PASS。

### 13.7 回归（全部实测）

- **端到端**：预算 4096 @ 16384 → `finish_reason=tool_calls`，思考 4,121 字符，写出完整 HTML。
- **A7 门禁**：`python3 scripts/build/91-repeat-lock-probe.py --ks 4,6,10 --rounds 4 --max-tokens 8192`
  三次独立运行、36 轮**全部 PASS**。
  ⚠ **必须显式放大 `--max-tokens`**：预算 4096 时脚本默认的 900 会被思考吃光。
- **门禁判据的已知偏严**：另一次 `--rounds 2` 运行在 K=4 首轮判 `LOCKED`、**第 2 轮即恢复**。
  这不是 L26 式锁死（L26 是 43 次连续、永不恢复）。采样态下 per-round 二值判据会把偶发单次
  重复误判为锁死；真锁死签名是"**跨轮持续重复且不恢复**"。门禁暂不改，需先积累采样态样本。
- **运行期取证**：`logs/request.jsonl` 确认 `temperature 1.0 / top_p 0.95 / top_k 20` 生效，
  `seed` 每请求随机。该日志**不含 prompt 正文**，可安全常开。
- **吞吐**：对齐后 3060 decode 实测 **57–220 tok/s**（随输出可预测性浮动）。

### 13.8 代价与风险

- DSH `maxTokens 16384` 会**挤压可用输入上下文**（`contextWindow` 仍是 49152 硬上限）。
- 若某任务的工具调用载荷 > 12,000 token，仍会被截断 → 需调低预算或继续提高 `maxTokens`。
- 回滚：`config/runtime.env.bak-20261007-135617-v100-align` + `cordis.patch.yml.bak-20261007-145319-v100-align`。

### 13.9 DSH 侧（结论不变）

§12.6 的结论继续有效：`reasoningEfforts: false` 让**引擎侧默认档位成为唯一开关**——
也就是说，**这次对齐完全发生在服务端**，DSH 除了 `maxTokens` 不需要任何改动。

### 13.10 V100 反向收口（2026-10-07 完成，不再是"待跟进"）

§13.4 实测的 V100 零工具调用，根因与本机一致：`v100-bonsai` 当时也是 `maxTokens: 8192` +
思考不限。**已反向收口并验收**：引擎加 `--reasoning-budget 8192`，`v100-bonsai.maxTokens`
8192→**32768**、`timeoutMs` 300000→**900000**。

改前/改后（prompt = "穷举 8 皇后全部 92 解并逐个验证"）：

| 阶段 | max_tokens | finish_reason | completion | 正文字符 | 耗时 |
|---|---|---|---|---|---|
| 改前 | 8192 | **length** | 8192 | **0** | 115 s |
| 改前 | 32768 | **length** | 32768 | 27173 | 546 s |
| 改后 | 32768 | **stop** | 26392 | **24017** | 416 s |
| 改后 | 8192 | **length** | 8192 | **0** | 116 s |

两条新教训（细节见 `evidence/reports/bonsai-3060-vs-v100-params.md` §9 与 PORTING-LEDGER §27.9）：
1. **只提高 `maxTokens` 不能解决"思考不收口"**——给多少它烧多少，还更慢。预算才是收口机制。
2. **同族两个模型可能用两个不同的二进制**：`v100-qwen38` 用的 `本机 V100 对照二进制（未发布）`
   支持 `--reasoning-budget` 但**不支持 `--reasoning-effort`**。跨引擎照抄参数前，先对**那个
   构建自己的** `--help` 求证。

---

## 14. A8 降速归因：40 tok/s 不是故障，是"打开思考"的既定代价（2026-10-07）

**用户提问**：「你对我重新编译的 ninfer-3060-bonsai 改了什么参数来着？怎么现在速度只有 40 token/s 了……
不会你把投机改成普通的 mtp 了吧？」

**第一步是对账，不是猜。** 运行中进程 cmdline 全程是 `--spec dflash2 --draft-tokens 7` —— **投机没被动过**。
`logs/service.log` 的 `命令:` 行显示该服务共启动 14 次：12:11:57 是本工程的部署，
其后 13 次全在 13:04–14:18 由另一会话完成（L26 复读锁死修复 + L27 档位对齐 V100）。
**我部署的与现在跑的差集，恰好就是"把思考打开 + 去掉 `--greedy` + 对齐 V100 采样 + 加取证日志"。**

**机制（全部量化，取自 `logs/request.jsonl`）**：

- 旧部署 **812/812** 条请求是 `thinking off`；新部署 415 条里只有 231 条 off → **思路径 0% → 44%**。
- 思考文本是高熵推理，dflash2 草稿模型预测不了。按思考量分桶，`≥1,000 思考 token` 那 17 条的
  **decode 中位 56.5 tok/s、接受率 33.8%、单轮输出 5,287 token**
  （对照 thinking off：91.9 / 44.2% / 61）。
- 上下文再乘一层：真实 DSH 会话 prompt 在 20K–33K，`ctx 27338 → 42.6 tok/s`。
  **用户看到的"40"就落在这一格。** 对照同一量级的 `ctx 20425` 在预算 512 下是 **93.9 tok/s**。
- 硬件已排除：clocks / temp / power 的四项限速原因**全部 Not Active**。

**结论：预算才是延迟的乘数**（固定 DSH 形态 agent 任务、`medium`、`K=7`、每档 3 次）：

| 预算 | 中位墙钟 | 真正写出文件 | 单轮重复率 |
|---|---|---|---|
| 512 | 40.9 s | 2/3 | **40.0%** |
| **1024（新默认）** | **44.2 s** | **3/3** | **13.3%** |
| 2048 | 36.6 s | 1/3 | 26.7% |
| 4096（旧默认） | **67.8 s** | 1/3 | 13.3% |

`decode tok/s` 几乎不随预算变（58–83 全域），**变的是"被烧掉多少思考 token"**。
反直觉但可复现：**放开预算并没有换来更好的产出**（4096 那档三次里两次只发了个 48 字符的 `bash` 敷衍）。

**顺带纠正一条早先写错的注释**：ngram **不是速度旋钮** —— 在 ≥1,000 思考档里它只占全部接受 token 的
**5.0%**；`--ngram-draft-tokens` 在开 `--spec` 时**默认就是 15（开）**。
`runtime.env` 里那句"这里显式关掉（0 = 关闭）"是 13:0x 中间态残留，**与事实不符，已删**。

**方法论产出**：

- `scripts/build/92-thinking-throughput.py` —— 从 `request.jsonl` 分桶出 decode / 接受率 / 思考量 / TTFT。
- `scripts/build/93-param-frontier.sh` —— 矩阵实测台（**刻意不走 systemd**，每臂独立请求日志，逐臂对账）。
- `scripts/build/94-lock-probe-repeat.sh` —— **单次探针不能当门禁**：四档都出现过 FAIL，
  但**真锁死（≥3 轮连续不恢复）在四档里都是 0** → 降预算是安全的。
- 一个测量陷阱（已写进病历）：引擎**在权重加载完成之前就已经在监听端口**，此时 `/v1/models` 回 **503**；
  **就绪判据必须判 HTTP 200，不能只判"curl 有没有回话"**（否则 20 次探针全打在加载窗口里）。

完整报告见 [`evidence/params/REPORT-param-audit-20261007.md`](evidence/params/REPORT-param-audit-20261007.md)，病历见 **L28**。
