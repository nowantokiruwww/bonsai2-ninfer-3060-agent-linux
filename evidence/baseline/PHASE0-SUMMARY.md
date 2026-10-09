# Phase 0 摘要

- 若上面 nvidia-smi 成功，说明这台机器**不是**空白 Ubuntu：驱动已存在。
- 本项目在既有机器上的执行方式：所有构建输入仍走项目自带路径（见 config/env.sh），
  并用 evidence/isolation/ 证明没有使用机器上既有的 CUDA / NInfer 产物。
- 在真正重装的空白 Ubuntu 上，本脚本的 nvidia-smi / nvcc / ~/.cache/ninfer 三项应全部为缺失。
