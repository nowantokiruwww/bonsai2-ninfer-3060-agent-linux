# ===========================================================================
#  bonsai2-ninfer-3060-agent-linux —— 运行镜像
# ===========================================================================
#
#  这个镜像里装的是"跑起来需要的一切"，但不装两样东西：
#
#    1) NVIDIA 内核态驱动 —— 驱动跑在宿主机内核里，容器不可能也不应该自带。
#       容器通过 nvidia-container-toolkit（推荐）或 docker/run.sh 的手工挂载
#       拿到 libcuda.so.1 与 /dev/nvidia*。
#
#    2) 9.5 GB 的模型权重 —— 烧进镜像会让它变成 12 GB 而且无法更新。
#       默认用 docker/run.sh 挂载宿主机的 models/ 目录；
#       确实想要一个自包含的胖镜像，就 `docker/build.sh --with-model`。
#
#  镜像里装的是引擎载荷（runtime/，2.6 GB，含自带的 CUDA 运行库）和全套
#  系统依赖库。后者不是手写的 —— 是从 `ldd runtime/bin/ninfer-serve` 反查出
#  来的 131 个 apt 包（见 docs/DOCKER.md「依赖是怎么算出来的」）。
#
#  构建：
#      ./docker/build.sh                      # 默认
#      ./docker/build.sh --base ubuntu:24.04  # 指定基座
#      ./docker/build.sh --with-model         # 把模型也烧进去（约 12 GB）
#
# ===========================================================================

ARG BASE=ubuntu:24.04
FROM ${BASE}

# 某些镜像站需要这个前缀，所以 BASE 用 ARG 而不是写死。
ARG DEBIAN_FRONTEND=noninteractive
# --with-model 时把 models/ 拷进镜像；默认不拷（.dockerignore 会挡住）
ARG WITH_MODEL=0

LABEL org.opencontainers.image.title="bonsai2-ninfer-3060-agent-linux" \
      org.opencontainers.image.description="Ternary-Bonsai-2-27B on a single RTX 3060 12GB: self-contained deployment with web console" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/nowantokiruwww/bonsai2-ninfer-3060-agent-linux"

# ---------------------------------------------------------------------------
# 1. 系统依赖
# ---------------------------------------------------------------------------
#
# 引擎不只是一段 CUDA 代码：它链了 ffmpeg（图像/音频预处理）、cairo + pango
# （渲染）、X11 客户端库、以及一大堆编解码器。缺任何一个都是
# "error while loading shared libraries"，而且报的是第一个缺的，要一个个试。
#
# 所以这里不手写猜测：这一串是 `ldd` 结果反查 dpkg 得到的**精确闭包**。
# 重新生成的方法写在 docs/DOCKER.md，升级引擎后应该重跑一次。
#
# 刻意排除 libnvidia-compute-580：那是宿主机驱动的用户态部分，
# 版本必须和宿主内核模块严格一致，只能运行时挂进来，不能从 apt 装。
RUN apt-get update && apt-get install -y --no-install-recommends \
      libc6 libgcc-s1 libstdc++6 \
      libaom3 libavcodec60 libavformat60 libavutil58 \
      libblkid1 libbluray2 libbrotli1 libbsd0 libbz2-1.0 \
      libcairo2 libcairo-gobject2 libchromaprint1 libcjson1 libcodec2-1.2 \
      libcom-err2 libcurl4t64 libdatrie1 libdav1d7 libdrm2 \
      libexpat1 libffi8 libfontconfig1 libfreetype6 libfribidi0 \
      libgcrypt20 libgdk-pixbuf-2.0-0 libglib2.0-0t64 libgme0 libgmp10 \
      libgnutls30t64 libgomp1 libgpg-error0 libgraphite2-3 libgsm1 \
      libgssapi-krb5-2 libharfbuzz0b libhogweed6t64 libhwy1t64 libicu74 \
      libidn2-0 libjpeg-turbo8 libjxl0.7 \
      libk5crypto3 libkeyutils1 libkrb5-3 libkrb5support0 \
      liblcms2-2 libldap2 liblzma5 \
      libmbedcrypto7t64 libmd0 libmount1 libmp3lame0 libmpg123-0t64 \
      libnettle8t64 libnghttp2-14 libnorm1t64 libnuma1 \
      libogg0 libopenjp2-7 libopenmpt0t64 libopus0 \
      libp11-kit0 libpango-1.0-0 libpangocairo-1.0-0 libpangoft2-1.0-0 \
      libpcre2-8-0 libpgm-5.3-0t64 libpixman-1-0 libpng16-16t64 libpsl5t64 \
      librabbitmq4 librav1e0 librist4 librsvg2-2 librtmp1 \
      libsasl2-2 libselinux1 libsharpyuv0 libshine3 libsnappy1v5 \
      libsodium23 libsoxr0 libspeex1 libsrt1.5-gnutls libssh-4 \
      libssh-gcrypt-4 libssl3t64 libsvtav1enc1d1 libswresample4 libswscale7 \
      libtasn1-6 libthai0 libtheora0 libtwolame0 libudfread0 libunistring5 \
      libva2 libva-drm2 libva-x11-2 libvdpau1 \
      libvorbis0a libvorbisenc2 libvorbisfile3 libvpl2 libvpx9 \
      libwebp7 libwebpmux3 libx11-6 libx11-xcb1 libx264-164 libx265-199 \
      libxau6 libxcb1 libxcb-dri3-0 libxcb-render0 libxcb-shm0 libxdmcp6 \
      libxext6 libxfixes3 libxml2 libxrender1 libxvidcore4 \
      libzmq5 libzstd1 libzvbi0t64 \
      ocl-icd-libopencl1 zlib1g \
      ca-certificates curl zstd python3 \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. 应用
# ---------------------------------------------------------------------------
WORKDIR /app
COPY . /app/

# config/runtime.env 是每台机器生成的（含 GPU UUID 与绝对路径），
# 由 entrypoint 在容器内生成，所以清掉构建上下文里可能带进来的那份。
RUN rm -f /app/config/runtime.env \
 && mkdir -p /app/logs /app/models /app/config \
 && chmod 755 /app/docker/entrypoint.sh /app/install.sh /app/*.sh /app/app/*.sh /app/scripts/*.sh 2>/dev/null || true

# --with-model=1 时断言模型真的进来了。
# 拷贝本身是上面那条 COPY 干的（docker/build.sh 会临时改写 .dockerignore
# 放行 models/，构建结束还原）；这里只做校验 —— 让"以为烤了其实没烤"
# 变成构建失败，而不是静默成功。
RUN if [ "$WITH_MODEL" = "1" ]; then \
      test -f /app/models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer \
        || { echo "错误：--with-model=1 但模型没进构建上下文，检查 .dockerignore"; exit 1; }; \
      echo "with-model: 模型已烘进镜像 ($(stat -c %s /app/models/Ternary-Bonsai-2-27B-ninfer-v3.ninfer) 字节)"; \
    else \
      echo "with-model: 不烘模型，运行时用 -v 挂载 models/"; \
    fi

# ---------------------------------------------------------------------------
# 3. 运行环境
# ---------------------------------------------------------------------------
# 引擎自带的 CUDA 运行库优先于任何系统库。
ENV LD_LIBRARY_PATH=/app/runtime/lib \
    CUDA_DEVICE_ORDER=PCI_BUS_ID \
    NINFER_DEVICE_PROFILES=/app/runtime/profiles/device-profiles.json \
    PYTHONUNBUFFERED=1 \
    CONTAINER=1

EXPOSE 8098 8099

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8098/v1/models >/dev/null || exit 1

ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["serve"]
