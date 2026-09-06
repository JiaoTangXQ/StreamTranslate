# 1.4.2：手机全屏字幕阅读

## 用户需求与实现

手机屏幕优先留给字幕。移除阅读态固定标题、连接状态、页脚说明，不预留工具栏空间。字幕区使用 `100dvh` 对应的可用网页视口，保留刘海、横屏与主屏幕指示条的安全边距；Safari 自带的地址栏和系统状态栏不属于网页可强制隐藏的区域。

- 点一下阅读区，浮现 Aa 设置入口；三秒不操作自动收起。展开设置时不自动消失，点“完成”、外侧或 Escape 关闭。调整字号、原文开关不挤压字幕布局。
- 滑动不等于离开实时位置。只在阅读区有真实滚动、且距离底部超过 48px 时暂停跟随并显示“回到实时字幕”。手动滚回底部也自动恢复，无需再点按钮。
- 字幕连续增长、修订、字号变化、横竖屏切换不被当作用户回看；回看时不被新字幕拉回底部。触屏拖动不当作轻点。
- 控件隐藏时仍可用键盘 Tab 或阅读区 Enter/空格发现操作。文本选择不触发显隐。
- 断线清空旧字幕并保留恢复提示。配对、撤销、HTTP 风险确认、隐私遮罩、授权与内存存储边界不变。连接安全说明、引擎状态和亮屏说明放入按需展开的设置面板；没有去掉 Mac 首次开启 HTTP 的确认。

## 复现与诊断

按 agent-browser 与 diagnose 技能增加真实页面反馈回路，使用独立 CompanionProbe 凭据和合成字幕，不读取用户的音频或字幕。工程未配置技能的 issue tracker 等元信息，本轮沿用 CONTEXT.md，不创建项目管理配置或外部 issue。

旧版在 393×852 视口中顶部固定区高 196px；没有实际滚动，仅收到 wheel 事件也会显示返回提示。`build/reader-142-red.log` 在该断言失败。修改后顶部占位为 0，阅读区高度为 852。

三个判断分别验证：固定头部消耗布局；无条件滑动处理误入回看；缺少底部位置判断导致手动返回后仍暂停。采用独立滚动容器、输入意图与实际位置分离、布局变化只重定位实时模式解决。

额外发现 agent-browser 0.36 的独立 `mouse wheel` 命令把事件送到 (0,0)，并不沿用前一次 mouse move 的坐标。第一次“设置滚动失败”实际上事件命中阅读区。测试通过同一隔离浏览器的 CDP 明确发送坐标，随后真实设置滚动通过；没有为迁就测试修改页面行为。临时事件记录已移除，保留失败时的几何诊断。

## 验证证据

- `build/reader-142-green.log`：HTTP 快速连接 37 项页面检查通过，含明确坐标滚轮和触屏输入。
- `build/reader-142-secure-ui.log`：HTTPS 29 项页面检查通过。此 Chromium 测试为隔离自签名证书开启了忽略错误选项，仅证明 UI 行为，不作为 TLS 认证正确的证据。
- `build/reader-142-core-tests.log`：273 个核心测试体、0 失败断言；为现有 CLT 顺序适配器，不是全量原生 XCTest。
- `build/reader-142-privacy.log`：`visible=0, independentTranslationReady=true, pass=true`。
- `build/web-quick-reader-immersive.png`、`build/web-quick-reader-landscape-final.png`：全屏阅读与横屏布局。
- `build/reader-142-safari.png`：iOS 26.5 专用模拟器真实 Safari 加载新页面后，无顶部产品标题及状态区；仍可看到 Safari 系统地址栏。不是物理 iPhone 手势或扫码验收。

页面回归覆盖：配对、清除邀请片段、文本不作为 HTML 执行、字号/原文设置保存、设置内滚动、设置展开保持可用、长历史与增长草稿、回看时不抢位置、手动返回实时、连续更新中提示无闪现、轻点显示/闲置隐藏、实际触屏拖动与底部继续滑动、键盘入口、页面离开清空、横屏、会话切换、断线恢复、授权撤销。

测试入口仍是 `Tools/test_web_reader.mjs PRIVATE_FIXTURE_DIRECTORY`；隔离 `CompanionProbe --web-quick-fixture` / `--web-fixture` 提供真实 HTTP(S) 与 SSE。新增 `long-history` 和 `grow-draft` 合成场景，没有新增录音测试或生产字幕日志。

## 更新注意事项

手机已打开的页面可能只接收扫码产生的 fragment 导航，继续运行旧 DOM/JS。更新后必须刷新该页面才能显示新版；无服务工作线程或离线缓存。Mac 快速服务重启会按原安全策略清除授权，需新二维码配对，不能承诺旧邀请或凭据永久复用。桌面端不自动恢复录音。

## 本机交付

已通过 `scripts/install-local.sh` 安装并启动 1.4.2（16），严格签名验证通过，原本地签名身份未变化。旧 1.4.1 保存在 `/Applications/StreamTranslate.app.previous`；之前的备份移入 `build/app-backups/`，未删除。

正式运行版保留了用户此前已启用的快速网页分享选择。在正式服务 18444 上获取静态 HTML、JS、CSS 并核对新布局/新逻辑（`build/reader-142-installed.{html,js,css}`），没有读取用户字幕或配对凭据。`build/reader-142-installed-phone.log` 确认实际点击手机入口后连接窗口位于字幕窗上方。模型与英中双向翻译会话就绪，未自动开始录音。

所有本轮隔离浏览器已关闭，合成字幕服务已停止并清除专用测试凭据。安装日志：`build/install-1.4.2.log`。
