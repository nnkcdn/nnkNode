#!/bin/sh
# ---------------------------------------------------------------------------
# Nanako 节点后端 entrypoint
# 把环境变量渲染成 V2bX 的 config.json, 然后启动 server.
# 所有参数都通过环境变量传入 —— 适配 Coolify 的环境变量面板.
# ---------------------------------------------------------------------------
set -eu

CONFIG_DIR=/etc/nanako-node
CONFIG_FILE="$CONFIG_DIR/config.json"
mkdir -p "$CONFIG_DIR/cert"

# 运维子命令直通: `docker run ... version` / `x25519` 等
case "${1:-}" in
  ""|server) : ;;
  *) exec nanako-node "$@" ;;
esac

# ── 逃生通道: 直接提供整份 config.json (高级多节点/多核场景) ──
if [ -n "${CONFIG_JSON:-}" ]; then
  printf '%s' "$CONFIG_JSON" > "$CONFIG_FILE"
  echo "[entrypoint] 使用 CONFIG_JSON 提供的完整配置"
  exec nanako-node server -c "$CONFIG_FILE"
fi

# ── 必填校验 ──
: "${API_HOST:?必须设置 API_HOST (面板地址, 如 https://panel.example.com)}"
: "${API_KEY:?必须设置 API_KEY (节点通信密钥)}"
: "${NODE_ID:?必须设置 NODE_ID (节点ID, 数字)}"
: "${NODE_TYPE:?必须设置 NODE_TYPE (vmess/vless/trojan/shadowsocks/hysteria2/tuic)}"
case "$NODE_ID" in ''|*[!0-9]*) echo "[entrypoint] NODE_ID 必须是数字: $NODE_ID"; exit 1 ;; esac

# ── 默认值 ──
LOG_LEVEL="${LOG_LEVEL:-info}"
CORE_TYPE="$(printf '%s' "${CORE_TYPE:-xray}" | tr '[:upper:]' '[:lower:]')"
API_TIMEOUT="${API_TIMEOUT:-30}"
LISTEN_IP="${LISTEN_IP:-0.0.0.0}"
SEND_IP="${SEND_IP:-0.0.0.0}"
DEVICE_ONLINE_MIN_TRAFFIC="${DEVICE_ONLINE_MIN_TRAFFIC:-100}"
REPORT_MIN_TRAFFIC="${REPORT_MIN_TRAFFIC:-0}"
CERT_MODE="${CERT_MODE:-none}"
CERT_DOMAIN="${CERT_DOMAIN:-}"
CERT_FILE="${CERT_FILE:-$CONFIG_DIR/cert/fullchain.cer}"
CERT_KEY_FILE="${CERT_KEY_FILE:-$CONFIG_DIR/cert/private.key}"
CERT_PROVIDER="${CERT_PROVIDER:-}"
CERT_EMAIL="${CERT_EMAIL:-}"
REJECT_UNKNOWN_SNI="${REJECT_UNKNOWN_SNI:-false}"
DNS_SERVERS="${DNS_SERVERS:-}"

# ── DNS 配置 (按内核生成对应格式) ──
if [ -n "$DNS_SERVERS" ]; then
  DNS_DIR="$CONFIG_DIR/dns"
  mkdir -p "$DNS_DIR"
  case "$CORE_TYPE" in
    xray)
      # xray DNS 格式: {"servers":["8.8.8.8","1.1.1.1"],"tag":"dns_inbound"}
      XRAY_DNS_FILE="$DNS_DIR/dns.json"
      printf '%s' "$DNS_SERVERS" | tr ',' '\n' | jq -R . | jq -s '{servers:.,tag:"dns_inbound"}' > "$XRAY_DNS_FILE"
      echo "[entrypoint] 已生成 xray DNS 配置: $DNS_SERVERS"
      ;;
    sing)
      # sing-box OriginalPath 格式: 完整 options, 只填 dns 段
      # 支持: 纯 IP (自动加 udp://) 或带协议前缀 (https:// tls:// quic:// tcp:// udp://)
      # DoH/DoT/DoQ 含域名时自动添加 bootstrap resolver (udp://8.8.8.8)
      SING_DNS_FILE="$DNS_DIR/sing-dns.json"
      need_bootstrap=0
      printf '%s' "$DNS_SERVERS" | tr ',' '\n' | while IFS= read -r addr; do
        case "$addr" in https://*|tls://*|quic://*) need_bootstrap=1 ;; esac
      done
      # 重新检测 (subshell 变量不传递)
      case "$DNS_SERVERS" in *https://*|*tls://*|*quic://*) need_bootstrap=1 ;; *) need_bootstrap=0 ;; esac

      printf '%s' "$DNS_SERVERS" | tr ',' '\n' | while IFS= read -r addr; do
        case "$addr" in
          https://*|tls://*|quic://*|tcp://*|udp://*) printf '%s\n' "$addr" ;;
          *) printf 'udp://%s\n' "$addr" ;;
        esac
      done | jq -R '{ tag: ("dns-\(input_line_number)"), address: . }' | \
        if [ "$need_bootstrap" = "1" ]; then
          jq -s 'map(. + (if (.address | test("^(https|tls|quic)://")) then {address_resolver:"dns-bootstrap"} else {} end))
                  + [{tag:"dns-bootstrap",address:"udp://8.8.8.8"}]
                  | {dns:{servers:.,rules:[],independent_cache:true}}'
        else
          jq -s '{dns:{servers:.,rules:[],independent_cache:true}}'
        fi > "$SING_DNS_FILE"
      echo "[entrypoint] 已生成 sing DNS 配置: $DNS_SERVERS (bootstrap=$need_bootstrap)"
      ;;
  esac
