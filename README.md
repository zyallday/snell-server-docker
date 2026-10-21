# snell-server (Docker)

基于官方二进制的 Snell v6 服务端 Docker 部署。

- 多架构：`linux/amd64`、`linux/arm64`、`linux/386`（对应官方 amd64 / aarch64 / i386 包）
- 构建时按 sha256 校验官方 zip
- 两种配置方式：挂载现成的 `snell-server.conf`，或在配置文件不存在时由环境变量生成
- snell 以非 root（默认 1000:1000）运行，容器只读根文件系统、`cap_drop: ALL`

## 快速开始

```bash
cp .env.example .env      # 按需修改；SNELL_PSK 留空会自动生成
docker compose up -d --build
make psk                  # 查看 PSK（读取 config/snell-server.conf）
```

Surge 客户端示例：

```ini
[Proxy]
MySnell = snell, <服务器IP>, 7177, psk=<PSK>, version=6
```

> `mode` 不是 `default` 时，客户端需配置相同的 mode（以 Surge 文档为准）。

## 配置方式

启动时 entrypoint 检查 `./config/snell-server.conf`（容器内 `/etc/snell/snell-server.conf`）：

| 情况 | 行为 |
|---|---|
| 文件存在 | 直接使用，**忽略** 下表中的生成变量 |
| 文件不存在 | 根据环境变量生成该文件（权限 600），再启动 |

生成后的文件会保留在 `./config/`，之后重启都使用它。修改环境变量后想重新生成，删掉该文件再 `docker compose up -d` 即可。

### 方式一：挂载配置文件

```bash
cp config/snell-server.conf.example config/snell-server.conf
# 编辑 psk / listen 等
sudo chown 1000:1000 config/snell-server.conf   # 或在 .env 中设置 PUID/PGID 为文件属主
```

容器端口映射使用 `SNELL_PORT`，需与文件中 `listen` 的端口一致。

### 方式二：环境变量生成

| 变量 | 默认值 | 对应配置项 / 说明 |
|---|---|---|
| `SNELL_PSK` | 随机 32 位 | `psk`，12–255 位，仅允许字母数字和 `._~+/=@:,!%^*()-` |
| `SNELL_PSK_FILE` | – | 从文件读取 PSK（可配合 Docker secrets），`SNELL_PSK` 为空时生效 |
| `SNELL_PORT` | `7177` | 生成 `listen = 0.0.0.0:<port>`，同时用于端口映射 |
| `SNELL_LISTEN` | – | 覆盖 `listen`，如 `0.0.0.0:7177,[::]:7177` |
| `SNELL_MODE` | `default` | `default` / `unshaped` / `unsafe-raw` |
| `SNELL_DNS` | – | `dns`，逗号分隔的 IP |
| `SNELL_DNS_IP_PREFERENCE` | `default` | `default` / `prefer-ipv4` / `prefer-ipv6` / `ipv4-only` / `ipv6-only` |
| `SNELL_EGRESS_INTERFACE` | – | `egress-interface` |

所有值都会先校验（拒绝换行等控制字符、枚举白名单），不合法时容器直接退出并给出原因。

### 始终生效的变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SNELL_LOG_LEVEL` | `notify` | `trace` / `verbose` / `notify` / `warning` |
| `PUID` / `PGID` | `1000` | 运行 snell 的用户，需能读取配置文件 |

## 多架构构建

`docker compose build` 只构建本机架构。要构建多架构镜像并推送到仓库：

```bash
make buildx-push IMAGE=ghcr.io/<you>/snell-server
```

然后在 `.env` 里设置 `SNELL_IMAGE=ghcr.io/<you>/snell-server`，在目标机器上 `docker compose pull && docker compose up -d`。

升级 Snell 版本时，修改 `SNELL_VERSION`，并更新 `Dockerfile` 中三个 `SHA256_*`：

```bash
for a in amd64 i386 aarch64; do
  curl -fsSLO https://dl.nssurge.com/snell/snell-server-v<ver>-linux-$a.zip
done
shasum -a 256 snell-server-v<ver>-linux-*.zip
```

## 注意事项

- **只需 TCP 端口**：v6 移除了 QUIC Proxy Mode，UDP 走 TCP 中转。
- **IPv6**：默认 bridge 网络通常没有 IPv6。需要 IPv6 入站或出站时，建议使用 `network_mode: host`（同时删除 `ports`）。
- **端口 < 1024**：snell 以非 root 运行，无法绑定特权端口。可以在宿主机映射成小端口（如 `443:7177`），或使用 host 网络并设置 `sysctl net.ipv4.ip_unprivileged_port_start`。
- **egress-interface**：绑定网卡在部分内核上需要 `CAP_NET_RAW`，而当前降权后的进程不带任何 capability。使用前请先实测；如果需要，得在 entrypoint 里通过 setpriv 授予 ambient capability。
- **unsafe-raw** 为明文传输，只应在可信网络或已加密的隧道内使用。
- Snell v6 官方仍标注为 beta。
