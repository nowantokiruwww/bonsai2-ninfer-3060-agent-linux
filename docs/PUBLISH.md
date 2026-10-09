# 发布门禁：这个 Release 是怎么被证明可用的

对外发布之前，下面 12 条必须全部为真。**任何一条不 PASS 就不发布。**
这些门禁不是形式：每一条都来自一次真实事故（见括号里的病历编号）。

| # | 门禁 | 命令 | 期望 |
|---|---|---|---|
| 1 | 隔离证明 | `bash scripts/build/85-isolation-proof.sh` | readelf RUNPATH 落在项目内；ldd 解析的 CUDA 库全部在项目内（只有 `libcuda.so.1` 来自驱动）；外部 profile 未被读写（L02/L22） |
| 2 | 产物是 sm_86 | `cuobjdump -lelf runtime/bin/ninfer-serve` | 列出 `sm_86.cubin`（不是 sm_120a，不是只有 PTX）（L16） |
| 3 | 源码血缘 | `git -C .store/src/ninfer-all rev-parse HEAD` | 等于 `config/env.sh` 里的 `NINFER_SRC_COMMIT`，且工作树干净（L01） |
| 4 | 模型哈希 | `sha256sum models/*.ninfer` | `cdc4810b0ff17c40d0f62cf214b6e0bcd08346e9eb05ca53371507037793c14a`，9,520,051,456 B（L01） |
| 5 | flag 对账 | `bash scripts/build/55-flag-diff.sh` | 静态 flag 面与运行时实际接受一致；参照线那条命令的 12 个 flag 在本线全部存在（L17） |
| 6 | 28-SM 标定 | `bash scripts/build/70-calibrate.sh` | profile 里 `multiprocessors=28`、`hardware_class=nvidia-geforce-rtx-3060-sm86`（L09） |
| 7 | KV 实测 | `bash scripts/build/75-kv-gate.sh` | 实测最大稳定容量 —— **不是常数**，随桌面显存占用变化（L08/L21） |
| 8 | agent 验收 | `bash scripts/build/90-agent-accept.sh all` | `results/agent-*.json`：50/50 轮工具调用、单步 <0.5 s、显存零增长（A1–A8） |
| 9 | 正确性控制 | `bash scripts/build/90-agent-accept.sh correctness` | **两臂各自可复现**；两臂是否逐字节相同**如实记录** —— 判据不是 `lossless=true`（见下） |
| 10 | 复读锁死探针 | `python3 scripts/build/91-repeat-lock-probe.py --ks 4,6,10 --rounds 4 --max-tokens 8192` | 无"连续 ≥3 轮不恢复"的真锁死；**单次 FAIL 不足以否决**（L26/L28） |
| 11 | 身份清单 | `bash scripts/build/95-manifest.sh` | `evidence/MANIFEST.md` 生成，输入/产物哈希齐全 |
| 12 | 仓库自包含 | `bash scripts/verify.sh` | 130 项全 PASS：README 里的每条命令存在、每个被引用的路径存在、没有本机绝对路径、没有身份标识 |

## 第 9 条的重要更正

早期版本写的是"correctness 的 `lossless` 必须为 true" —— **那是错的**。

控制实验（每臂同 prompt 连发 3 次）证明两臂**各自完全可复现**，但在复读密集内容之外，
两臂输出**不一致**。所以正确的判据是**「各自可复现 + 分歧如实记录」**，而不是"必须无损"。

推论：**要逐字节可复现（回归/审计）用基线臂（不挂 `--spec`）；追吞吐才用投机臂。**

## 第 12 条为什么单独存在

上一代工程退役的直接原因就是这一条不成立：它的 README 写着 `bash scripts/build/80-serve.sh`（当时在 `scripts/`，现在在 `scripts/build/`）
和 `bash <部署根>/serve.sh`（部署根在仓库外），前者依赖被 `.gitignore` 掉的 `.store/`，
后者在仓库外 —— **别人 clone 下来一行都跑不了**。

一个仓库如果要求读者先拥有作者本机的那套东西，它就不是一个仓库。
所以 `verify.sh` 把"自包含"写成可执行断言，而不是写成一句承诺。

## 载荷为什么分卷

引擎载荷压缩后 **2.06 GiB**，而 GitHub Release 附件单文件上限是 **2 GiB**。
切成 `part1`（1.46 GiB）+ `part2`（582 MiB），`fetch-runtime.sh` 拼回整包并校验整包 sha256。
分卷只是托管绕开手段，**没有删掉任何东西**。

## 明确不发什么

- **模型权重**（9.5 GB）：不进 git（单文件 100 MB 上限），也不塞进 Release；
  由 `fetch-model.sh` 从 HF 镜像按 sha256 校验下载。
- **驱动**：从宿主机来，容器/载荷都不带。
- **编译器**：载荷是产物，不是构建环境。要自己编译，见 [`docs/BUILD.md`](BUILD.md)。
- **任何指向作者本机的绝对路径或身份标识**：见 [`docs/PRIVACY.md`](PRIVACY.md)。

## 关于 CI（为什么没有 badge）

第 12 条门禁本身是可执行的，但目前**没有自动跑**：GitHub 不允许任何 Personal Access Token
创建或更新 `.github/workflows/*` 文件（需要 `workflow` 权限，而临时 token 只有 `repo` 权限）。

所以 workflow 文件放在 `scripts/ci/verify.yml`，内容就是一行 `bash scripts/verify.sh`。
想启用 CI，两步：

```bash
mkdir -p .github/workflows
cp scripts/ci/verify.yml .github/workflows/verify.yml
git add .github && git commit -m "enable self-containment CI" && git push
```

启用后 README 顶部加徽章：

```markdown
[![仓库自检](https://github.com/<owner>/<repo>/actions/workflows/verify.yml/badge.svg)](https://github.com/<owner>/<repo>/actions/workflows/verify.yml)
```
