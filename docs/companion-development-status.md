# 手机私密字幕开发状态与试用说明

更新：2026-09-06。Mac 开发预览：1.3.0（11）；iPhone 开发版本：0.1.0（1）。

## 已经实现

- Mac 使用 macOS 26 的 installedSource 翻译会话，不再依赖悬浮字幕视图；语言包缺失时在非私密模式进行准备。
- 菜单栏新增“手机字幕”，服务默认关闭；支持普通局域网和显式开启的 Apple 点对点 Wi-Fi。
- 两分钟有效、一次性二维码/链接配对；一次只授权一部手机。手机固定验证 Mac 证书指纹，实际数据使用 TLS 1.3；凭据保存在 Keychain，Mac 可以撤销。
- 原文、译文、引擎状态的有界快照与增量协议；同一字幕 ID 的精修覆盖、序列缺口重同步、清空和会话切换。新录音不会向手机带出上一场字幕，Mac 历史仍保留。
- 发送队列/数据帧限制、认证和快照超时、前台心跳、退避重连；认证失效给出重新配对提示，不无限重复发送旧凭据。
- 持久化“仅手机显示”；隐藏桌面字幕、历史、设置与配对窗口，拦截恢复入口，断线不恢复桌面字幕。
- 原生 iPhone 阅读界面、二维码扫描/粘贴链接、横竖屏、字号、原文开关、回看/回到实时、观看时亮屏、回前台恢复及 App 切换隐私遮挡。
- iPhone 目标不依赖任何语音或翻译模型，也不构建仅供 Mac 生成证书使用的 X509 依赖。

## 验证结果和边界

| 项目 | 结果与证据 |
|---|---|
| Mac Release 编译 | 通过；`build/companion-app-build.log` |
| 核心回归 | 263 个测试体、0 个失败断言；`build/companion-portable-tests.log`。这是 CLT 下的顺序断言适配器，不是完整 Swift Testing/XCTest 运行器；原有 UI/共享日志测试的排除情况会在日志列出 |
| 无窗口翻译 | 已安装的中英双向实际翻译通过；上述日志包含 `HEADLESS TRANSLATION`。没有录制音频 |
| 私密窗口进程检查 | `--companion-privacy-check` 使用隔离偏好与合成字幕，验证启动、重开、历史、设置、配对、下载入口不会显示窗口，同时独立翻译就绪；`build/companion-privacy-check.log` |
| 本机 TLS 集成 | `CompanionProbe --loopback` 验证错误证书指纹、错误邀请、成功配对、实际 TLS 1.3 协商、精修覆盖、10 次重连、18 秒安静期心跳、清空/新会话、撤销与拒绝旧凭据；`build/companion-loopback.log` |
| iPhone 共享核心和 UI 类型检查 | 原先 Catalyst 检查通过；现已通过真正的 iPhoneOS SDK 检查，见 `build/companion-shared-iphoneos-check.log`、`build/companion-phone-iphoneos-check.log` |
| Xcode 工程 | 已用 XcodeGen 2.46.0 成功生成，包含 `StreamTranslatePhone`；生成器从上游 release 下载并验证 SHA-256，未全局安装 |
| iPhone 实际构建 | **未签名 arm64 iPhoneOS Debug 构建通过**，包括链接和 bundle 校验；`build/companion-phone-device-build.log`。SDK 26.5、最低 iOS 17.0；不是 Catalyst，也不是可直接装机的签名包 |
| 原生 Simulator UI 测试 | iOS 26.5 / iPhone 17 Pro，5 项 XCTest UI 测试全部通过；`build/phone-ui-tests-final.log`、`build/phone-ui-20260906-003401.xcresult` |
| 原生手机界面字幕联调 | 正常 Bonjour/TLS 合成字幕显示、终止后重开自动恢复当前快照、精修后的正文、新会话清空、停服后隐藏旧字幕已观察；截图与边界见[模拟器验收](phone-simulator-verification.md)。不是实体无线测试 |

上述 loopback 测试只使用本机回环地址、合成文本、独立测试 Keychain 账户，不广播 Bonjour、不捕获音频。临时测试凭据在结束时删除。不能据此推断真实无线延迟、扫码体验、耗电或两小时稳定性已经达标。

## 尚未完成，不能当成发布能力

