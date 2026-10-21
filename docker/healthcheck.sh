#!/usr/bin/env bash
# 读取配置中第一个 listen 地址，确认该 TCP 端口可以建立连接。
set -euo pipefail

conf="${SNELL_CONFIG:-/etc/snell/snell-server.conf}"
listen="$(sed -nE 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*([^,;#[:space:]]+).*/\1/p' "$conf" | head -n1)"
[[ -n "$listen" ]] || exit 1

port="${listen##*:}"
host="${listen%:*}"
host="${host#[}"; host="${host%]}"
case "$host" in
  0.0.0.0|"") host=127.0.0.1 ;;
  ::)         host=::1 ;;
esac

timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
