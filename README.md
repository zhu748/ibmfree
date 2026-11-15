# LinuxONE Edge 部署助手

面向 LinuxONE（s390x）及常见 Linux 架构的可审查部署方案。安装时三选一，核心服务只监听回环地址，由 Nginx 在随机 WS/XHTTP 路径上转发；其他请求返回正常静态站点。

## 代理方案（三选一）

| 选择 | `PROXY_MODE` | 方案 | 核心 |
| --- | --- | --- | --- |
| 1 | `vmess-ws` | VMess + WS + TLS | sing-box `1.13.19` |
| 2 | `vless-xhttp` | VLESS + XHTTP + TLS | Xray `26.11.9` |
| 3 | `vless-xhttp-encryption` | VLESS + XHTTP + TLS + VLESS Encryption | Xray `26.11.9` |

首次安装默认选 1；重复安装默认保留已有方案。每次只部署选中的一种，不同时开放三个入站。也可以通过 `PROXY_MODE=1/2/3` 或表中的名称跳过选择提示。VLESS 方案要求客户端支持 XHTTP；方案 3 还要求支持 VLESS Encryption，普通 VLESS 支持不代表这两项都支持。

XHTTP 固定使用 `packet-up`，Nginx 关闭请求和响应缓冲、允许随机路径下的会话/序号子路径。Xray 的 `noSSEHeader` 开启；不依赖 Tunnel 公网域名的 gRPC 支持。这里的 TLS 由 Cloudflare（Tunnel 模式）或 Nginx（Direct 模式）提供，核心在回环地址接收 HTTP。

方案 3 使用固定版本 `xray vlessenc` 生成的第一组 X25519 认证密钥，临时密钥交换使用 ML-KEM；这不等于使用后量子认证。客户端链接只包含客户端加密参数，服务端密钥另存于 root-only 的 `/etc/edge-router/vless-keys.json`，备份时请连同核心配置一起保存。重复安装、或切换到其他方案再切回来时复用这组密钥；已有加密配置丢失密钥文件时停止安装，避免静默生成新密钥使旧客户端失效。

方案 2 的 VLESS Encryption 关闭（`encryption=none`）。Cloudflare 会终止外层 TLS，因此若需要代理载荷在客户端和自己的核心之间继续加密，应选择方案 3。目的网站自己的 HTTPS 加密是另一层。

## 与旧版本的区别

- 不再下载或执行 `eooce.com` 的不透明 `sbsh` 载荷；
- sing-box/Xray 固定为官方发布包，并校验 amd64、arm64、s390x 架构对应的 SHA-256；
- WS/XHTTP 路径随机生成，不使用 `/vmess-argo` 等固定路径；
- 不提供公网订阅端点，客户端链接只保存在 root-only 文件中；
- 核心仅监听 `127.0.0.1`，Nginx 负责正常站点和所选传输的转发；
- systemd 服务启用权限收敛和文件系统保护。
- 默认伪装页按部署生成不同的内容与配色，也可以使用自备首页；
- 未知 Host/SNI 和不完整的 WebSocket 请求不会进入核心服务。
- 安装成功后可用 `fczd` 打开本机管理菜单，安装器和模板保存在本机。

## 部署模式

### Tunnel 模式

适合使用 Cloudflare Tunnel 的环境。公网 TLS 在 Cloudflare 终止，Nginx 只监听 `127.0.0.1:8001`。

Cloudflare 官方没有提供 s390x 发布资产，因此本仓库通过 GitHub Actions 从固定的官方源码提交构建并发布；amd64 与 arm64 直接使用 Cloudflare 官方发布资产。两条路径都按固定版本下载并校验 SHA-256，不需要手工上传二进制。

在 Cloudflare Tunnel 的 Published application 中，将公网域名映射到：

```text
http://127.0.0.1:8001
```

安装器会把 Tunnel Token 保存为仅服务账户可读的文件，并通过 `--token-file` 启动，Token 不会出现在进程参数中。

cloudflared 的 metrics／诊断服务显式绑定 `127.0.0.1:0`（由系统分配本地空闲端口），不依赖构建版本的默认监听地址，也不占用 8001。它只供本机诊断使用，不应在 Cloudflare Published application 或 Nginx 中另行公开。

