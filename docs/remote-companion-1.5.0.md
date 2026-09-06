# 跨网络手机字幕 1.5.0（build 17）

2026-09-06 已部署到用户的杭州 ECS，并安装到 `/Applications/StreamTranslate.app`。
这是可用的个人服务器版本，不是面向任意 Mac 用户的公共注册服务。

仓库中的 IP 已替换为文档示例 192.0.2.1（不可连接），不代表真实服务地址。
部署时须替换 Relay/nginx.conf 与 Relay/streamtranslate-relay.service 中的主机。
本机及已部署服务器的实际配置未被这次仓库脱敏修改。

## 怎么用

1. 打开 Mac 的「手机字幕」，保持「网页版」选中。
2. 点「手机用流量 / 不同 Wi-Fi…」，确认开启后用 iPhone 自带相机扫码。
3. 打开链接后开始阅读；需要分享屏幕时点 Mac 的「进入仅手机显示模式」。

手机可以使用蜂窝网络或另一 Wi-Fi；不需 VPN、付费开发者会员、购买域名、
输入服务器地址或手动信任证书。公司网络仍须允许访问该 HTTPS 地址，且会议
内容须允许按此方式传输。本机已配置服务凭据，但跨网络开关默认关闭，首次
需要明确确认；不自动开启录音。局域网旧入口仍在折叠项中。

二维码两分钟、一次有效。一次连接授权最多 12 小时、三个浏览器；有效期内
刷新/重新打开网页可恢复。Mac 重启、关闭连接、服务器重启或授权到期后可能
需要重新扫码。这版不承诺永久配对。Safari 添加主屏幕可作为快捷入口，但
独立主屏幕容器的配对继承与真实 iPhone 锁屏/蜂窝切换仍待设备实测。

## 数据与权限边界

链路：Mac 音频 → 本地识别/翻译 → CryptoKit AES-256-GCM → HTTPS →
杭州中转（密文）→ HTTPS/SSE → 浏览器 WebCrypto 解密 → 原有全屏阅读界面。

- 音频和模型不上传。传输包含原文、译文、状态；字幕内容在 Mac 加密。
- 解密密钥只在二维码 URL fragment 中给手机，不放查询参数/请求体；网页
  收到后移除 fragment。手机 localStorage 保存连接标识和解密密钥以及阅读
  偏好，不保存字幕。页面内存的字幕在断开/隐藏/撤销时清空。
- 发布凭据与阿里云 AccessKey 完全无关，不放 App 包或仓库；本机文件
  `~/Library/Application Support/StreamTranslate/RemoteRelay.json` 为 0600。
- 发布权限单独认证；浏览器配对使用随机 256-bit、两分钟一次性邀请，之后
  为 Secure/HttpOnly/SameSite=Strict 的 `__Host-` Cookie。Host/Origin 校验、
  无跨站 CORS、拒绝 query 参数、CSP、无第三方脚本/统计代码。
- 中转只在内存保存有限的加密基线与增量，用于重连；不记录字幕或访问日志。
  最多两间房、每房三浏览器、21 帧/约 2 MiB 缓冲；发布请求上限 256 KiB。
  慢连接积压时断开并从最新基线恢复，不无限排队。
- 网页代码由该服务器提供。服务器或账号被攻破可替换网页脚本，不能声称
  “即使服务器被攻破也绝不可能读到字幕”。保护服务器和 Mac/手机本身同样重要。
- 手机断线不恢复 Mac 字幕；未经验证的密文不显示。不因 TLS 故障降级为 HTTP。

## 部署与续期

- 地址示例：`https://192.0.2.1/`。真实服务直接打开只是未配对入口；用户扫码获得授权。
- `/opt/streamtranslate-relay`：无 npm 依赖的 Node 22 服务、生成的阅读资源、证书辅助脚本。
- `/etc/streamtranslate-relay/publisher-token`：独立发布凭据，root:streamtranslate-relay 0640。
- `streamtranslate-relay.service`：低权限专用用户、160 MiB 内存上限、只读系统目录，
  后端只监听 127.0.0.1:18447。检查时 cgroup 内存 44,277,760 bytes（约 42 MiB）。
