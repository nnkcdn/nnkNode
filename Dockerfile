# syntax=docker/dockerfile:1
###############################################################################
# Nanako 节点后端 (V2bX 多核: xray + sing-box + hysteria2)
# 全参数环境变量化 · Coolify 友好 · 多架构预编译 (linux/amd64 + linux/arm64)
#
# 重: Go 编译用 BUILDPLATFORM 原生交叉编译 (快), 仅运行层在目标架构上跑.
###############################################################################

# ---------- build stage (原生交叉编译, 不走 QEMU) ----------
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS builder
ARG TARGETOS
ARG TARGETARCH
WORKDIR /app
RUN apk add --no-cache git
COPY src/go.mod src/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    GOEXPERIMENT=jsonv2 go mod download
COPY src/ .
# 全核标签 (与上游官方一致). 内存极小的构建机可删 with_gvisor with_wireguard.
ARG BUILD_TAGS="sing xray hysteria2 with_quic with_grpc with_utls with_wireguard with_acme with_gvisor"
ARG VERSION=nanako
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH GOEXPERIMENT=jsonv2 \
    go build -v -trimpath \
      -tags "${BUILD_TAGS}" \
      -ldflags "-X 'github.com/InazumaV/V2bX/cmd.version=${VERSION}' -s -w -buildid=" \
      -o /out/nanako-node

# ---------- geo stage (下载 geoip/geosite, 架构无关, 跑在构建机原生架构) ----------
FROM --platform=$BUILDPLATFORM alpine AS geo
RUN apk add --no-cache wget ca-certificates
WORKDIR /geo
RUN set -eux; \
    ok=0; \
    for i in 1 2 3; do \
      if wget -q -O geoip.dat   https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat && \
         wget -q -O geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat && \
         wget -q -O geoip.db    https://github.com/SagerNet/sing-geoip/releases/latest/download/geoip.db && \
         wget -q -O geosite.db  https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite.db; then ok=1; break; fi; \
      echo "geo 下载重试 ($i)"; sleep 3; \
    done; \
    [ "$ok" = "1" ]

# ---------- runtime stage (目标架构) ----------
FROM alpine
RUN apk add --no-cache tzdata ca-certificates jq netcat-openbsd \
    && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && mkdir -p /etc/nanako-node/cert /usr/share/nanako-node
COPY --from=geo     /geo/                       /usr/share/nanako-node/
COPY --from=builder /out/nanako-node            /usr/local/bin/nanako-node
COPY docker-entrypoint.sh                        /usr/local/bin/docker-entrypoint.sh
COPY healthcheck.sh                              /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/healthcheck.sh
WORKDIR /etc/nanako-node

# Coolify / Docker 原生健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