Tunnel 会按顺序拉起核心，但不再与核心单独停止的操作联动退出；Nginx 和 Tunnel 本身正常时，核心维护／故障期间静态页面仍可服务。此时代理不可用，不代表故障已修复；安装流程仍必须通过核心服务及本地 WS/XHTTP 传输检查才会报成功。需要停掉整个公开入口时应明确停止 `edge-tunnel`。长期使用请配置固定的 Named Tunnel 和自己的域名。

### Direct 模式

适合域名直接或经普通 Cloudflare 代理解析到服务器的环境。需要提前准备 TLS 证书和私钥；Nginx 监听 `443/TCP`。

推荐使用可信证书或 Cloudflare Origin CA，并保持 Cloudflare SSL 模式为 Full (strict)。

## 安装

先在 Cloudflare Tunnel 中将 Published application 设置为 `http://127.0.0.1:8001`，然后在 VPS 上切换到 root：

```bash
sudo -i
```

s390x（IBM LinuxONE）VPS 使用原有的一条命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhu748/ibmfree/main/bootstrap.sh)
```

x86_64/AMD64 与 ARM64 VPS 使用另一条独立命令，与上面的 s390x 入口互不影响（新入口在 s390x 上会拒绝执行并提示改用原命令）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhu748/ibmfree/main/bootstrap-vps.sh)
```

安装器会要求代理方案、UUID（可留空自动生成）、公网域名和 Cloudflare Tunnel Token。完成后按所选方案打印 `vmess://` 或 `vless://` 链接。重复安装时会复用现有 UUID、路径和内部端口。切换方案会改变协议/传输，请重新导入输出的链接；保留 UUID 不代表原链接能跨方案使用。引导脚本会下载完整仓库归档，正式安装仍由仓库中的模板化安装器执行。

安装前会确认 systemd 系统管理器可连接，并通过 `flock` 防止两个安装进程同时修改配置（系统基础包 `util-linux` 提供该命令）。锁会覆盖安装和回滚过程，进程结束后释放；不要手动删除 `/run/edge-router-install.lock` 来强行解锁。

完成依赖安装和参数收集后，安装器会检查内部核心端口及 Tunnel 的 8001（Direct 为 443）是否空闲或属于对应的现有 systemd 服务；其他进程占用或无法确认归属时，在部署文件写入前停止，不会结束占用进程或悄悄改端口。检查保守地覆盖同端口的所有本机地址；检查后仍可能有其他程序抢占端口，因此保留后续服务验证和回滚。此时基础软件包可能已经安装。

重复安装时，UUID 提示中的默认值来自本安装器已有的 sing-box 或 Xray 配置，回车即可保留；部署模式和自定义 Tunnel 入口端口也会复用已有状态，旧安装可从 Nginx 配置中读取。显式传入 `UUID`、`WS_PATH`、`SING_BOX_PORT`、`DEPLOY_MODE`、`ORIGIN_PORT` 时以传入值为准。已有核心配置为空或无法唯一读取时，安装器停止而不会静默生成新身份；此时请先检查并备份 `/etc/edge-router/config.json`。这不等同于自动迁移其他脚本生成的配置。

安装后会检查本地首页和 Nginx 到核心的传输：VMess 使用 WebSocket 握手，XHTTP 使用真实 packet-up POST，并有限重试以等待服务就绪。本地通过不代表 Cloudflare Token、域名映射、UUID 或 Encryption 已通过公网验证；最终仍需导入链接测试。健康检查不使用环境代理，也不会把 Token 放进请求。

安装结束还会按 systemd 主进程检查核心、Nginx 和 Tunnel 服务的非回环 TCP 监听。Direct 模式的 Nginx 443 属于预期入口；其他非回环监听会提示核对，例如 VPS 原有 Nginx 默认站点的 80 端口。检查只报告地址，不会删除已有站点、停止其他服务或修改防火墙；无法读取监听／主进程信息时也会提示。它不是全机端口审计，不覆盖其他进程、UDP、容器端口映射或公网防火墙可达性。

