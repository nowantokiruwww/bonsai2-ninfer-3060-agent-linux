# patches/ — 我们对引擎源码做的改动

**当前状态：零改动。**

本项目在 `iamwavecut/ninfer-all @ 796f985007775f4bc7cfde53804fa22e7d60dbf8` 上
**没有修改任何源码**，因此 `patches/` 为空。这一点本身就是结论的一部分：

> 这条源码线**已经**具备 sm_86 在 Linux 上构建所需的一切：
> - `CMakeLists.txt:8-17` 的架构闸门接受 `86`（官方 `Neroued/ninfer` 只接受 `120a` 并 `FATAL_ERROR`）；
> - `CMakeLists.txt:214-215` 的 CUDA 地板是 `12.8`；
> - `src/ops/fp8_sm86_stubs.cpp` 已存在（对应 bench 记录里的"FP8 墙"坑）；
> - `t2_g128_fp16` 与 `hadamard_signs` 已实现（这是 v3 工件能加载的前提）；
> - `docs/rtx-3090-linux.md` 有 Linux sm_86 的原生构建指引。

也就是说，**"要改源码才能编"这件事在这条线上不成立**；上一次的失败不是"Linux 不兼容"，
而是引擎与其他 fork 的工件血缘错配（见 `PORTING-LEDGER.md` L01）。

## 如果我们将来必须改动

规则：

1. 每个改动一个 `.patch` 文件，文件名 `NNN-简短描述.patch`；
2. 用 `git -C <src> diff > patches/NNN-*.patch` 生成，**基于锁定的 commit**；
3. 交付前必须在**全新 clone** 上验证可重放：
   ```bash
   git -C <fresh-clone> apply --check patches/NNN-*.patch
   ```
4. 每个改动在 `PORTING-LEDGER.md` 里有一条对应记录，写清"不改会怎样"；
5. `MANIFEST.md` 记录 base commit 与每个补丁的 sha256。

## 注意：构建期的"不改源码"≠"不改环境"

本项目对**环境**做了大量约束（两道硬门禁），这些不是源码补丁：

- **污染门禁**：构建期断言所有 CUDA 环境变量与 `PATH`/`LD_LIBRARY_PATH` 都指向项目内；
  产物期用 `readelf -d`（RUNPATH）+ `ldd`（真实解析）双重确认。
- **profile 门禁**：强制 `NINFER_DEVICE_PROFILES` 指向项目内，并断言
  `~/.cache/ninfer/device-profiles.json` 整轮实验未被读/写。

这两条取代了"打补丁硬编码路径"的做法——不碰源码也能保证构建是自包含的。
