# 3060 (NInfer) vs V100 (llama.cpp-prism) 跑 Bonsai-2-27B 的参数对照与对齐

日期：2026-10-07
触发：用户提出"V100 虽然慢点，但智力都是在线的"，要求对比两端参数设置，并把 V100 的思考与采样参数照抄到 3060。
结论：**采样参数照抄是正确且已落地的；"思考不限量"照抄是物理上做不到的**——两端在"不限思考"下都会把 max_tokens 烧光在思考里、零工具调用。

---

## 1. 两端的真实参数（实测命令行，不是文档推测）

### 1.1 V100 — llama.cpp-prism（对齐 + 收口后，pid 1112784，`:8913`）

启动脚本：`/home/<user>/llm/scripts/start-v100-bonsai-prism.sh`（新增 `BUDGET=${BUDGET:-8192}`）

```
/home/<user>/llm/llama-prism-sm70/build/bin/llama-server \
  -m /home/<user>/llm/models/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf \
  --host 0.0.0.0 --port 8913 -ngl 99 -fa on -c 131072 -np 1 \
  -ctk q4_0 -ctv q4_0 -b 2048 -ub 512 \
  --jinja --reasoning-effort medium --reasoning-budget 8192 \
  --temp 1.0 --top-p 0.95 --top-k 20 \
  --spec-type draft-mtp --spec-draft-n-max 1
```

关键点：
- `--reasoning-effort medium` 交给 GGUF 内嵌 chat template 决定思考档位。
- **`--reasoning-budget 8192` 是 2026-10-07 新增的收口开关**；此前不传 → 默认 `-1` = 不限
  （`llama-server --help` 原文：`-1 for unrestricted`，env `LLAMA_ARG_THINK_BUDGET`），实测会零输出（见 §9）。
- 采样：`--temp 1.0 --top-p 0.95 --top-k 20`（`--min-p` 默认 0.05 未改）。
- 锁卡靠 UUID：`V100_UUID=GPU-<redacted>`；`nvidia-smi` index 与 CUDA 枚举顺序相反，不能用 index。
- `export GGML_CUDA_BATCH_INVARIANT=1`。
- 无 systemd unit，手工终端启动；只能 `kill -INT <pid>`（不要 -9）。V100 只有 16 GB，与 `v100-qwen38` 互斥。

### 1.2 3060 — NInfer（对齐后，`:8098`）

`/home/<user>/bonsai-ninfer-3060/config/runtime.env:47,52`

```
SPEC_FLAGS="--spec dflash2 --draft-tokens 7"
EXTRA_FLAGS="--max-concurrency 1 --temperature 1.0 --top-p 0.95 --top-k 20 \
             --default-reasoning-effort medium --default-thinking-budget 4096 \
             --request-log-jsonl /home/<user>/bonsai-ninfer-3060/logs/request.jsonl"
```

### 1.3 参数映射表

| V100 / llama.cpp-prism | 3060 / NInfer | 说明 |
|---|---|---|
| `--reasoning-effort medium` | `--default-reasoning-effort medium` | 语义等价（后者只对"未指定 effort 且开着思考"的请求生效） |
| `--reasoning-budget -1`（默认） | **`--default-thinking-budget 4096`** | **必须偏离**，原因见 §3 |
| `--temp 1.0` | `--temperature 1.0` | 等价 |
| `--top-p 0.95` | `--top-p 0.95` | 等价 |
| `--top-k 20` | `--top-k 20` | 等价 |
| （无 `--seed`） | （不传 `--seed`） | ninfer 默认 `fresh per request`，与 V100 行为一致 |
| `--spec-type draft-mtp --spec-draft-n-max 1` | `--spec dflash2 --draft-tokens 7` | **不可移植**：引擎不同，各自最优投机配置 |
| （旧 3060）`--greedy` | **已删除** | 见 §2 |

---

## 2. 为什么 `--greedy` 是错的（本次纠错的核心）

`--greedy` 在 ninfer help 里属 `SAMPLING & THINKING` 段，原文 **"force temperature 0 (exact argmax)"**——它是一个**纯采样开关，显存开销为 0**。

它进入生产配置不是因为显存，而是从工程仓 `agent/agent_accept.py` 的 `SERVE_EXTRA` 继承来的（L18 为 A4 投机保真度 A/B 的公平性而设）。当初否掉采样的证据是 `--temperature 0.3 --top-p 0.9` 这个远弱于 V100 的配置，**用弱配置否掉整条路线，证据不足**。