写入阶段失败或收到 Ctrl+C／终止信号时，安装器会尝试回滚配置。备份先复制到目标目录的临时文件，成功后再替换；复制失败或备份缺失时会保留当前文件并报告具体路径。新备份统一保存在 `/var/backups/edge-router/install.*` 的 root-only 目录，`paths.tsv` 记录原文件路径，不再写入网页目录。旧版留下的备份不自动删除，但本项目 Nginx 站点会拒绝访问 `.bak`、`.restore` 等备份路径。回滚不卸载已经安装的软件包；强制结束进程（SIGKILL）或断电无法触发退出处理。

正常更新与回滚都在目标文件所在目录创建权限为 `0700` 的 `.edge-stage.*` 私有暂存目录，复制及权限设置完成后再通过同文件系统重命名替换。复制／替换失败不会先截断旧文件；源文件与目标相同（例如重用现有 Token／证书）也支持。目标符号链接替换的是链接本身，不改写其指向的外部文件，旧链接可由备份恢复。暂存目录在正常退出或可处理的中断后清理；异常清理失败会报告路径。该保护针对单个文件，不代表整套配置具备跨文件原子性，也不保证断电后的持久性；SIGKILL 或断电仍可能留下私有暂存目录。

也可以克隆仓库后运行：

```bash
git clone https://github.com/zhu748/ibmfree.git
cd ibmfree
sudo bash install.sh
```

例如直接选择方案 3（其余参数仍交互输入）：

```bash
sudo PROXY_MODE=vless-xhttp-encryption bash install.sh
```

要测试本地修改，应从克隆目录运行 `install.sh`；上方一键入口始终下载 GitHub `main` 分支。

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
| `PROXY_MODE` | 已有方案，否则 `vmess-ws` | 三选一，也接受 `1`、`2`、`3` |
| `WS_PATH` | 两段完全随机路径 | WS/XHTTP 共用的路径变量，保留旧名称 |
| `ORIGIN_PORT` | `8001` | Tunnel 模式的本地 Nginx 端口 |
| `SING_BOX_PORT` | 随机空闲端口 | 所选核心的回环监听端口，保留旧名称 |
| `SITE_INDEX_FILE` | 自动生成 | 可选的自备静态首页文件，不会增加交互问题 |

部署完成后，客户端链接保存在：

```text
/etc/edge-router/client.txt
```

该文件权限为 `0600`，不会通过 Web 服务暴露；安装完成时也会按用户要求在终端打印一次。

## 日常管理：fczd

从当前源码运行 `sudo bash install.sh` 完成安装后，在任意目录输入：

```bash
fczd
```

即可打开主菜单，包含安装/切换方案、列出已安装、服务状态、启动/停止/重启、本地检查、查看客户端链接、更换网页首页和卸载。非 root 用户在系统提供 sudo 时会通过 sudo 运行；否则先 `sudo -i` 切换到 root。EOF 或输入 `0` 退出菜单。

也支持直接执行子命令：

```bash
fczd list
fczd status
fczd install 3
fczd restart
fczd stop
fczd start
fczd check
fczd link
fczd site /root/my-site/index.html
fczd uninstall
```

`list` 只列出本项目的三种方案和实际已安装的一种，以及核心版本和服务状态，不显示 UUID、随机路径、客户端链接或 Tunnel Token。`status` 默认不附带近期 journal 日志，便于分享排障信息；需要日志时使用下方的 `journalctl` 命令。`link` 是显式查看私密链接的命令。`install 1/2/3` 使用本机安装器切换方案，复用现有域名、Tunnel Token（或 Direct 证书）和连接参数；切换后请重新导入链接。菜单重装同样尊重显式传入的环境变量；缺少旧证书时会询问新的证书文件。参数数量或方案值错误时会在执行操作前停止。

`stop` 停止本项目核心和 Tunnel，即使核心配置损坏或二进制丢失也可使用，Nginx 保持运行；Tunnel 模式的公网隧道入口随之关闭，Direct 模式的静态网页仍可访问。`start/restart` 先校验核心配置和 Nginx，再修改服务状态，随后检查本地 WS/XHTTP 链路；中途失败时尝试恢复原服务状态。`check` 取得安装锁后读取配置并检查本地链路。`site` 只替换首页，原首页保存在私有备份中；可以不带文件参数，按提示输入 HTML 文件路径。使用自己的真实公开内容可以减少统一占位页的显眼特征。

