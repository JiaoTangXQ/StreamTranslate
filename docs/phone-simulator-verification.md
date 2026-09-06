# 不连接 iPhone 的开发与验收

日期：2026-09-06。用户明确选择暂不连接 iPhone，继续开发；真实手机不作为本轮开发前置条件。

## 本轮范围

1. 原生 iPhoneOS 与 Simulator 编译、手机界面自动化测试。
2. 正常 TLS/Bonjour 路径的合成字幕测试，不录音、不调用模型、不读取真实字幕。
3. 回归已有协议、权限撤销和重连检查。
4. 真机无线、相机扫码、锁屏行为、耗电和共享接收端隐私继续列为后续验收，不能由模拟器结果替代。

## 代码变化

- 手机断线恢复和切换字幕会话时重新跟随最新内容，避免延续上次的历史回看位置。
- 连接断开/新建时清除旧 TLS 协商状态；回归测试验证暂停后的文本和连接状态均清空。
- 为手机页面增加稳定的无障碍测试标识，不影响正常显示。
- 增加 `StreamTranslatePhoneUITests` 和五项离线 UI 检查：初次打开、无效配对链接、阅读偏好持久化、横竖屏、返回前台。
- 仅在 **Debug + iOS Simulator** 编译条件下接受 `--ui-testing-reset`，清理该模拟器内本 App 的偏好和配对；真机和 Release 不包含此入口。
- 增加 `CompanionProbe --simulator-fixture NEW_PRIVATE_DIRECTORY`：最多运行 240 秒的合成字幕服务，正常广播 Bonjour、使用证书固定验证和一次性邀请。邀请只写到新建的 0700 私有目录，不输出到日志。正常结束或 SIGINT/SIGTERM 会关闭监听并清理该次专用 Keychain 账户。

## 可复现命令

原生未签名 iPhoneOS 构建仍使用 `scripts/build-phone.sh`。UI 测试需要已安装的模拟器运行时和专门用于本项目的模拟器，不需要真实 iPhone 或 Apple 签名账户：

```sh
DEVELOPER_DIR=/Volumes/StreamTranslateDev/Applications/Xcode.app/Contents/Developer \
TMPDIR=/Volumes/StreamTranslateDev/Temporary \
IOS_SIMULATOR_ID=你的专用测试模拟器UUID \
IOS_DERIVED_DATA_PATH=/Volumes/StreamTranslateDev/DerivedData/phone-simulator \
zsh scripts/test-phone-ui.sh
```

测试结果写入新的 `.xcresult`，脚本拒绝覆盖已有结果。测试会重置模拟器中的本 App，请勿用该测试模式保存需要保留的配对。

合成字幕服务只用于开发：

```sh
swift run -c release CompanionProbe --simulator-fixture /某个已有父目录/全新的私有目录
```

启动后，使用该目录中的 `invitation.txt` 配对手机模拟器。配对仍有两分钟有效期，不绕过真实连接的安全检查。合成内容会每秒更新，20 秒时覆盖同一条字幕的译文，60 秒时切换新会话并清空上一场字幕。结束后模拟器上遗留的测试配对不再可用，可使用 UI 测试重置或“移除本机配对”清除。

## 验证状态

- iOS 26.5（23F73）arm64 运行时已下载、完整 SHA-256 校验、系统签名验证、安装并启动；设备为专用 `StreamTranslate QA` / iPhone 17 Pro。Xcode 的 SDK/运行时构建映射问题已用官方命令解决，过程和可撤销方式见[开发环境记录](ios-development-environment.md)。
- 真正的原生 XCTest UI 测试 **5 项通过、0 失败**，耗时 57.54 秒。证据：`build/phone-ui-tests-final.log`、`build/phone-ui-20260906-003401.xcresult`、`build/phone-ui-tests-summary.json`。不是用可移植断言适配器替代 UI 执行。
- 初次运行 4/5 通过；通过增加“切换后立即断言”定位到测试点击的是 SwiftUI Switch 的整行中心，而非右侧开关，未改变状态。修正测试点击位置后全部通过；没有为了通过测试而更改偏好保存逻辑。复现证据：`build/phone-ui-tests-matched.log`、`build/phone-ui-toggle-repro.log`。
- iPhoneOS 原生未签名构建通过：`build/companion-phone-device-build.log`。Simulator App 与 UI runner 原生编译通过：`build/phone-ui-test-build.log`。模拟器 Debug 重置入口不编入真实 iPhone 构建，已检查两个二进制。
- 核心回归仍为 **263 个测试体、0 失败断言**：`build/companion-portable-tests.log`，这是 CLT 顺序适配器，不能称为 263 项原生 XCTest。实际 localhost TLS 集成含 10 次重连、18 秒无字幕心跳、撤销和断开状态清理，通过：`build/companion-loopback.log`。
- 正常 Bonjour + 固定证书 TLS 路径已把合成英文原文与中文翻译显示在原生 iPhone 模拟器；截图 `build/phone-simulator-live.png` 显示实时计数 9 和“已连接 · 加密传输”。没有替换客户端为 mock。
- 终止手机 App，等待 15 秒后不携带配对链接重新打开，自动恢复认证并显示当前快照；截图 `build/phone-simulator-reconnected.png` 显示计数 43 和已经修订的第一条译文。服务日志 `build/phone-simulator-fixture.log` 记录断开、同 ID 精修、重新连接。
- 在线切换新会议，旧字幕清空且实时更新继续：`build/phone-simulator-new-session.png` 显示仅新会话内容和计数 68。
- 停止合成服务后，手机转为等待连接且不再展示旧字幕：`build/phone-simulator-offline.png`。测试服务已关闭并清理其独立 Keychain 身份；未录音、未调用模型、未启动或替换用户的稳定 Mac App。

当前完成的是本机模拟器验证，不等于 iPhone 无线延迟、长时间稳定性、相机扫码、锁屏或手机耗电已经验收。首次读取链接时系统可能要求确认“在私密字幕中打开”，后续自动恢复不依赖重复扫码。
