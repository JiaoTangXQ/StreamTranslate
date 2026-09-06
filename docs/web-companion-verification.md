# 网页字幕开发与验证

## 当前本机安装状态：1.4.2（16）

2026-09-06，已安装全屏网页阅读版 1.4.2，严格签名验证通过。保留用户已启用的快速网页连接选择；通过正式安装 App 的 18444 端口读取 HTML/JS/CSS，确认已提供无固定头部和新的跟随逻辑，而不是仅改了测试页。手机连接窗口已通过实际按钮点击打开，未自动恢复录音。旧 1.4.1 保存在 `/Applications/StreamTranslate.app.previous`，更早备份归档。安装日志 `build/install-1.4.2.log`；测试与界面说明见 `web-reader-1.4.2-verification.md`。手机需要刷新旧页，并在快速连接授权因重启失效时重新扫码。

## 历史安装：1.4.1（15）

2026-09-06，针对用户报告的外边框无法拖动、手机按钮似乎无响应，已安装 1.4.1，完成 `/Applications/StreamTranslate.app` 的严格签名验证与重启。旧 1.4.0 保留在 `/Applications/StreamTranslate.app.previous`，更早的备份归档在 `build/app-backups/`。安装日志为 `build/install-1.4.1.log`。正式安装版已用真实鼠标事件验证四边、右下角拖动和手机按钮关闭后再次打开；连接窗口确实位于字幕窗上方，测试恢复了原窗口尺寸与位置。详见 `window-interaction-fix-2026-09-06.md`。

启动日志确认英中双向翻译会话与 Apple 英文识别模型就绪；手机连接入口已通过实际按钮点击打开。未自动开始录音、未代用户确认 HTTP 风险或开启未加密分享。重启后需点击开始翻译，真实 iPhone 配对仍待用户扫码。下方未安装描述为开发阶段的历史状态。

## 1.3.2（13）：简化扫码入口，2026-09-06

根据用户“不要安装证书或配置一堆东西”的要求，新增显式选择的可信局域网快速连接。旧 HTTPS 流程保留在高级选项；不新增外部服务器、域名或第三方中转。

- Mac 首次快速连接前展示 HTTP 明文风险确认；确认后开启服务、自动选择局域网地址、生成一次性二维码。手机以自带相机/Safari 为主要入口，微信只给出打开 Safari 的引导，不承诺其未验证的兼容性。
- `WebTransport` 隔离两种模式：HTTPS 18443 / Secure host-only cookie / 90 天钥匙串授权；HTTP 18444 / 独立 HttpOnly cookie / 最长 12 小时、服务端只存内存。HTTP 服务停止/重启/切换模式时清空授权，不自动降级 HTTPS。
- 物理 `en*`/`bridge*` 网卡地址自动选择，优先默认路由接口的私有 IPv4；不更改 DNS、代理或 VPN。IPv6-only 情况回退系统 `.local` 名称，未做该网络环境实测。
- 页面始终标明 HTTP 未加密，禁用其不可用的保持亮屏选项。二维码不消除窃听/篡改风险；Safari 可能显示 HTTP 提示。此实现不满足“免配置 + 加密 + 自动亮屏”三项同时成立，不能将快速模式称为与 HTTPS 同等安全。
- 既有私密显示、请求解析、Host/Origin 校验、短码失败限制、流量上限和 SSE 快照/增量逻辑保持共用。字幕不新增持久化或云传输。

验证证据与交付记录：

- `build/web-quick-core-tests.log`：268 个核心测试体，0 个失败断言。仍是 CLT 顺序适配器，不是全量原生 XCTest。
- `build/web-quick-reader-tests.log` / `build/web-quick-api-tests.log`：免证书 HTTP 网页和接口回归。浏览器技能用于实际点击/配对/重载/撤销和截图；HTTP 测试没有传入证书错误忽略选项。
- `build/web-secure-regression-api.log` / `build/web-secure-regression-reader.log`：原 HTTPS 的接口与界面回归；TLS 验证仍来自 curl 显式 CA 校验，Chromium 的忽略证书选项仅用于其独立 UI 实例。
- 测试中原先“持续每秒更新时，五秒内一定出现心跳”的断言偶发失败：发送繁忙时实现本来就跳过冗余心跳。已将测试改为先验证增量，再暂停合成更新验证静默期心跳，未放宽服务端授权或网络安全检查。
- `build/web-quick-safari.png` / `build/web-quick-safari-reopened.png`：iOS 26.5 专用模拟器，通过局域网 IP 的 HTTP 邀请链接直接打开并显示合成字幕；终止 Safari 后再打开不带邀请的地址恢复成功。没有为快速模式安装根证书。URL 打开测试不是物理相机扫码测试。
- `--web-quick-fixture` 使用隔离钥匙串写入 HTTPS 哨兵，退出前验证快速启动/配对/撤销/重启没有读写覆盖该授权，也没有生成根证书；仅测试哨兵会在清理时删除，不操作正式用户凭据。
- 产物路径仍为 `build/StreamTranslate.app`；签名/构建/私密模式日志分别为 `build/web-quick-signature.log`、`build/web-quick-app-build.log`、`build/web-quick-privacy-check.log`。实际结果以日志为准。
- 此轮未替换 `/Applications` 下正在运行的旧版、未开启真实音频的 HTTP 分享。真实 iPhone 扫码、主屏幕入口、微信、无线延迟/长时间稳定性仍需验收。

