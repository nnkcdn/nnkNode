#!/bin/sh
# ---------------------------------------------------------------------------
# Coolify / Docker 健康检查
#   1) 进程必须存活 (非崩溃循环)
#   2) 可选: 若设置 HEALTHCHECK_PORT, 探测该 TCP 端口是否在监听
# 退出码 0 = healthy, 非 0 = unhealthy
# ---------------------------------------------------------------------------
pidof nanako-node >/dev/null 2>&1 || { echo "unhealthy: nanako-node 进程未运行"; exit 1; }

if [ -n "${HEALTHCHECK_PORT:-}" ]; then
  nc -z 127.0.0.1 "$HEALTHCHECK_PORT" >/dev/null 2>&1 \
    || { echo "unhealthy: 端口 $HEALTHCHECK_PORT 未监听"; exit 1; }
fi

echo "healthy"
exit 0