管理入口安装在 `/usr/local/bin/fczd`，本机安装器和模板位于 `/usr/local/lib/fczd`，仅 root 可改写。管理状态保存在 root-only 的 `/etc/edge-router/install-state.json`，不包含 Token、UUID 或加密密钥；缺少此文件的旧安装可从本项目现有核心和 Nginx 配置中识别参数。菜单操作不下载远程管理脚本；安装核心时仍按固定版本下载、校验官方发布包。更新源码后重新运行 `install.sh` 可更新本机菜单。

卸载前会列出范围并要求输入 `UNINSTALL`；自动化调用可显式使用 `fczd uninstall --yes`。卸载会备份并移除本项目配置/密钥、核心、两个 systemd 单元、本项目 Nginx 站点和管理器。删除、Nginx 校验/重载或 systemd 操作失败时，安装器会尝试恢复托管文件和原服务状态。它保留共享的 Nginx/cloudflared 程序、服务账户、静态站点目录、用户额外文件、历史备份和系统日志。备份中的密钥依旧敏感，需要彻底移除时应由管理员核对用途后处理。

安装和管理器更新同样参与现有回滚；`fczd` 名称或管理目录被其他程序占用时停止，避免覆盖。菜单以独立 Bash 进程执行操作，单次失败会回到菜单，保留子进程的错误处理和回滚行为。

管理器在读取重装参数前取得与安装器相同的锁；同一进程进入安装流程时复用锁描述符。卸载取得锁后会再次检查托管入口归属。仅文件写入/备份失败、尚未修改服务状态时，回滚只恢复文件；已修改服务时才恢复服务状态，并优先重载仍在运行的 Nginx。服务恢复失败会明确报告，便于管理员继续排查。

## 验证与排错

```bash
sudo systemctl status edge-router nginx
sudo nginx -t
sudo journalctl -u edge-router -u edge-tunnel --since today
```

VMess 核心配置检查用 `sudo /usr/local/libexec/edge-router check -c /etc/edge-router/config.json`；两种 VLESS 方案用 `sudo /usr/local/libexec/edge-router run -test -config /etc/edge-router/config.json`。

Tunnel 模式还应检查：

```bash
sudo systemctl status edge-tunnel
curl -I https://edge.example.com/
```

## 安全边界

随机路径和正常站点可以减少低成本主动探测，但不应被视为不可识别。安全性仍依赖 UUID/密钥保密、TLS、及时升级、最小化开放端口及 Cloudflare/WAF 规则。

本项目的站点对未找到页面、受保护文件和 WebSocket 上游错误返回相同的 404 正文；有效 WebSocket 升级仍返回 101。目录跳转使用相对地址，不携带内部 HTTP scheme 和 8001 端口。重装默认保留现有首页，只有首次安装或显式提供 `SITE_INDEX_FILE` 时才生成／替换；用户自己的真实静态页面比统一模板更适合公开展示。

秘密 WebSocket 路径上的上游 301／302／303／307／308 跳转也转为统一 404，避免返回内部地址的 Location；这不影响普通静态目录的正常跳转。集成测试另行覆盖上游断开、拒绝连接和恢复后的有效握手；Cloudflare 自身产生的错误页面不受源站模板控制。

WS/XHTTP 代理位置会过滤上游 Server、X-Powered-By、X-Runtime、X-AspNet-Version、X-Generator、X-Backend-Server 和认证挑战响应头，401/407 也映射为站点的统一 404。有效协议响应仍保持工作；不改写 Cloudflare 自身响应。`vless-keys.json` 和 `install-state.json` 即使误放入网页目录也不能通过本项目站点访问。

秘密路径仅在基础 WebSocket 握手字段完整时转发：GET、Upgrade 为 websocket、Connection 包含 Upgrade、版本为 13、Key 为 16 字节 nonce 的 Base64 形式；可解析的 HTTP 请求中，这些字段缺失或校验失败时在 Nginx 层返回普通 404，不交给核心生成协议错误。检查允许合法的大小写和 Connection 多 token 写法，不增加 User-Agent／Origin 限制。这不是 VMess 身份认证：完整握手仍可返回 101，之后由核心校验 UUID；路径和 UUID 仍需保密。