复现：编译 `CompanionProbe` 后，以 `--web-quick-fixture 新的私有目录` 启动 HTTP 合成服务，或 `--web-fixture 新的私有目录` 启动 HTTPS 合成服务；两个 Node 测试脚本自动识别地址方案。对同一 fixture 顺序运行，不能并发写其控制文件。

---

## 1.3.1（12）历史记录

日期：2026-09-06；Mac 版本 1.3.1（12）。本轮新增网页入口，保留原生 iPhone 版；音频识别/翻译模型不变。

## 实现

- `WebCaptionServer`：独立于原生服务的 TLS 1.3 / HTTP/1.1 监听，固定 18443 端口、系统本地主机名 `.local`。仅接受私有 IPv4、IPv6 ULA/link-local、loopback 和对应 IPv4-mapped 地址；不开放公网源地址、CGNAT 地址或明文接口。
- `WebIdentity`：一年的 P256 根证书/服务器证书，SAN 与根 DNS 名称约束指向该 Mac。根签发私钥不持久化，服务器叶私钥在独立 Keychain 账户内。导出 profile 仅含公开根证书，不含设备管理、VPN、身份私钥或邀请。
- 证书通过用户从 Mac 隔空投送到手机，再手动安装与信任；不提供可被局域网中间人替换的明文证书引导站点，不更改真实手机或主机的系统根证书信任。
- 网页、JS、CSS、SVG 图标与 manifest 均内置 App，零第三方脚本/字体/分析请求。主屏幕入口可以独立打开，但不提供 Mac 离线时的离线应用壳。
- 配对邀请：随机长密钥二维码片段或 8 位短码、120 秒、一次性；六次错误取消邀请。最多三个浏览器授权，90 天有效，Mac 可统一撤销；持久化存储 cookie 的 SHA-256 而非原值，cookie 为 Secure / HttpOnly / SameSite=Strict / host-only。
- 所有请求严格校验 Host，POST 必须匹配 Origin 和 JSON Content-Type，无 CORS；拒绝重复请求头、Transfer-Encoding、无效长度、超长输入和流水线请求。上限 24 个连接，握手/请求读取 10 秒、发送 8 秒超时。
- SSE 初始快照、正常增量、三秒心跳；发送繁忙时只保留最新完整快照，不积压增量队列。浏览器序列缺口重新同步，断线清掉旧画面，后台暂停、前台恢复。浏览器确认渲染/心跳后 Mac 才将它视为正在阅读。
- 原文/译文按 ID 就地更新，使用 textContent，不解释识别文本为 HTML；阅读偏好可持久化，字幕不写 localStorage/IndexedDB/服务工作线程缓存。回看暂停跟随；字体、原文开关、亮屏能力和系统拒绝说明。
- Mac 菜单栏“手机字幕”默认展示网页页签；原生服务与网页服务分别开关，均可支持既有“仅手机显示”模式。断开网页不会恢复 Mac 窗口。发布器共享同一次捕获的字幕快照，新会议不发送上场内容。

## 验证证据