1. iOS 签名、真机安装、相机扫码、锁屏/后台/强退恢复的实机验证；模拟器已安装并启动 App，模拟器结果不能替代真机验收。
2. 真正的 Mac ↔ iPhone 局域网与 Apple 直连、访客网/VPN/防火墙、两小时长时与 100 次恢复循环。
3. 与视频、会议共享、AirDrop/AirPlay 同时运行的无线共存测试，以及实际共享接收方的隐私验收。
4. QUIC 对照和自动 LAN/P2P 切换。本预览仅提供 TCP + TLS 与两端明确启用的试验性 P2P，不假装系统已自动选到最优路径。
5. App Store/TestFlight 发布、手机正式图标与上架材料；当前本机签名不能代替 Apple Developer 分发签名/公证。

## 本机已有的开发产物

- Mac 预览 App：`build/StreamTranslate.app`，已使用本机开发证书签名并通过严格签名校验，不是对外公证版。原有 `/Applications/StreamTranslate.app` 稳定版及先前 DMG 未替换。不要与稳定版同时启动，以免两个进程竞争录音、模型及偏好设置。
- iPhone 工程：`StreamTranslate.xcodeproj` 中的 `StreamTranslatePhone` scheme。
- iPhone 未签名 App：`/Volumes/StreamTranslateDev/DerivedData/phone-device/Build/Products/Debug-iphoneos/StreamTranslatePhone.app`，当前 Debug 约 1.5 MiB，无识别/翻译模型。
- 工程源配置：`project.yml`。生成工程按仓库既有规则被 Git 忽略，另一台机器需要重新生成。
- 可复用核心：`CompanionKit`。iOS 与 Mac 使用同一协议和客户端实现。

本次不重打包含大模型的 DMG：手机安装与无线验收尚未完成，现有稳定分发包继续保留。

## 接下来需要的环境

安装进展更新：完整 Xcode 26.6 已安装、通过 Apple 签名与系统安全检查，并完成首次初始化和 iPhoneOS 原生编译。用户已反馈完成账户登录，选择暂不连接 iPhone；当前直接使用 iOS 26.5 模拟器开发，不再把真机连接作为开发前置。真机签名尚未验证。详见[开发环境安装记录](ios-development-environment.md)和[不接手机的验收记录](phone-simulator-verification.md)。

全局活动开发目录仍为 Command Line Tools，本机使用项目级 `DEVELOPER_DIR` 指向外接盘 Xcode；完整命令见上述安装记录。

安装 Xcode 后，可在工程根目录运行：

```sh
zsh scripts/build-phone.sh
```

脚本默认使用直接目标方式生成 **未签名的 iPhoneOS Debug 构建**，无需模拟器运行时，不生成可安装到真实 iPhone 的 IPA。设置 `IOS_DESTINATION='generic/platform=iOS Simulator'` 可选择模拟器 scheme 构建，但需要其运行时。真机请打开 `StreamTranslate.xcodeproj`，选择 `StreamTranslatePhone`，在 Signing & Capabilities 选择你自己的 Team，再选择已连接的 iPhone 按 Xcode 提示运行。没有伪造 Team ID 或使用本机自签证书替代 iOS 签名。

另一个环境若缺少生成器，可安装 XcodeGen，或将 `XCODEGEN_PATH` 指向其可执行文件。

## 真机可用后的使用顺序

1. 演示之前启动 Mac App，完成音源权限和语言包准备。
2. 菜单栏 → 手机字幕 → 开启服务 → 生成配对二维码。
3. iPhone App 扫码。默认两端在能互通的局域网；P2P 需双方同时开启，Wi-Fi 保持开启，仍属试验路线。
4. 确认手机已收到字幕，再在 Mac 点击“进入仅手机显示模式”。Mac 录音仍由用户在 Mac 开启，手机端不会擅自启动采集。
5. 通过菜单栏图标可以停止录音，或明确退出仅手机模式。手机断开不弹桌面字幕。
6. 更换手机：先在 Mac 解除旧配对，再生成新邀请。电脑、服务或网络不可达时，手机显示等待/离线，不能承诺远程唤醒电脑。

不要在共享屏幕时展示配对二维码；复制链接会写入剪贴板，仅应在可信环境中使用。OS 自身的录音/屏幕采集隐私指示不在隐藏范围内。

## 复现验证

```sh
python3 Tools/run_portable_tests.py
swift run -c release --disable-build-manifest-caching --jobs 4 CompanionProbe --loopback
zsh scripts/build-app.sh
build/StreamTranslate.app/Contents/MacOS/StreamTranslate --companion-privacy-check
```

`CompanionProbe` 是显式测试工具，未加入 iPhone 或 Mac App 的常规启动流程。服务仅在用户开启后运行。后续自动路径选择和性能优化，以[调研报告](apple-companion-transport-research-2026-09-05.md)中的双机门槛为准。
