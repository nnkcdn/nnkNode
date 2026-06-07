# Nanako 节点后端 · Coolify 部署仓库

基于 **V2bX**(多核:Xray + sing-box + Hysteria2)的节点后端,**全参数环境变量化**、**Coolify 友好**、**多架构预编译**。

> 本仓库内容对应 GitHub 仓库 [`nnkcdn/nnkNode`](https://github.com/nnkcdn/nnkNode)。

## 工作原理(为什么弱节点不用编译)

```
 你 push 仓库 ──► GitHub Actions 自动编译多架构镜像 ──► 推到 GHCR
                                                          │
        弱性能节点(Coolify) ◄── 只 docker pull 预编译镜像 ◄──┘   ← 零编译
```

- **预编译**:`.github/workflows/build.yml` 每次 push 用 buildx 编译 `linux/amd64` + `linux/arm64`,推到 `ghcr.io/nnkcdn/nnknode:latest`。
- **弱节点**:Coolify 直接拉镜像运行,**不在节点上编译**(V2bX 多核编译要 ~2GB 内存,小鸡扛不住)。
- **配置**:容器启动时 `docker-entrypoint.sh` 把环境变量渲染成 `config.json`,你**只填环境变量**。

## 一、首次准备

1. 把本仓库推到 `github.com/nnkcdn/nnkNode`(`src/` 是 vendored 的 V2bX 源码,必须一起推,CI 要用它编译)。
2. push 后看仓库 **Actions** 跑完,镜像出现在仓库 **Packages**。
3. GHCR 包首次发布默认是私有 → 打开 https://github.com/users/nnkcdn/packages/container/nnknode/settings ,拉到底把可见性改成 **Public**(只需一次)。仓库本身是公开的,包设为 Public 后**所有服务器都能匿名拉取,Coolify 无需任何登录凭据**。

## 二、Coolify 部署(弱节点,推荐)

1. **New Resource → Docker Compose**,Source 选 `nnkNode` 仓库,用默认 `docker-compose.yaml`(引用预编译镜像,不在节点上构建)。
2. **Environment Variables** 面板填变量(最少 4 个必填),见下方《协议配置模板》。
3. **Deploy**。

> **网络**:compose 用 `network_mode: host`(代理节点必须),Hysteria2/TUIC 的 UDP 才能直通,无需 Coolify 域名/反代。

### Coolify 健康检查

镜像内置 Docker `HEALTHCHECK`(`healthcheck.sh`),Coolify 自动识别 healthy/unhealthy:

- 默认:`nanako-node` 进程存活即健康(挡崩溃循环)。
- 更严格:设 `HEALTHCHECK_PORT=<节点端口>`,额外 TCP 探测该端口。

## 三、协议配置模板

> **重要**:协议的端口、加密方式、传输(tcp/ws/grpc)、REALITY/XTLS 参数等,**全部在面板的节点设置里配**,后端会自动拉取。环境变量这边只决定三件事:**`NODE_TYPE`(哪种协议)**、**`CORE_TYPE`(用哪个内核)**、**证书**。

### 内核 × 协议支持表

| 协议 | `NODE_TYPE` | 可用 `CORE_TYPE` | 是否需要证书 |
|---|---|---|---|
| VMess | `vmess` | `xray`(默认) / `sing` | 否(除非面板开 ws+tls) |
| VLESS | `vless` | `xray`(默认) / `sing` | REALITY 否 / TLS 是 |
| Trojan | `trojan` | `xray`(默认) / `sing` | **是** |
| Shadowsocks | `shadowsocks` | `xray` / `sing`(SS2022 建议) | 否 |
| Hysteria2 | `hysteria2` | `sing` / `hysteria2`(专核) | **是**(QUIC/UDP) |
| TUIC | `tuic` | `sing` | **是**(QUIC/UDP) |
| AnyTLS | `anytls` | `sing` | 是 |

公共必填(所有协议都要):

```env
API_HOST=https://你的面板地址
API_KEY=面板里的节点通信密钥
NODE_ID=1
```

下面按协议给出**追加**的变量模板。

#### ① VMess

```env
NODE_TYPE=vmess
CORE_TYPE=xray
CERT_MODE=none          # 面板若是 vmess+ws+tls,改成 dns/file 并配 CERT_*
```

#### ② VLESS(REALITY,推荐)

```env
NODE_TYPE=vless
CORE_TYPE=xray
CERT_MODE=none          # REALITY 借用目标站证书,后端不需要证书
```

REALITY 需要一对密钥:`docker exec nanako-node nanako-node x25519`,把生成的公/私钥填到**面板**的节点设置里。
若是 VLESS+TLS(非 REALITY):`CERT_MODE=dns` + 下面《证书》的 `CERT_*`。

#### ③ Trojan(必须 TLS)

```env
NODE_TYPE=trojan
CORE_TYPE=xray
CERT_MODE=dns
CERT_DOMAIN=node.example.com
CERT_PROVIDER=cloudflare
CERT_EMAIL=you@example.com
DNSENV_CF_DNS_API_TOKEN=你的CF_token
```

#### ④ Shadowsocks

```env
NODE_TYPE=shadowsocks
CORE_TYPE=xray          # 用 SS2022(2022-blake3-*)加密时改 CORE_TYPE=sing
CERT_MODE=none
```

#### ⑤ Hysteria2(QUIC/UDP,必须 TLS)

```env
NODE_TYPE=hysteria2
CORE_TYPE=sing          # 也可用专核: CORE_TYPE=hysteria2
CERT_MODE=dns
CERT_DOMAIN=node.example.com
CERT_PROVIDER=cloudflare
CERT_EMAIL=you@example.com
DNSENV_CF_DNS_API_TOKEN=你的CF_token
```

> UDP 提醒:默认 `network_mode: host` 已直通 UDP。若改桥接网络,记得映射 `端口/udp`。

#### ⑥ TUIC(QUIC/UDP,必须 TLS)

```env
NODE_TYPE=tuic
CORE_TYPE=sing
CERT_MODE=dns
CERT_DOMAIN=node.example.com
CERT_PROVIDER=cloudflare
CERT_EMAIL=you@example.com
DNSENV_CF_DNS_API_TOKEN=你的CF_token
```

#### ⑦ AnyTLS

```env
NODE_TYPE=anytls
CORE_TYPE=sing
CERT_MODE=dns
CERT_DOMAIN=node.example.com
CERT_PROVIDER=cloudflare
CERT_EMAIL=you@example.com
DNSENV_CF_DNS_API_TOKEN=你的CF_token
```

## 四、证书(TLS)

| `CERT_MODE` | 说明 | 需要的变量 |
|---|---|---|
| `none` | 无 TLS(由面板/客户端决定) | — |
| `file` | 已有证书 | 把证书挂到 `/etc/nanako-node/cert/`,设 `CERT_FILE` / `CERT_KEY_FILE` |
| `dns` | DNS-01 自动签发(推荐) | `CERT_DOMAIN` `CERT_PROVIDER` `CERT_EMAIL` + `DNSENV_*` |
| `http` | HTTP-01 自动签发 | `CERT_DOMAIN`(需 80 端口可达) |

DNS provider token 用 `DNSENV_` 前缀注入(自动去前缀传给 ACME),常见厂商:

| 厂商 | `CERT_PROVIDER` | `DNSENV_*` 变量 |
|---|---|---|
| Cloudflare | `cloudflare` | `DNSENV_CF_DNS_API_TOKEN` |
| 阿里云 | `alidns` | `DNSENV_ALICLOUD_ACCESS_KEY` + `DNSENV_ALICLOUD_SECRET_KEY` |
| 腾讯云 | `tencentcloud` | `DNSENV_TENCENTCLOUD_SECRET_ID` + `DNSENV_TENCENTCLOUD_SECRET_KEY` |
| DNSPod | `dnspod` | `DNSENV_DNSPOD_API_TOKEN` |

签发的证书持久化在 `cert-data` 卷。

## 五、DNS 配置（可选）

默认使用节点系统 DNS。如果系统 DNS 不稳定或延迟高，可通过环境变量指定：

```env
DNS_SERVERS=8.8.8.8,1.1.1.1
```

逗号分隔多个 DNS 服务器地址。entrypoint 会自动按内核类型生成对应格式的 DNS 配置：

| `CORE_TYPE` | 生成方式 |
|---|---|
| `xray` | 写入 `DnsConfigPath`，xray 原生 DNS 模块接管解析 |
| `sing` | 写入 `OriginalPath`，sing-box DNS 模块接管解析 |
| `hysteria2` | 不支持（使用系统 DNS） |

常用组合：

| 场景 | `DNS_SERVERS` 值 |
|---|---|
| Google DNS | `8.8.8.8,8.8.4.4` |
| Cloudflare DNS | `1.1.1.1,1.0.0.1` |
| 混合 | `8.8.8.8,1.1.1.1` |

## 六、运维命令

```bash
docker exec nanako-node nanako-node x25519                 # 生成 REALITY 密钥对
docker exec nanako-node nanako-node version
docker exec nanako-node cat /etc/nanako-node/config.json   # 查看生成的配置
```

## 七、端口中转（relay-ctl）

中转服务器一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/nnkcdn/nnkNode/main/relay-ctl.sh -o /usr/local/bin/relay-ctl && chmod +x /usr/local/bin/relay-ctl
```

交互式菜单：

```bash
relay-ctl                                           # 进入交互菜单
```

CLI 命令：

```bash
relay-ctl add 443 node.example.com 443              # TCP+UDP 转发（支持域名）
relay-ctl add 19007 1.2.3.4 19007 udp               # 只转 UDP（Hysteria2）
relay-ctl list                                       # 查看所有规则
relay-ctl del 2                                      # 删除规则 #2
relay-ctl refresh                                    # 域名 IP 变更后刷新
relay-ctl status                                     # 查看状态
relay-ctl flush                                      # 清空所有规则
```

> 使用 iptables DNAT+MASQUERADE 内核层转发，规则自动持久化（systemd 开机恢复）。

## 八、强节点本机编译(可选)


用 `docker-compose.build.yaml`(`build:` 而非 `image:`),或 Coolify 选 Dockerfile 构建包。弱节点别用。

## 九、本地测试(非 Coolify)

```bash
docker build -t nanako-node:full .
docker run --rm --network host \
  -e API_HOST=https://panel.example.com -e API_KEY=xxx \
  -e NODE_ID=1 -e NODE_TYPE=vless nanako-node:full
```

## 注意事项

- **面板不可达时进程会退出**(V2bX 设计,`src/cmd/server.go:79`):填错 `API_HOST/API_KEY/NODE_ID` 会反复重启;`restart: unless-stopped` 会在面板恢复后自愈。属正常 fail-fast。
- **计费用 xray 内核**;V2bX 的 sing 内核在纯 conn 路径有流量少计的小 bug(`common/counter/conn.go` 用 `Store` 应为 `Add`),用 xray 不受影响。
- **geo 数据**(geoip/geosite 的 `.dat`+`.db`)在构建时从 Loyalsoldier / SagerNet 官方 release 下载,内置到镜像 `/usr/share/nanako-node/`。

## 文件说明

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 多阶段、原生交叉编译、运行期下载 geo、内置 HEALTHCHECK |
| `docker-entrypoint.sh` | 环境变量 → `config.json`,再启动 server |
| `healthcheck.sh` | 进程 + 可选端口健康检查 |
| `docker-compose.yaml` | Coolify:预编译镜像(弱节点默认) |
| `docker-compose.build.yaml` | Coolify:本机构建(强节点) |
| `.github/workflows/build.yml` | CI:多架构编译并推 GHCR |
| `relay-ctl.sh` | 中转服务器端口转发管理脚本 |
| `.env.example` | 全部环境变量 |
| `src/` | vendored V2bX 源码(CI 编译用) |
