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

适合使用 Cloudflare Tunnel 的环境。公网 TLS 在 Cloudflare 终止，Nginx 只监听 `127.0.0.1:8001`。

Cloudflare 官方没有提供 s390x 发布资产，因此本仓库通过 GitHub Actions 从固定的官方源码提交构建并发布。安装器会自动下载和校验，不需要手工上传二进制。

在 Cloudflare Tunnel 的 Published application 中，将公网域名映射到：

```text
http://127.0.0.1:8001
```

安装器会把 Tunnel Token 保存为仅服务账户可读的文件，并通过 `--token-file` 启动，Token 不会出现在进程参数中。

### Direct 模式

适合域名直接或经普通 Cloudflare 代理解析到服务器的环境。需要提前准备 TLS 证书和私钥；Nginx 监听 `443/TCP`。

推荐使用可信证书或 Cloudflare Origin CA，并保持 Cloudflare SSL 模式为 Full (strict)。

## 安装

先在 Cloudflare Tunnel 中将 Published application 设置为 `http://127.0.0.1:8001`，然后在 s390x VPS 上切换到 root：

```bash
sudo -i
```

执行一条命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhu748/ibmfree/main/bootstrap.sh)
```

安装器只会要求 UUID（可留空自动生成）、公网域名和 Cloudflare Tunnel Token。完成后会直接打印 `vmess://` 链接。重复安装时会复用现有 UUID、WebSocket 路径和内部端口，避免旧客户端无故失效。引导脚本会下载完整仓库归档，正式安装仍由仓库中的模板化安装器执行。

重复安装时，UUID 提示中的默认值来自本安装器已有配置，回车即可保留；显式传入 `UUID`、`WS_PATH`、`SING_BOX_PORT` 时以传入值为准。已有配置为空或无法唯一读取时，安装器停止而不会静默生成新身份；此时请先检查并备份 `/etc/edge-router/config.json`。这不等同于自动迁移其他脚本生成的配置。

安装后会检查本地首页和 Nginx 到 sing-box 的 WebSocket 握手，并有限重试以等待服务就绪。本地通过不代表 Cloudflare Token、域名映射或 VMess 认证已经通过公网验证；最终仍需导入链接测试。健康检查不使用环境代理，也不会把 Token 放进请求。

写入阶段失败或收到 Ctrl+C／终止信号时，安装器会尝试回滚配置。备份先复制到目标目录的临时文件，成功后再替换；复制失败或备份缺失时会保留当前文件并报告具体路径。新备份统一保存在 `/var/backups/edge-router/install.*` 的 root-only 目录，`paths.tsv` 记录原文件路径，不再写入网页目录。旧版留下的备份不自动删除，但本项目 Nginx 站点会拒绝访问 `.bak`、`.restore` 等备份路径。回滚不卸载已经安装的软件包；强制结束进程（SIGKILL）或断电无法触发退出处理。

也可以克隆仓库后运行：

```bash
git clone https://github.com/zhu748/ibmfree.git
cd ibmfree
sudo bash install.sh
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
| `ORIGIN_PORT` | `8001` | Tunnel 模式的本地 Nginx 端口 |
| `SING_BOX_PORT` | 随机空闲端口 | sing-box 回环监听端口 |
| `SITE_INDEX_FILE` | 自动生成 | 可选的自备静态首页文件，不会增加交互问题 |

部署完成后，客户端链接保存在：

```text
/etc/edge-router/client.txt
```

该文件权限为 `0600`，不会通过 Web 服务暴露；安装完成时也会按用户要求在终端打印一次。

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

本项目的站点对未找到页面、受保护文件和 WebSocket 上游错误返回相同的 404 正文；有效 WebSocket 升级仍返回 101。目录跳转使用相对地址，不携带内部 HTTP scheme 和 8001 端口。重装默认保留现有首页，只有首次安装或显式提供 `SITE_INDEX_FILE` 时才生成／替换；用户自己的真实静态页面比统一模板更适合公开展示。

访问日志仅保留时间、方法、状态、字节数和耗时，不记录 URL／查询串／Referer。错误日志仍保留用于排障，可能包含请求路径；系统管理员、Cloudflare 和 VPS 提供方仍可能观察到相关信息。本项目不会清除系统审计或保证规避流量识别。

## 开发验证

仓库包含隔离的回归测试，覆盖首次安装、重复安装、旧配置异常、端口、cloudflared 能力检查、下载失败、回滚、VMess 链接和本机 WebSocket 握手。测试只使用临时目录和回环地址，不安装软件、不访问真实 `/etc`，也不需要 Cloudflare 凭据。运行环境需要 Bash、curl、tar 和 Node.js（Node.js 仅用于测试，VPS 安装不需要）。

```bash
bash tests/run.sh
```

Windows 可使用 Git Bash 在仓库目录执行相同命令。`Test installer` 工作流会在安装器、模板或测试变更时于 Ubuntu 24.04 运行测试；这不能替代 s390x/systemd VPS 上的完整安装验证。

CI 还会安装 Nginx 并执行 `node tests/nginx-privacy.cjs`：使用测试专属临时目录、回环端口和一次性证书，实际验证 Tunnel/Direct 模板的 404、备份拒绝访问、日志字段、目录跳转、SNI 拒绝和有效 WebSocket 升级。该步骤在开发机需要预装 Nginx 与 OpenSSL，不会修改系统 Nginx 配置。

## 来源

- 核心：[SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- 隧道客户端：[cloudflare/cloudflared](https://github.com/cloudflare/cloudflared)
- 原始脚本整理自 Joey 与 [eooce](https://github.com/eooce) 的工作。