更关键的是：`--greedy` 是精确 argmax，**没有任何随机逃逸路径**。L26 记录的复读锁死事故里，模型逐字节重复同一次工具调用 43 次、无视 10 次 harness 纠偏——`--greedy` 让这个吸引子变成绝对吸收态。

**"greedy 保证逻辑一致性"这个论据本身不成立**：逐字节重复的思考是机械的、无价值的思考，不是一致性。

---

## 3. 核心发现：照抄"不限思考"会让模型**零输出**

### 3.1 现象（两端一致）

| 测试 | completion | reasoning | finish_reason | tool_calls |
|---|---|---|---|---|
| 3060 不限预算 @8192 | 8192 | 22,622 字符 | `length` | **0** |
| **V100 不限预算 @8192** | 8192 | 21,372 字符 | `length` | **0** |
| 3060 不限预算 @16384 | 16384 | 41,819 字符 | `length` | **0** |

→ **这不是 ninfer 的缺陷**：V100 在 `--reasoning-budget -1`（默认不限）下行为完全相同，而且它连 `<｜end▁of▁thinking｜>` 都没吐出来过。

### 3.2 这不是复读，是"永不收口"

对三份思考文本做行级去重统计：

| 来源 | 唯一行 / 总行 |
|---|---|
| V100 @8192 | 133 / 133 |
| 3060 @16384 | 324 / 337 |
| 3060 @2048 | 101 / 102 |

去重率接近 1.0 → 模型**不是卡在复读**，它真的在逐条设计 SVG 坐标、算动画参数，**只是永远画不完**。三值极限压缩模型的思考里幻觉多，它需要更多思考是对的——但它**没有一个"够了，去作答"的内部信号**。

### 3.3 `--default-thinking-budget` 不是"质量帽"，是"收口机制"

ninfer help 原文：

```
--default-thinking-budget N   cap model-origin thinking of thinking requests
--thinking-budget-message TEXT   notice a request gets at its thinking budget;
                                 the canonical </think> close is appended when missing
```

即：预算到点，服务端**主动补一个 `<｜end▁of▁thinking｜>` 强制关闭思考**，把模型推去作答。没有它，模型在这个任务上没有任何收口机制。

所以用户"把思考用一个数字限制死不太好"的直觉是对的（它确实不该被当成质量帽），但**这个 flag 更准确的定位是"必须存在的收口器"**，而不是可选的限制。

### 3.4 由此确立的硬约束

模型写那个 HTML 的 `write` 工具调用载荷 ≈ **6,100 token**（实测 `raw call0 length` 16,800 字符，含 JSON 转义）。

```
思考预算 + 工具调用载荷(≈6100) ≤ max_tokens
```

DSH 原本发 `max_tokens = 8192`，所以思考预算最多只能给到 ~2,000（且几乎没余量）。

---

## 4. 实测矩阵（同一条 payload，逐档重启服务）

| 思考预算 | max_tokens | 结果 |
|---|---|---|
| 不限 | 8192 | ❌ 零工具调用 |
| 不限 | 16384 | ❌ 零工具调用 |
| 4096 | 8192 | ❌ `malformed_tool_call {"intended_function":"write","error":"The output ended before the tool call was closed"}` |
| 2048 | 8192 | ❌ 同上 malformed |
| 1024 | 8192 | ❌ 同上 malformed |
| **512** | **8192** | ✅ `finish_reason=tool_calls`，completion 6,683、思考 537、write 内容 **12,800 字符**、尾部 `</script></body></html>` 完整 |
| **4096** | **16384** | ✅ `finish_reason=tool_calls`，completion 7,733、思考 4,121、write 内容 7,516 字符、尾部 `</style></html>` |

两个 ✅ 对应两个可选档位：

- **档位 A**：预算 512 + DSH maxTokens 保持 8192 → 零 DSH 改动，但思考紧。
- **档位 B（已采用）**：预算 4096 + DSH maxTokens 提到 16384 → 思考慷慨，需改 DSH provider。

**用户选择 B。**

> 注：512/8192 那次写出的 HTML 反而更长（12,800 vs 7,516 字符），说明单样本下"思考更多 → 产物更好"并不成立；预算大小主要影响**收口安全性**，不是直接的质量旋钮。