fi

# ── 内核对象 ──
case "$CORE_TYPE" in
  xray)
    if [ -n "$DNS_SERVERS" ]; then
      core=$(jq -n --arg lvl "${XRAY_LOG_LEVEL:-warning}" --arg dp "$XRAY_DNS_FILE" \
        '{Type:"xray", Log:{Level:$lvl}, AssetPath:"/usr/share/nanako-node/", DnsConfigPath:$dp}')
    else
      core=$(jq -n --arg lvl "${XRAY_LOG_LEVEL:-warning}" \
        '{Type:"xray", Log:{Level:$lvl}, AssetPath:"/usr/share/nanako-node/"}')
    fi ;;
  sing)
    if [ -n "$DNS_SERVERS" ]; then
      core=$(jq -n --arg lvl "${SING_LOG_LEVEL:-error}" --arg op "$SING_DNS_FILE" \
        '{Type:"sing", Log:{Level:$lvl, Timestamp:true}, OriginalPath:$op}')
    else
      core=$(jq -n --arg lvl "${SING_LOG_LEVEL:-error}" \
        '{Type:"sing", Log:{Level:$lvl, Timestamp:true}}')
    fi ;;
  hysteria2)
    core=$(jq -n '{Type:"hysteria2"}') ;;
  *) echo "[entrypoint] 未知 CORE_TYPE=$CORE_TYPE (应为 xray/sing/hysteria2)"; exit 1 ;;
esac

# ── 证书对象 ──
cert=$(jq -n \
  --arg mode "$CERT_MODE" \
  --argjson reject "$REJECT_UNKNOWN_SNI" \
  --arg domain "$CERT_DOMAIN" \
  --arg cf "$CERT_FILE" \
  --arg kf "$CERT_KEY_FILE" \
  --arg prov "$CERT_PROVIDER" \
  --arg email "$CERT_EMAIL" \
  '{CertMode:$mode, RejectUnknownSni:$reject, CertDomain:$domain, CertFile:$cf, KeyFile:$kf}
   + (if $prov  != "" then {Provider:$prov}  else {} end)
   + (if $email != "" then {Email:$email}    else {} end)')

# ── 收集 DNSENV_* 前缀变量 → DNSEnv (DNS-01 自动签发) ──
# 例: DNSENV_CF_DNS_API_TOKEN=xxx  →  DNSEnv.CF_DNS_API_TOKEN=xxx
dnsenv=$(jq -n '{}'); has_dnsenv=0
while IFS='=' read -r k v; do
  case "$k" in
    DNSENV_*) name="${k#DNSENV_}"
      dnsenv=$(printf '%s' "$dnsenv" | jq --arg k "$name" --arg v "$v" '. + {($k):$v}')
      has_dnsenv=1 ;;
  esac
done <<EOF
$(env)
EOF
if [ "$has_dnsenv" = "1" ]; then
  cert=$(printf '%s' "$cert" | jq --argjson d "$dnsenv" '. + {DNSEnv:$d}')
fi

# ── 节点对象 ──
node=$(jq -n \
  --arg core "$CORE_TYPE" \
  --arg host "$API_HOST" \
  --arg key "$API_KEY" \
  --argjson id "$NODE_ID" \
  --arg ntype "$NODE_TYPE" \
  --argjson timeout "$API_TIMEOUT" \
  --arg listen "$LISTEN_IP" \
  --arg send "$SEND_IP" \
  --argjson devmin "$DEVICE_ONLINE_MIN_TRAFFIC" \
  --argjson repmin "$REPORT_MIN_TRAFFIC" \
  --argjson cert "$cert" \
  '{Core:$core, ApiHost:$host, ApiKey:$key, NodeID:$id, NodeType:$ntype,
    Timeout:$timeout, ListenIP:$listen, SendIP:$send,
    DeviceOnlineMinTraffic:$devmin, ReportMinTraffic:$repmin, CertConfig:$cert}')

# ── 组装并写入 ──
jq -n --arg lvl "$LOG_LEVEL" --argjson core "$core" --argjson node "$node" \
  '{Log:{Level:$lvl, Output:""}, Cores:[$core], Nodes:[$node]}' > "$CONFIG_FILE"

echo "[entrypoint] 已生成配置 (core=$CORE_TYPE, node_type=$NODE_TYPE, node_id=$NODE_ID, cert=$CERT_MODE)"
exec nanako-node server -c "$CONFIG_FILE"