| 检查 | 证据与范围 |
|---|---|
| Mac Release 构建 | `build/web-app-build-final.log`；1.3.1（12）App |
| 本机签名 | `build/web-signature.log`；本机开发身份，不是 Apple 公证/对外签名 |
| 私密模式进程检查 | `build/web-privacy-check.log`：`visible=0, independentTranslationReady=true, pass=true`；隔离偏好/合成字幕，不录音 |
| 核心回归 | `build/web-portable-tests-final.log`；267 个测试体、0 个失败断言；CLT 顺序断言适配器，新增请求解析、私有地址限制和独立设置持久化测试；不是原生 XCTest 全量运行 |
| 实际 HTTPS API 集成 | `Tools/test_web_companion.mjs` 与 `build/web-api-tests-final.log`；curl 使用导出的根证书验证 TLS 链和主机名，不使用 `-k` |
| 浏览器端回归 | `Tools/test_web_reader.mjs` 与 `build/web-reader-tests.log`；独立 Chromium，手机/横屏视口、二维码同页面导航、XSS 文本、偏好/凭据、精修、回看、断开清空、重连、撤销 |
| iOS Safari | 专用 iOS 26.5 模拟器安装测试根证书后访问普通 `.local` 地址；`build/web-safari-live.png`、`build/web-safari-reopened-new-session.png`；真实 WebKit 页面、TLS 信任、字幕/精修、关闭 Safari 后重开恢复已观察 |

浏览器工具依赖安装在 `build/web-browser-tools`（agent-browser 0.36.0 与本地 Node 24），未替换系统 Node 或访问用户 Chrome 配置。自动化 Chrome 的 `.local` 导航挂起，通过只作用于测试实例的主机解析映射和禁用该实例代理后运行成功；不修改用户 VPN、DNS、浏览器或系统配置。Chromium UI 检查使用其测试实例的证书错误忽略选项，**不能用于证明 TLS 正确**；证书验证证据来自 curl 的显式 CA 校验与 Safari 模拟器安装根证书后的实际连接。

测试期间发现 Safari 已打开页面时，扫描同地址的新二维码会触发 hashchange 而非重载；已补上处理，并用“先开空白配对页、再改变邀请片段”的原路径通过回归。还将标题/设置保持可访问，避免实时滚动抢走设置操作。

## 复现

```sh
swift run -c release --jobs 2 CompanionProbe --web-fixture /已存在父目录/新的私有目录
# 等日志出现 WEB_FIXTURE_READY，再运行；测试顺序执行，不能共享控制文件并行。
node Tools/test_web_reader.mjs /上述私有目录
node Tools/test_web_companion.mjs /上述私有目录
python3 Tools/run_portable_tests.py
BUILD_JOBS=2 zsh scripts/build-app.sh
build/StreamTranslate.app/Contents/MacOS/StreamTranslate --companion-privacy-check
```

Fixture 仅使用合成文本，最长 15 分钟；邀请只写到新建的 0700 目录，不打印密钥。`command.txt` 为该显式开发工具的本地测试控制，不存在于正式 App。正常退出/信号处理会关监听并删除隔离的服务器叶私钥和配对凭据，过期公共证书/截图可保留为证据。

## 尚未验证与交付边界

- 未连接真实 iPhone：实际扫码/隔空投送/描述文件手工信任、主屏幕安装后存储行为、实际锁屏/应用切换快照隐私、Wi-Fi 稳定性与耗电仍待用户手机验收。模拟器导入证书不等同于已在用户手机完成安装。
- 浏览器 pagehide 自动化是显式派发事件的处理器回归，不代表已经完成真实手机锁屏测试。Safari 截图是模拟器，不伪称真实 iPhone。
- 没有用网页重跑 ASR/翻译质量基准，也未测端到端无线字幕延迟。现有模型不变，不能凭文字传输联调宣称准确率或无线速度提高。
- 冷启动时 Mac 必须可达；网页没有原生 Bonjour 浏览/Apple P2P 自动切换能力。证书一年和授权 90 天意味着不是永久零维护，但免除了免费原生包七天续签。
- 新包打包/签名完成不等于已替换正在运行的旧版，也不等于已在真实 iPhone 配置完成；安装状态以下方实际安装记录为准。

## 本次交付状态

- `build/StreamTranslate.app` 已构建为 1.3.1（12），使用本机 StreamTranslate Local Code Signing 身份签名，严格签名验证通过。
- `build/StreamTranslate-iPhone-HTTPS.mobileconfig` 是正式应用钥匙串身份对应的公开证书描述文件，已通过独立导出命令生成；导出没有开启音频采集或网络监听。
- 界面回归与 HTTPS API 回归顺序重跑均通过。合成测试服务已结束，隔离的测试私钥与网页配对凭据已清理。
- `/Applications/StreamTranslate.app` 的旧版本仍在运行；其日志最后一次采集状态是开始录音。为避免中断用户正在进行的翻译，已询问是否方便重启，尚未替换安装。得到确认后使用 `BUILD_JOBS=2 zsh scripts/install-local.sh` 备份旧包并更新。
- 真实 iPhone 上的证书安装、完全信任、扫码配对和添加到主屏幕需要用户操作，尚未完成。
