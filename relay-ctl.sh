#!/bin/bash
# ---------------------------------------------------------------------------
# relay-ctl.sh — iptables 端口中转管理
# 把本机端口的 TCP/UDP 流量通过 DNAT 转发到目标服务器
# 适用于代理节点中转场景 (VLESS/AnyTLS/Hysteria2 等)
# ---------------------------------------------------------------------------
set -euo pipefail

CONF_DIR="/etc/relay-ctl"
CONF_FILE="$CONF_DIR/rules.conf"
SYSCTL_FILE="/etc/sysctl.d/99-relay-ctl.conf"
SERVICE_NAME="relay-ctl-restore"
SCRIPT_PATH="$(readlink -f "$0")"

# ── 基础检查 ──

check_root() {
  [ "$(id -u)" -eq 0 ] || { echo "[错误] 请用 root 运行此脚本"; exit 1; }
}

ensure_forward() {
  local cur
  cur=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
  if [ "$cur" != "1" ]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo "[信息] 已开启 ip_forward"
  fi
  if [ ! -f "$SYSCTL_FILE" ] || ! grep -q "ip_forward" "$SYSCTL_FILE" 2>/dev/null; then
    mkdir -p "$(dirname "$SYSCTL_FILE")"
    echo "net.ipv4.ip_forward = 1" > "$SYSCTL_FILE"
  fi
}

ensure_config() {
  mkdir -p "$CONF_DIR"
  if [ ! -f "$CONF_FILE" ]; then
    printf '# relay-ctl rules\n# ID:LOCAL_PORT:RESOLVED_IP:TARGET_PORT:PROTOCOL:ORIGINAL_HOST\n' > "$CONF_FILE"
  fi
}

# ── 配置读写 (原子写入) ──

read_rules() {
  grep -v '^#' "$CONF_FILE" 2>/dev/null | grep -v '^$' || true
}

save_config() {
  local tmp="$CONF_FILE.tmp.$$"
  printf '# relay-ctl rules\n# ID:LOCAL_PORT:RESOLVED_IP:TARGET_PORT:PROTOCOL:ORIGINAL_HOST\n' > "$tmp"
  printf '%s\n' "$1" >> "$tmp"
  mv -f "$tmp" "$CONF_FILE"
}

next_id() {
  local max=0 id
  while IFS=: read -r id _ _ _ _ _; do
    [ "$id" -gt "$max" ] 2>/dev/null && max="$id"
  done <<EOF
$(read_rules)
EOF
  echo $((max + 1))
}

# ── 输入校验 ──

resolve_host() {
  local host="$1"
  if echo "$host" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    local IFS='.'; set -- $host
    for octet in "$@"; do
      [ "$octet" -le 255 ] 2>/dev/null || { echo "[错误] 无效 IP: $host" >&2; return 1; }
    done
    echo "$host"; return 0
  fi
  if ! echo "$host" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$'; then
    echo "[错误] 无效地址: $host" >&2; return 1
  fi
  local resolved
  resolved=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}') \
    || resolved=$(dig +short "$host" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1) \
    || resolved=""
  if [ -z "$resolved" ]; then
    echo "[错误] 无法解析域名: $host" >&2; return 1
  fi
  echo "[信息] $host → $resolved" >&2
  echo "$resolved"
}

validate_port() {
  local p="$1"
  case "$p" in ''|*[!0-9]*) echo "[错误] 端口必须是数字: $p"; return 1 ;; esac
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { echo "[错误] 端口范围 1-65535: $p"; return 1; }
}

validate_proto() {
  case "$1" in tcp|udp|both) ;; *) echo "[错误] 协议须为 tcp/udp/both: $1"; return 1 ;; esac
}

# ── iptables 操作 ──