- `/etc/nginx/conf.d/streamtranslate-relay.conf`：新增 443 HTTPS 站点；原有 80/8080
  站点配置未改，Nginx 通过校验后平滑 reload；已有业务容器未重启。
- `/opt/streamtranslate-certbot`：独立 Python 环境，Certbot 5.8.0。初次继承服务器
  HTTP 镜像配置，之后所有依赖通过 HTTPS 阿里云镜像重新安装；不改变系统 pip/DNS。
- 正式 IP 证书保存在 `/etc/streamtranslate-certificates`；本次到期日 2026-09-12。
  `/etc/streamtranslate-certificates-staging` 仅用于测试签发，不给手机使用。
- `streamtranslate-certificate.timer` 每天 00/12 时加 0–30 分钟随机延迟运行。
  Certbot 内部随机等待已关闭（否则可能超出服务超时），续期后 nginx -t + reload。
- 服务器系统解析器对 ACME 域名超时；`certbot-with-doh.py` **仅在证书工具进程内**
  对两个 Let’s Encrypt API 域名通过 AliDNS HTTPS 解析，TLS 仍验证原域名。
  不编辑 `/etc/hosts`、系统 DNS、代理配置或安全组；不依赖已有 sing-box 服务。
- 停用运行服务：`systemctl stop streamtranslate-relay`；定时续期是独立 unit。
  切勿停止 Nginx 或 Docker 以停用字幕服务，以免影响其他业务。

证书服务 `Result=success / ExecMainStatus=0`，计时器 active；已跑带 deploy hook
的 dry-run，测试签发、续期与 Nginx 重载成功。仍需持续运维监控，不把一次演练
视为多年稳定性的保证。

## 验证

- `Relay/server.test.mjs`：真实 HTTP 鉴权、一次性邀请、Origin、密文转发与解密、
  重试幂等、顺序拒绝、浏览器确认和撤销；通过。
- `Relay/browser.test.mjs`：隔离 Chromium，扫码解密、满屏布局、轻点控件、自动隐藏、
  刷新、同句修订、无字幕持久化、篡改拒绝、恢复和停止清空；11 项通过。
- `CompanionProbe --remote-fixture` + `Relay/public.test.mjs`：实际 Swift CryptoKit →
  杭州公网 HTTPS → 浏览器 WebCrypto；增量、刷新后基线/增量重放、手机确认、停止清空；
  6 项通过。仅合成文字，无麦克风或系统音频，不使用用户会议内容。
- 公网 curl `HTTPS 200 / ssl_verify_result=0`；Chromium 未忽略证书错误，未映射本地地址。
- 原有局域网浏览器 37 项回归、273 项可移植核心测试均通过。可移植适配器不是完整
  Xcode Swift Testing runner。隐私窗口检查 visible=0/pass=true。
- 已安装包 1.5.0/17 严格签名验证通过；实际鼠标点手机入口成功，窗口层级 4 高于字幕 3。
  通过截图确认新入口可见、局域网入口折叠。旧安装包保留在 `.app.previous`。
- 未测：真实 iPhone 蜂窝网络/微信、主屏幕容器、整天会议、断网切换与大量并发。

日志与截图：`build/remote-public-tests.log`、`build/remote-browser-tests.log`、
`build/remote-lan-regression.log`、`build/remote-relay-core-tests.log`、
`build/remote-privacy-tests.log`、`build/remote-installed-phone.png`、
`build/remote-public-reader.png`、`build/install-1.5.0.log`。

实现入口：`Relay/server.mjs`、`Relay/remote.js`、
`CompanionKit/Sources/CompanionKit/RemoteCaptionRelay.swift`。
部署静态阅读资源由 `node Relay/export-assets.mjs OUTPUT_DIRECTORY` 从已有 WebAssets
生成，不维护另一份字幕 UI。每次网页资源变更后需要重新生成并部署。

## 官方依据

- [IP 与六日证书已开放](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability.html)
- [Certbot 的 IP 证书与 webroot 支持](https://letsencrypt.org/2026/03/11/shorter-certs-certbot)
- [Certbot 参数与自动续期](https://eff-certbot.readthedocs.io/en/stable/using.html)