---

## 5. 采样确实生效（运行期取证，非推测）

`logs/request.jsonl` 的 `request_start` 记录：

```json
"effective_thinking_budget": null, "enable_thinking": true,
"requested_reasoning_effort": null, "thinking_budget": null, "tool_count": 63,
"requested_output_tokens_source": "client",
"sampling": {"temperature": 1.0, "top_k": 20, "top_p": 0.949999988079071, "seed": <随机>, ...}
```

- `temperature 1.0 / top_p 0.95 / top_k 20` **确认送达并生效**，`seed` 每请求随机。
- `--request-log-jsonl` 只写 `server_start / request_start / request_done / throughput` 四类事件，**不含 prompt 正文**，可安全常开。
- 对齐后 3060 decode 实测 **57–220 tok/s**（`logs/service.log` req#41–#45：220.0 / 79.2 / 57.0 / 62.5 / 132.3）。L26 里"掉到 50–90"的记账偏保守。

---

## 6. 已落盘的改动

### 6.1 部署态（生效中）

| 文件 | 改动 | 备份 |
|---|---|---|
| `/home/<user>/bonsai-ninfer-3060/config/runtime.env:47-54` | `SPEC_FLAGS` 未动；`EXTRA_FLAGS` 换成档位 B；新增 3 行注释说明为何不能照抄"不限" | `config/runtime.env.bak-20261007-135617-v100-align` |
| `/home/<user>/.dsh/profiles/web/cordis.patch.yml:92,99` | `bonsai2-3060` 段 `maxTokens` 与 `defaultMaxTokens`：`8192 → 16384`（`contextWindow` 保持 49152） | `cordis.patch.yml.bak-20261007-145319-v100-align` |

服务已重启并验证：`systemctl --user restart bonsai2-ninfer-3060.service`，33–38 s 就绪，`/v1/models` HTTP 200，启动后逐项断言通过。

⚠ **DSH 侧改动需要 DSH 重启 / 新会话才生效**（为避免打断会话，未重启 DSH）。

### 6.2 生产默认值同步（9 个文件、10 处）

旧串 `--max-concurrency 1 --greedy --default-thinking-budget 512`
→ 新串 `--max-concurrency 1 --temperature 1.0 --top-p 0.95 --top-k 20 --default-reasoning-effort medium --default-thinking-budget 4096`

工程仓 `/home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux/`（6 文件 / 7 处）：
`config/env.sh:104`、`package/runtime-tools.sh:99`、`package/entrypoint.sh:15`（注释）与 `:26`（代码）、`package/install-runtime.sh:81`、`scripts/80-serve.sh:51`、`scripts/97-deploy-service.sh:190`

部署仓 `/home/<user>/bonsai-ninfer-3060/`（3 文件 / 3 处）：
`config/env.sh:104`、`runtime-tools.sh:99`、`install-runtime.sh:81`（`serve.sh`/`verify.sh` 是 `runtime-tools.sh` 的软链）

全部带 `.bak-<ts>-v100-align` 备份，`bash -n` 语法检查全通过，改后无残留旧串。

### 6.3 **刻意不动**的测试控制臂

以下文件保留 `--max-concurrency 1 --no-thinking --greedy`，因为它们是 A4/A6 对照实验的控制臂，改了会破坏既有基线可比性：

- 工程仓与部署仓 `agent/agent_accept.py:46`（`ACCEPT_SERVE_EXTRA`，A4 投机保真度对照）
- 工程仓与部署仓 `agent/kvgate.py:35`（KV 位宽逐字节对照）
- 工程仓 `agent/correctness_control.py:40`

→ 跑 `90-agent-accept.sh correctness` / `kvgate.sh` 得到的配置**故意不同于生产配置**，不要顺手统一。

### 6.4 探针提示文字更新

`scripts/91-repeat-lock-probe.py:157-160`（工程仓）与 `agent/91-repeat-lock-probe.py:157-160`（部署仓）的 FAIL 提示从 L26 口径更新为 L27 口径：

```
检查服务配置：--greedy 必须不在，采样（--temperature/--top-p/--top-k）应生效；
`--default-thinking-budget` 是收口机制而非质量帽，必须与 max_tokens 配对
（预算 + 工具调用载荷 ≤ max_tokens，见 L27）。
```

