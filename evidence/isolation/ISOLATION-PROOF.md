# 隔离证明（ISOLATION PROOF）

生成时间：2026-10-07T03:59:14+0800
项目根：`/home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux`

**结论**：见文末。每条都有对应命令与证据文件。
## 1) 依赖层断言：没有脚本把 CUDA/动态库路径**赋值**为项目外
```
$ grep -rnE "(CUDA_HOME|CUDA_PATH|CUDA_ROOT|CUDACXX|CUDAToolkit_ROOT|LD_LIBRARY_PATH|PATH)=[\"?](/usr/local/cuda|\$HOME/cuda|~/cuda)" scripts/ config/ agent/ package/

```
- **PASS** —— 没有任何赋值把 CUDA/动态库路径指向项目外
## 1b) 禁用路径的文本清单（信息性；注释与存在性探测属正常）
- 命中 4 行，逐条列出供人工判断（本项不判 FAIL）：

```
/home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux/scripts/20-cuda-fetch.sh:12:# 不需要 sudo；不触碰 /usr/local/cuda*。
/home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux/scripts/00-baseline.sh:44:run_ok bash -c "ls -d /usr/local/cuda* 2>/dev/null || echo '(no /usr/local/cuda*)'"
/home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux/dist/0.1.0/porting/scripts/20-cuda-fetch.sh:12:# 不需要 sudo；不触碰 /usr/local/cuda*。
/home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux/dist/0.1.0/porting/scripts/00-baseline.sh:44:run_ok bash -c "ls -d /usr/local/cuda* 2>/dev/null || echo '(no /usr/local/cuda*)'"
```
## 2) 构建脚本的 CUDA 路径只能指向项目内
- **PASS** —— `config/env.sh` 里 `NINFER_CUDA_DIR="$STORE_TOOLCHAIN/cuda-$NINFER_CUDA_VERSION"`
- `scripts/50-build.sh` 显式 `export CUDA_HOME="$NINFER_CUDA_DIR"`（并先做构建期门禁）
## 3) 产物期门禁：readelf -d（RUNPATH）+ ldd（真实解析）
```
binary  = /home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux/.store/build/build-sm86/apps/ninfer-serve
RUNPATH = /home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux/.store/toolchain/cuda-13.1/lib
project = /home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux/.store/toolchain/cuda-13.1
- **PASS** —— RUNPATH 落在项目内
- **PASS** —— libcudart/libcublas/libnvjitlink 全部解析到项目内
- 白名单例外：`libcuda.so.1`（驱动加载器）来自系统属正常：
```
	libcuda.so.1 => /lib/x86_64-linux-gnu/libcuda.so.1 (0x00007c7a8d400000)
```
## 4) 源码树锁定且干净
```
HEAD     = 796f985007775f4bc7cfde53804fa22e7d60dbf8
pinned   = 796f985007775f4bc7cfde53804fa22e7d60dbf8
VERSION  = 0.12.0-rtx3090
dirty    = <clean>
```
- **PASS** —— HEAD 等于锁定 commit
- **PASS** —— 工作树干净（本轮零补丁，见 patches/README.md）
## 5) 模型 sha256 等于官方发布值
```
path   = /home/<user>/文档/deepseek-harness/default-workspace/bonsai2-ninfer-3060-agent-linux/.store/models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer
bytes  = 9520051456
sha256 = cdc4810b0ff17c40d0f62cf214b6e0bcd08346e9eb05ca53371507037793c14a
expect = cdc4810b0ff17c40d0f62cf214b6e0bcd08346e9eb05ca53371507037793c14a
```
- **PASS**
## 6) `~/.cache/ninfer/device-profiles.json` 未被读取/写入
```
path        = /home/<user>/.cache/ninfer/device-profiles.json
sha256 now  = 8df4a539eb3ef042f8e98c19266a2090dc9bfff959d9ad98f81b0faec6049087
sha256 base = 8df4a539eb3ef042f8e98c19266a2090dc9bfff959d9ad98f81b0faec6049087
mtime  now  = 2026-10-05 17:03:35.028956106 +0800
mtime  base = 2026-10-05 17:03:35.028956106 +0800
```
- **PASS** —— 外部 profile 未被读取也未被写入
## 结论
**全部通过。** 本项目的输入没有一条来自机器上既有的旧移植产物。

证据文件：`readelf-dyn.txt`、`ldd.txt`、`foreign-profile-baseline.txt`、`artefact-gate.txt`。
