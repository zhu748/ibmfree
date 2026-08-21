# LinuxONE Edge 部署助手

面向 LinuxONE（s390x）及常见 Linux 架构的可审查部署方案。核心服务只监听回环地址，由 Nginx 在秘密 WebSocket 路径上转发；其他请求返回正常静态站点。

## 与旧版本的区别

- 不再下载或执行 `eooce.com` 的不透明 `sbsh` 载荷；
- sing-box 固定为官方 `v1.13.19` 发布包，并校验架构对应的 SHA-256；
- WebSocket 路径随机生成，不使用 `/vmess-argo` 等固定路径；
- 不提供公网订阅端点，客户端链接只保存在 root-only 文件中；
- sing-box 仅监听 `127.0.0.1`，Nginx 负责正常站点和 Upgrade 转发；
- systemd 服务启用权限收敛和文件系统保护。
- 默认伪装页按部署生成不同的内容与配色，也可以使用自备首页；
- 未知 Host/SNI 和不完整的 WebSocket 请求不会进入核心服务。

## 部署模式

### Tunnel 模式

适合使用 Cloudflare Tunnel 的环境。公网 TLS 在 Cloudflare 终止，Nginx 只监听 `127.0.0.1:18080`。

Cloudflare 官方没有提供 s390x 发布资产，因此必须从官方源码构建：

1. 在 GitHub Actions 中手动运行 `Build cloudflared for s390x`；
2. 下载 `cloudflared-2026.8.2-linux-s390x` 产物；
3. 在服务器验证随附的 SHA-256 后安装：

```bash
sha256sum --check cloudflared-linux-s390x.sha256
sudo install -o root -g root -m 0755 cloudflared-linux-s390x /usr/local/bin/cloudflared
```

在 Cloudflare Tunnel 的 Published application 中，将公网域名映射到：

```text
http://127.0.0.1:18080
```

安装器会把 Tunnel Token 保存为仅服务账户可读的文件，并通过 `--token-file` 启动，Token 不会出现在进程参数中。

### Direct 模式

适合域名直接或经普通 Cloudflare 代理解析到服务器的环境。需要提前准备 TLS 证书和私钥；Nginx 监听 `443/TCP`。

推荐使用可信证书或 Cloudflare Origin CA，并保持 Cloudflare SSL 模式为 Full (strict)。

## 安装

请克隆完整仓库后运行，不要使用 `curl | bash`，因为安装器依赖仓库内经过版本控制的模板：

Tunnel 模式没有新增必填输入：仍使用域名、UUID（未提供时自动生成）和 Cloudflare Tunnel Token。

```bash
git clone https://github.com/zhu748/ibmfree.git
cd ibmfree
sudo bash install.sh
```

也可以通过环境变量进行非交互配置：

```bash
sudo PUBLIC_DOMAIN=edge.example.com \
  UUID=11111111-1111-4111-8111-111111111111 \
  DEPLOY_MODE=tunnel \
  CLOUDFLARED_BIN=/usr/local/bin/cloudflared \
  TUNNEL_TOKEN_FILE=/root/tunnel-token.txt \
  bash install.sh
```

Direct 模式额外使用：

```bash
sudo PUBLIC_DOMAIN=edge.example.com \
  DEPLOY_MODE=direct \
  TLS_CERT_FILE=/root/origin.crt \
  TLS_KEY_FILE=/root/origin.key \
  bash install.sh
```

可选环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `UUID` | 随机 | 客户端 UUID |
| `WS_PATH` | 两段完全随机路径 | WebSocket 路径 |
| `ORIGIN_PORT` | `18080` | Tunnel 模式的本地 Nginx 端口 |
| `SING_BOX_PORT` | 随机空闲端口 | sing-box 回环监听端口 |
| `SITE_INDEX_FILE` | 自动生成 | 可选的自备静态首页文件，不会增加交互问题 |

部署完成后，客户端链接保存在：

```text
/etc/edge-router/client.txt
```

该文件权限为 `0600`，不会通过 Web 服务暴露。

## 验证与排错

```bash
sudo systemctl status edge-router nginx
sudo nginx -t
sudo /usr/local/libexec/edge-router check -c /etc/edge-router/config.json
sudo journalctl -u edge-router -u edge-tunnel --since today
```

Tunnel 模式还应检查：

```bash
sudo systemctl status edge-tunnel
curl -I https://edge.example.com/
```

## 安全边界

随机路径和正常站点可以减少低成本主动探测，但不会改变 VMess/WebSocket 协议本身，也不应被视为不可识别。安全性仍依赖 UUID 保密、TLS、及时升级、最小化开放端口及 Cloudflare/WAF 规则。

## 来源

- 核心：[SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- 隧道客户端：[cloudflare/cloudflared](https://github.com/cloudflare/cloudflared)
- 原始脚本整理自 Joey 与 [eooce](https://github.com/eooce) 的工作。