---

## 7. 回归结果（对齐后）

### 7.1 端到端真实形状

预算 4096 @ max_tokens 16384：`finish_reason=tool_calls`，思考 4,121 字符，写出完整 HTML。

### 7.2 A7 复读锁死门禁

```
python3 scripts/91-repeat-lock-probe.py --ks 4,6,10 --rounds 4 --max-tokens 8192
```

⚠ **必须显式放大 `--max-tokens`**：预算 4096 时脚本默认的 900 会被思考吃光，测不出东西。

三次独立运行结果：

| run | K=4 | K=6 | K=10 |
|---|---|---|---|
| 1 | OK(read)/OK(bash)/OK(bash)/OK(read) | OK(read)/OK(bash)/OK(read)/OK(bash) | OK(bash)/OK(read)/OK(read)/OK(bash) |
| 2 | OK(read)/OK(bash)/OK(bash)/OK(bash) | OK(read)/OK(bash)/OK(bash)/OK(bash) | EDIT-OTHER/OK(bash)/OK(bash)/OK(read) |
| 3 | OK(read)/OK(bash)/OK(bash)/OK(bash) | OK(bash)/OK(read)/OK(bash)/OK(bash) | OK(read)/OK(bash)/OK(bash)/OK(bash) |

**三次独立运行、每次 3 个 K × 4 轮 = 36 轮，全部 `[PASS]`**（仅 run 2 的 K=10 首轮出现一次 `EDIT-OTHER`——那是模型改了**别的**字段，属正常策略调整，不是锁死）。

另外有一次 `--rounds 2` 的运行在 **K=4 第 1 轮** 判出 `LOCKED(byte-identical repeat)`，但**第 2 轮立刻恢复 `OK(bash)`**。

**判读**：这不是 L26 那种锁死（L26 现场是 43 次连续相同、永不恢复）。采样开起来后，偶发的单次重复属于抖动；**门禁的 per-round 二值判据在采样配置下偏严**——它把"是否曾经重复过一次"当成锁死，而真正的锁死签名是"**跨轮持续重复、且不恢复**"。这一点已记入 L27，门禁本身暂不改（改判据需要先积累更多采样态样本）。

---

## 8. 风险与回滚

| 风险 | 说明 | 回滚 |
|---|---|---|
| DSH `maxTokens 16384` 挤压输入上下文 | DSH 为输出预留的空间变大，可用输入变短（`contextWindow` 仍是 49152 硬上限） | 还原 `cordis.patch.yml.bak-20261007-145319-v100-align` |
| 思考预算 4096 在别的任务上可能仍不够 | 若某任务的工具调用载荷 > 12,000 token，仍会 malformed | 调低 `--default-thinking-budget`，或继续提高 DSH `maxTokens` |
| DSH 改动未生效 | 需重启 DSH / 新会话 | —— |
| 采样带来的不确定性 | `temperature 1.0` 下同一问题答案不固定 | 用 provider 的 `seed`（当前刻意不传 = fresh per request） |

**一键回滚部署态**：

```bash
cp -a /home/<user>/bonsai-ninfer-3060/config/runtime.env.bak-20261007-135617-v100-align \
      /home/<user>/bonsai-ninfer-3060/config/runtime.env
systemctl --user restart bonsai2-ninfer-3060.service
```

---

## 9. 对 V100 的反向收口（**已于 2026-10-07 完成**）

V100 的 DSH provider `v100-bonsai` 原本同样是 **`maxTokens: 8192` + 思考不限**（不传 `--reasoning-budget`，默认 -1）。§3.1 已实测：**V100 在这个组合下同样会零工具调用**。

也就是说，V100 "智力在线"是**采样参数的功劳，不是"不限思考"的功劳**。

现已按同一思路反向收口，并做了改前/改后实测（prompt 为"穷举 8 皇后全部 92 解并逐个验证"，刻意诱导长思考）：

| 阶段 | 引擎配置 | max_tokens | finish_reason | completion_tokens | 思考段字符 | 正文字符 | 耗时 |
|---|---|---|---|---|---|---|---|
| 改前 B1 | 无限思考 | 8192 | **length** | **8192** | 18913 | **0** | 115.2 s |
| 改前 B2 | 无限思考 | 32768 | **length** | **32768** | 26361 | 27173 | 545.8 s |
| 改后 A2 | `--reasoning-budget 8192` | 32768 | **stop** | 26392 | 16748 | **24017** | 416.3 s |
| 改后 A1 | `--reasoning-budget 8192` | 8192 | **length** | 8192 | 11129 | **0** | 115.5 s |