apply_one() {
  local proto="$1" lport="$2" tip="$3" tport="$4" rid="$5"
  iptables -t nat -A PREROUTING  -p "$proto" --dport "$lport" \
    -j DNAT --to-destination "${tip}:${tport}" \
    -m comment --comment "relay-ctl:${rid}" || return 1
  if ! iptables -t nat -A POSTROUTING -p "$proto" -d "$tip" --dport "$tport" \
    -j MASQUERADE -m comment --comment "relay-ctl:${rid}"; then
    iptables -t nat -D PREROUTING -p "$proto" --dport "$lport" \
      -j DNAT --to-destination "${tip}:${tport}" \
      -m comment --comment "relay-ctl:${rid}" 2>/dev/null
    return 1
  fi
}

apply_iptables() {
  local proto="$1" lport="$2" tip="$3" tport="$4" rid="$5"
  if [ "$proto" = "both" ]; then
    apply_one tcp "$lport" "$tip" "$tport" "$rid" && \
    apply_one udp "$lport" "$tip" "$tport" "$rid"
  else
    apply_one "$proto" "$lport" "$tip" "$tport" "$rid"
  fi
}

remove_iptables() {
  local rid="$1" chain proto rest
  for chain in PREROUTING POSTROUTING; do
    while iptables -t nat -S "$chain" 2>/dev/null | grep -q "relay-ctl:${rid}\""; do
      local line
      line=$(iptables -t nat -S "$chain" | grep "relay-ctl:${rid}\"" | head -1)
      local del_cmd
      del_cmd=$(echo "$line" | sed 's/^-A/-D/')
      iptables -t nat $del_cmd 2>/dev/null || break
    done
  done
}

# ── 持久化 (开机恢复) ──

install_persistence() {
  if command -v systemctl >/dev/null 2>&1; then
    local svc="/etc/systemd/system/${SERVICE_NAME}.service"
    [ -f "$svc" ] && return 0
    cat > "$svc" <<UNIT
[Unit]
Description=Relay-ctl restore forwarding rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    echo "[信息] 已安装 systemd 开机恢复服务"
  else
    local job="@reboot $SCRIPT_PATH restore"
    if ! crontab -l 2>/dev/null | grep -qF "$SCRIPT_PATH restore"; then
      (crontab -l 2>/dev/null; echo "$job") | crontab -
      echo "[信息] 已添加 @reboot crontab 恢复任务"
    fi
  fi
}

# ── CRUD 操作 ──

cmd_add() {
  local lport="$1" orig_host="$2" tport="$3" proto="${4:-both}"
  validate_port "$lport" && validate_port "$tport" && validate_proto "$proto" || exit 1
  local tip
  tip=$(resolve_host "$orig_host") || exit 1

  local existing
  existing=$(read_rules)
  while IFS=: read -r _ ep _ _ eproto _; do
    [ -z "$ep" ] && continue
    if [ "$ep" = "$lport" ]; then
      if [ "$eproto" = "both" ] || [ "$proto" = "both" ] || [ "$eproto" = "$proto" ]; then
        echo "[错误] 本地端口 $lport ($proto) 已被占用"; exit 1
      fi
    fi
  done <<EOF
$existing
EOF

  ensure_forward
  local rid
  rid=$(next_id)
  if apply_iptables "$proto" "$lport" "$tip" "$tport" "$rid"; then
    local new_rules
    new_rules=$(read_rules)
    local entry="${rid}:${lport}:${tip}:${tport}:${proto}:${orig_host}"
    if [ -n "$new_rules" ]; then
      save_config "$(printf '%s\n%s' "$new_rules" "$entry")"
    else
      save_config "$entry"
    fi
    install_persistence
    echo "[成功] #${rid}: 0.0.0.0:${lport} → ${orig_host}(${tip}):${tport} (${proto})"
  else
    echo "[错误] iptables 规则添加失败"; exit 1
  fi
}