站点显式关闭目录列表，即使 VPS 的 Nginx 全局启用了 `autoindex`，无首页的目录也返回统一 404，不展示目录内文件名、大小和时间。普通静态资源仍可按路径访问；`.edge-stage.*` 暂存目录同时由文件权限和隐藏路径规则保护。

访问日志仅保留时间、方法、状态、字节数和耗时，不记录 URL／查询串／Referer。错误日志仍保留用于排障，可能包含请求路径；系统管理员、Cloudflare 和 VPS 提供方仍可能观察到相关信息。本项目不会清除系统审计或保证规避流量识别。

服务使用普通 systemd 管理和通用的 edge-router/edge-tunnel 名称，Token 通过受限文件传入，服务新建文件使用 `UMask=0077`；这些措施用于减少凭据泄露和公网实现信息。具有本机管理权限的人仍能检查二进制、配置和网络连接，无法保证消除 VPS 上的代理特征。

## 开发验证

仓库包含隔离的回归测试，覆盖首次安装、重复安装、旧配置异常、端口、cloudflared 能力检查与架构分发、下载失败、回滚、VMess 链接和本机 WebSocket 握手。测试只使用临时目录和回环地址，不安装软件、不访问真实 `/etc`，也不需要 Cloudflare 凭据。运行环境需要 Bash、curl、tar 和 Node.js（Node.js 仅用于测试，VPS 安装不需要）。

管理器回归测试还覆盖本地 `fczd` 入口/模板安装、冲突拒绝、失败后清理与重试、旧配置识别、列表不泄露凭据、Token 复用、服务操作范围、菜单分派、更换首页、取消卸载、卸载保留共享/用户/审计文件，以及 Nginx 校验失败后的文件和服务恢复。

```bash
bash tests/run.sh
```

Windows 可使用 Git Bash 在仓库目录执行相同命令；实际 `flock` 互斥和 `ss` 进程归属测试只在 Linux 运行，其余预检分支使用隔离模拟。`Test installer` 工作流会在安装器、模板或测试变更时于 Ubuntu 24.04 运行测试；这不能替代 s390x/systemd VPS 上的完整安装验证。

CI 还会安装 Nginx 并执行 `node tests/nginx-privacy.cjs`：使用测试专属临时目录、回环端口和一次性证书，实际验证 Tunnel/Direct 模板的 404、备份拒绝访问、日志字段、目录跳转、SNI 拒绝和有效 WebSocket 升级。该步骤在开发机需要预装 Nginx 与 OpenSSL，不会修改系统 Nginx 配置。

`node tests/vmess-loopback.cjs` 会下载安装器固定版本的官方 sing-box 发布包，使用安装器中的架构 SHA-256 校验，在临时目录运行真实客户端／服务端及 Nginx。测试复用安装器生成的配置和 `vmess://` 链接，覆盖并发 1 MiB 下载、上传回传的 SHA-256 完整性校验、错误 UUID／路径拒绝及拒绝后的恢复连接。Direct 模式使用一次性证书验证 TLS（不跳过证书校验）；Tunnel 模式只测本地 HTTP origin 链路，不连接 Cloudflare。此测试需要 Linux、Bash、Node.js、Nginx、OpenSSL、curl、tar；不要求 root、不调用 systemd、不增加 VPS 安装依赖。CI 在 amd64 运行，不能替代 s390x 实机、其他客户端、UDP 或公网 Tunnel 测试。

`node tests/xhttp-loopback.cjs` 使用同样隔离的方式下载、校验固定版本 Xray，复用安装器模板和 `vless://` 链接，验证普通/Encryption 两个方案在 Tunnel 本地链路和 Direct TLS 下的并发下载、分包上传、错误 UUID/路径/Host/加密密钥拒绝及恢复，还执行真实 XHTTP 本地健康检查。需要额外安装 `unzip`；不连接 Cloudflare，不代替公网 Tunnel 或 s390x 实机验证。

## 来源

- 核心：[SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- VLESS/XHTTP 核心：[XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- 隧道客户端：[cloudflare/cloudflared](https://github.com/cloudflare/cloudflared)
- 原始脚本整理自 Joey 与 [eooce](https://github.com/eooce) 的工作。
