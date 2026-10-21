#!/usr/bin/env bash
# snell-server 容器入口：
#   - 配置文件已存在：直接使用，忽略 SNELL_* 生成类变量；
#   - 配置文件不存在：根据环境变量生成，然后启动。
# 以 root 启动时会在完成文件准备后用 setpriv 降权到 PUID:PGID 运行。
set -euo pipefail

log()  { printf '[entrypoint] %s\n' "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

SNELL_CONFIG="${SNELL_CONFIG:-/etc/snell/snell-server.conf}"
SNELL_LOG_LEVEL="${SNELL_LOG_LEVEL:-notify}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# 拒绝任何控制字符（含 CR/LF），防止注入额外的配置行。
assert_no_ctrl() {
  local name="$1" value="$2"
  if [[ "$value" =~ [[:cntrl:]] ]]; then
    die "$name contains control characters (newline etc.), refusing."
  fi
}

[[ "$PUID" =~ ^[0-9]+$ ]] || die "PUID must be numeric"
[[ "$PGID" =~ ^[0-9]+$ ]] || die "PGID must be numeric"

case "$SNELL_LOG_LEVEL" in
  trace|verbose|notify|warning) ;;
  *) die "SNELL_LOG_LEVEL must be one of: trace, verbose, notify, warning" ;;
esac

random_psk() {
  # 只用字母数字，避免与 INI 注释符或客户端配置语法冲突。
  head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32
}

generate_config() {
  local psk="${SNELL_PSK:-}"
  local port="${SNELL_PORT:-7177}"
  local listen="${SNELL_LISTEN:-}"
  local mode="${SNELL_MODE:-default}"
  local dns="${SNELL_DNS:-}"
  local pref="${SNELL_DNS_IP_PREFERENCE:-default}"
  local egress="${SNELL_EGRESS_INTERFACE:-}"
  local psk_generated=0

  # 支持 Docker secrets：SNELL_PSK_FILE 指向一个只含 PSK 的文件。
  if [[ -z "$psk" && -n "${SNELL_PSK_FILE:-}" ]]; then
    [[ -r "$SNELL_PSK_FILE" ]] || die "SNELL_PSK_FILE is not readable: $SNELL_PSK_FILE"
    psk="$(head -c 4096 "$SNELL_PSK_FILE" | tr -d '\r\n')"
  fi

  if [[ -z "$psk" ]]; then
    psk="$(random_psk)"
    psk_generated=1
  fi

  for v in psk port listen mode dns pref egress; do
    assert_no_ctrl "$v" "${!v}"
  done

  # psk：长度 12-255，字符集收紧到不会被 INI 解析器误读的范围。
  (( ${#psk} >= 12 && ${#psk} <= 255 )) || die "SNELL_PSK length must be between 12 and 255."
  [[ "$psk" =~ ^[A-Za-z0-9._~+/=@:,!%^*()-]+$ ]] \
    || die "SNELL_PSK may only contain letters, digits and ._~+/=@:,!%^*()-"

  if [[ -z "$listen" ]]; then
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) \
      || die "SNELL_PORT must be an integer between 1 and 65535."
    listen="0.0.0.0:${port}"
  else
    local addr_re='(([0-9]{1,3}\.){3}[0-9]{1,3}|\[[0-9A-Fa-f:.]+\]):[0-9]{1,5}'
    [[ "$listen" =~ ^${addr_re}(,[[:space:]]*${addr_re})*$ ]] \
      || die "SNELL_LISTEN must look like 0.0.0.0:7177 or 0.0.0.0:7177,[::]:7177"
  fi

  case "$mode" in
    default|unshaped|unsafe-raw) ;;
    *) die "SNELL_MODE must be one of: default, unshaped, unsafe-raw" ;;
  esac
  if [[ "$mode" == "unsafe-raw" ]]; then
    log "WARNING: mode=unsafe-raw sends traffic UNENCRYPTED."
  fi

  case "$pref" in
    default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only) ;;
    *) die "SNELL_DNS_IP_PREFERENCE must be one of: default, prefer-ipv4, prefer-ipv6, ipv4-only, ipv6-only" ;;
  esac

  if [[ -n "$dns" ]]; then
    [[ "$dns" =~ ^[0-9A-Fa-f:.,[:space:]]+$ ]] \
      || die "SNELL_DNS must be a comma-separated list of IP addresses."
  fi
  if [[ -n "$egress" ]]; then
    [[ "$egress" =~ ^[A-Za-z0-9_.@-]{1,15}$ ]] \
      || die "SNELL_EGRESS_INTERFACE is not a valid interface name."
  fi

  local dir tmp
  dir="$(dirname "$SNELL_CONFIG")"
  mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.snell-server.conf.XXXXXX")"
  {
    echo "[snell-server]"
    echo "listen = ${listen}"
    echo "psk = ${psk}"
    echo "mode = ${mode}"
    echo "dns-ip-preference = ${pref}"
    if [[ -n "$dns" ]]; then echo "dns = ${dns}"; fi
    if [[ -n "$egress" ]]; then echo "egress-interface = ${egress}"; fi
  } > "$tmp"
  chmod 0600 "$tmp"
  if [[ "$(id -u)" == "0" ]]; then
    chown "${PUID}:${PGID}" "$tmp"
  fi
  mv -f "$tmp" "$SNELL_CONFIG"

  log "Generated ${SNELL_CONFIG} (listen=${listen}, mode=${mode})."
  if (( psk_generated )); then
    # 不把 PSK 打进日志；需要时到宿主机挂载目录里查看配置文件。
    log "SNELL_PSK was not set: a random PSK was written to the config file."
  fi
}

# 允许 `docker run image --help` / `-v` 之类直接透传给 snell-server。
if [[ $# -gt 0 && "$1" == -* && "$1" != "-c" ]]; then
  exec /usr/local/bin/snell-server "$@"
fi

if [[ -f "$SNELL_CONFIG" ]]; then
  log "Using existing config ${SNELL_CONFIG}; SNELL_* generation variables are ignored."
else
  log "Config ${SNELL_CONFIG} not found, generating from environment."
  generate_config
fi

cmd=(/usr/local/bin/snell-server -l "$SNELL_LOG_LEVEL" -c "$SNELL_CONFIG")

if [[ "$(id -u)" == "0" ]]; then
  # 降权后必须能读到配置文件；不擅自修改用户自己提供的文件的属主。
  if ! setpriv --reuid="$PUID" --regid="$PGID" --clear-groups test -r "$SNELL_CONFIG"; then
    die "uid ${PUID} cannot read ${SNELL_CONFIG}. Fix with: chown ${PUID}:${PGID} <file> (or set PUID/PGID)."
  fi
  exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups -- "${cmd[@]}"
fi

exec "${cmd[@]}"