cmd_list() {
  local rules
  rules=$(read_rules)
  if [ -z "$rules" ]; then
    echo "当前没有中转规则"; return
  fi
  printf '%-4s  %-8s  %-24s  %-18s  %-8s  %-6s\n' "ID" "本地端口" "目标地址" "解析 IP" "目标端口" "协议"
  printf '%-4s  %-8s  %-24s  %-18s  %-8s  %-6s\n' "---" "------" "--------------------" "----------------" "------" "----"
  while IFS=: read -r id lp tip tp pr host; do
    [ -z "$id" ] && continue
    host="${host:-$tip}"
    printf '%-4s  %-8s  %-24s  %-18s  %-8s  %-6s\n' "$id" "$lp" "$host" "$tip" "$tp" "$pr"
  done <<EOF
$rules
EOF
}

cmd_del() {
  local rid="$1"
  case "$rid" in ''|*[!0-9]*) echo "[错误] 规则 ID 必须是数字"; exit 1 ;; esac

  local rules found=0 new_rules=""
  rules=$(read_rules)
  while IFS=: read -r id lp tip tp pr host; do
    [ -z "$id" ] && continue
    if [ "$id" = "$rid" ]; then
      found=1
    else
      new_rules="${new_rules:+${new_rules}
}${id}:${lp}:${tip}:${tp}:${pr}:${host:-$tip}"
    fi
  done <<EOF
$rules
EOF

  if [ "$found" = "0" ]; then
    echo "[错误] 未找到规则 #${rid}"; exit 1
  fi
  remove_iptables "$rid"
  save_config "$new_rules"
  echo "[成功] 已删除规则 #${rid}"
}

cmd_restore() {
  local rules count=0
  rules=$(read_rules)
  [ -z "$rules" ] && { echo "[信息] 配置为空, 无需恢复"; return; }
  ensure_forward
  while IFS=: read -r id lp tip tp pr _; do
    [ -z "$id" ] && continue
    if apply_iptables "$pr" "$lp" "$tip" "$tp" "$id"; then
      count=$((count + 1))
    else
      echo "[警告] 规则 #${id} 恢复失败"
    fi
  done <<EOF
$rules
EOF
  echo "[成功] 已恢复 ${count} 条规则"
}

cmd_flush() {
  local rules
  rules=$(read_rules)
  while IFS=: read -r id _ _ _ _ _; do
    [ -z "$id" ] && continue
    remove_iptables "$id"
  done <<EOF
$rules
EOF
  # 清理孤立规则 (配置里没有但 iptables 里残留的)
  if iptables -t nat -S 2>/dev/null | grep -q "relay-ctl"; then
    iptables-save | grep -v "relay-ctl" | iptables-restore 2>/dev/null || true
    echo "[信息] 已清理孤立的 iptables 规则"
  fi
  save_config ""
  echo "[成功] 已清空所有中转规则"
}

cmd_refresh() {
  local rules new_rules="" count=0
  rules=$(read_rules)
  [ -z "$rules" ] && { echo "[信息] 配置为空, 无需刷新"; return; }
  while IFS=: read -r id lp tip tp pr host; do
    [ -z "$id" ] && continue
    host="${host:-$tip}"
    local new_ip
    new_ip=$(resolve_host "$host" 2>/dev/null) || { new_ip="$tip"; echo "[警告] #${id} 解析 $host 失败, 保持 $tip"; }
    if [ "$new_ip" != "$tip" ]; then
      remove_iptables "$id"
      if apply_iptables "$pr" "$lp" "$new_ip" "$tp" "$id"; then
        echo "[更新] #${id}: $host $tip → $new_ip"
        count=$((count + 1))
      else
        echo "[错误] #${id} 更新 iptables 失败, 保持 $tip"
        new_ip="$tip"
        apply_iptables "$pr" "$lp" "$tip" "$tp" "$id" 2>/dev/null
      fi
    fi
    new_rules="${new_rules:+${new_rules}
}${id}:${lp}:${new_ip}:${tp}:${pr}:${host}"
  done <<EOF
