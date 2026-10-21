# syntax=docker/dockerfile:1

# 官方二进制动态链接 glibc，不能用 alpine。
ARG DEBIAN_IMAGE=debian:bookworm-slim

# ---------- 下载阶段：在构建机原生架构上运行，按目标架构挑选安装包 ----------
FROM --platform=$BUILDPLATFORM ${DEBIAN_IMAGE} AS downloader

ARG TARGETARCH
ARG SNELL_VERSION=6.0.0
# 每个架构的官方 zip 的 sha256；升级版本时一起更新。
ARG SHA256_AMD64=8a9c4463ca87cfa5eaa37c6af0d37ab93ea275aa12391985bb2a375ca3abd7f2
ARG SHA256_386=67060ef79ac4ef0bb64c520302396620b3a06f8f6d5ceb450be283e4fa749335
ARG SHA256_ARM64=a0b2915cbc77dc3baf8fa069e741c20808d8a10c3a8a93e709a0a580645c3bd7

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/snell
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) pkg=amd64;   sum="${SHA256_AMD64}" ;; \
      386)   pkg=i386;    sum="${SHA256_386}" ;; \
      arm64) pkg=aarch64; sum="${SHA256_ARM64}" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${pkg}.zip"; \
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 -o snell.zip "${url}"; \
    echo "${sum}  snell.zip" | sha256sum -c -; \
    unzip -q snell.zip snell-server; \
    install -m 0755 snell-server /out-snell-server

# ---------- 运行阶段 ----------
FROM ${DEBIAN_IMAGE}

ARG SNELL_VERSION=6.0.0
LABEL org.opencontainers.image.title="snell-server" \
      org.opencontainers.image.version="${SNELL_VERSION}" \
      org.opencontainers.image.description="Snell proxy server (official binary from nssurge.com)"

# libstdc++6 是运行依赖；util-linux 提供 setpriv，用于以 root 修正目录权限后降权运行；
# curl / unzip / ca-certificates 用于 SNELL_BIN_URL 启动时下载新版本。
RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 util-linux ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 1000 snell \
 && useradd --system --uid 1000 --gid snell --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin snell \
 && mkdir -p /etc/snell /var/lib/snell

COPY --from=downloader /out-snell-server /usr/local/bin/snell-server
COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 docker/healthcheck.sh /usr/local/bin/healthcheck.sh

# 构建时确认二进制能在目标架构上加载（缺库会在这里失败）。
RUN /usr/local/bin/snell-server -v

ENV SNELL_CONFIG=/etc/snell/snell-server.conf
VOLUME ["/etc/snell"]
EXPOSE 7177/tcp

# start-period 留出 SNELL_BIN_URL 下载的时间。
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