四条结论：
1. **无限思考下，给多少 `max_tokens` 就烧多少**：8192 → 正文 0 字符；32768 → 思考吃掉前约三分之一才开始写正文，正文又把剩下的烧完，仍是 `length`，而且单次 9.1 分钟。**只提高 `maxTokens` 不解决问题**，只会更慢。
2. `--reasoning-budget 8192` 生效：同样 32768 上限下，`finish_reason` 从 `length` 变成 **`stop`**，正文 **24017 字符**，端到端 416 s。
3. **预算必须与 `max_tokens` 配对**（A1）：预算 8192 而 `max_tokens` 也是 8192 时，预算本身就把额度吃光，仍然零输出。
4. 最终取值：`v100-bonsai` 引擎预算 **8192** + `maxTokens` **32768**（32768 = 3060 的 16384 的两倍，与 131072 窗口相称）；`timeoutMs` 300000→**900000**（实测 416 s，5 分钟墙会失败）。

**最直接的验收：复刻当初的故障形状。** §3.1 的原始故障是**零工具调用**（不是"回答很短"），所以最终验收不能只看"正文非空"。用新写的 `（本机工作目录，未发布）`（要求一次约 9 KB 载荷的 `write_file` 调用，写出一个"鹈鹕骑自行车"的 SVG 动画 HTML——正是当初那个 prompt 的形状）在收口后的引擎上跑：

| finish_reason | completion_tokens | thinking 字符 | tool_calls | 载荷字符 | 耗时 |
|---|---|---|---|---|---|
| **tool_calls** | 12722 | 20098 | 1（`write_file` → `/tmp/pelican.html`） | **9451** | 209.9 s |

→ **一次完整、载荷 9.4 KB 的工具调用**——这正是当初 8192 上限下发不出来的东西。

**同批处理的 `v100-qwen38`（另一个引擎、另一个二进制）**：

| | bonsai（prism 构建） | qwen38（v100-sm70 构建） |
|---|---|---|
| 二进制 | `（本机工作目录，未发布）`（0.2.0-dev / `6bfcd79`） | `（本机工作目录，未发布）`（`9611` / `02182fc5b`） |
| `--reasoning-effort` | ✅ 支持 | ❌ **不支持** |
| `--reasoning-budget` | ✅ 支持 | ✅ 支持 |

→ qwen38 脚本**只能**加 `--reasoning-budget 4096`，**不能**加 `--reasoning-effort`（加了起不来）。这是"照抄参数"最容易踩的坑：**同族、同厂的两个构建，能力集不同**——判断某个 flag 是否存在，必须对**那个构建自己的** `--help` 求证（本次还踩到 `grep -c -- "--flag"` 把 `--flag` 当选项解析而误报 0 的坑）。

回滚：`（本机工作目录，未发布）`、`start-v100-qwen38.sh.bak-20261007-162127-reasoning-budget`、`~/.dsh/profiles/web/cordis.patch.yml.bak-20261007-162329-v100-budget`。

---

## 10. 结论

1. **照抄采样参数是对的**，已落地：`--temperature 1.0 --top-p 0.95 --top-k 20 --default-reasoning-effort medium`，删除 `--greedy`。
2. **照抄"思考不限"做不到**：两端都会把 max_tokens 烧光在思考里、零工具调用。这不是 ninfer 缺陷。
3. `--default-thinking-budget` 的真实身份是**收口机制**，且**必须与 `max_tokens` 配对**：`预算 + 载荷 ≈ 6100 ≤ max_tokens`。
4. 采用档位 B：预算 4096 + DSH maxTokens 16384。
5. **真正让"智力在线"的是采样**，把 `--greedy` 换成 `temp 1.0` 才是有实质意义的改动——它给了模型随机逃逸路径，这正是 L26 复读锁死的解药。
6. **V100 已于同日按同一思路反向收口**（§9）：引擎加 `--reasoning-budget 8192`，DSH `v100-bonsai.maxTokens` 8192→32768、`timeoutMs` 300000→900000；实测 `finish_reason` 由 `length` 变 `stop`、正文非空。