$rules
EOF
  save_config "$new_rules"
  echo "[完成] 刷新 ${count} 条规则"
}

cmd_status() {
  local fwd count
  fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
  count=$(read_rules | grep -c . || true)
  echo "ip_forward:  $fwd"
  echo "中转规则数:  $count"
  if [ "$count" -gt 0 ]; then
    echo ""
    echo "iptables nat 表 (仅 relay-ctl 规则):"
    iptables -t nat -S 2>/dev/null | grep "relay-ctl" | sed 's/^/  /' || echo "  (无)"
  fi
}

# ── 交互菜单 ──

show_menu() {
  while true; do
    echo ""
    echo ""
    echo "========== 中转管理 (relay-ctl) =========="
    echo "  1) 添加中转规则"
    echo "  2) 查看所有规则"
    echo "  3) 删除规则"
    echo "  4) 刷新 DNS (重新解析域名)"
    echo "  5) 重新加载规则"
    echo "  6) 清空所有规则"
    echo "  7) 查看状态"
    echo "  0) 退出"
    echo "=========================================="
    printf "请选择: "
    read -r choice
    case "$choice" in
      1)
        printf "本地端口: "; read -r lp
        printf "目标地址 (IP/域名): "; read -r tip
        printf "目标端口: "; read -r tp
        printf "协议 [tcp/udp/both, 默认 both]: "; read -r pr
        cmd_add "$lp" "$tip" "$tp" "${pr:-both}" || true
        ;;
      2) cmd_list ;;
      3)
        cmd_list
        printf "要删除的规则 ID: "; read -r rid
        [ -n "$rid" ] && { cmd_del "$rid" || true; }
        ;;
      4) cmd_refresh || true ;;
      5) cmd_restore || true ;;
      6)
        printf "确认清空所有规则? [y/N]: "; read -r yn
        case "$yn" in y|Y) cmd_flush ;; *) echo "已取消" ;; esac
        ;;
      7) cmd_status ;;
      0) exit 0 ;;
      *) echo "[错误] 无效选项" ;;
    esac
  done
}

# ── 入口 ──

usage() {
  cat <<'USAGE'
用法:
  relay-ctl.sh                                         交互式菜单
  relay-ctl.sh add  <本地端口> <目标地址> <目标端口> [tcp|udp|both]
  relay-ctl.sh list                                    列出所有规则
  relay-ctl.sh del  <规则ID>                           删除规则
  relay-ctl.sh refresh                                 重新解析所有域名并更新规则
  relay-ctl.sh restore                                 从配置恢复规则 (开机用)
  relay-ctl.sh flush                                   清空所有规则
  relay-ctl.sh status                                  查看状态

目标地址支持 IP 和域名, 域名在添加时自动解析为 IP.

示例:
  relay-ctl.sh add 443 1.2.3.4 443              # TCP+UDP 都转发
  relay-ctl.sh add 443 node.example.com 443      # 域名自动解析
  relay-ctl.sh add 19007 5.6.7.8 19007 udp       # 只转 UDP (Hysteria2)
  relay-ctl.sh del 2                             # 删除规则 #2
  relay-ctl.sh refresh                           # 域名 IP 变了? 刷新
USAGE
}

main() {
  check_root
  ensure_config

  case "${1:-}" in
    add)
      [ $# -lt 4 ] && { usage; exit 1; }
      cmd_add "$2" "$3" "$4" "${5:-both}"
      ;;
    list)    cmd_list ;;
    del)
      [ $# -lt 2 ] && { usage; exit 1; }
      cmd_del "$2"
      ;;
    refresh) cmd_refresh ;;
    restore) cmd_restore ;;
    flush)   cmd_flush ;;
    status)  cmd_status ;;
    help|-h|--help) usage ;;
    "")      show_menu ;;
    *)       echo "[错误] 未知命令: $1"; usage; exit 1 ;;
  esac
}

main "$@"
