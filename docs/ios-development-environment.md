# iPhone 开发环境安装记录

安装开始：2026-09-05；更新：2026-09-06。用户已授权安装所需开发工具。

## 已完成

- 系统：macOS 26.4，Apple Silicon；开始时系统盘实际空闲约 5 GiB，故开发工具和构建产物放到外接盘。最新检查空闲约 35 GiB，未由本轮删除用户文件。
- 外接盘 `/Volumes/PortableSSD` 空闲约 762 GiB，但格式为 ExFAT。未格式化或调整现有分区，也未删除现有文件。
- 新建 APFS 稀疏磁盘映像：`/Volumes/PortableSSD/StreamTranslate-Development/StreamTranslateDev.sparseimage`。
- 挂载点：`/Volumes/StreamTranslateDev`。容量上限 100 GiB，按需增长，并非立即占用 100 GiB；刚创建时实际占用约 15 MiB。
- 使用 Homebrew 官方 cask 安装 `/Applications/Xcodes.app`（4.0.5b40）。这是第三方 Xcode 下载管理器，**不是完整 Xcode 本身**。
- 下载包 SHA-256：`e94e6971707db8c0faf81753ad92cd20ebefd0845e908c342d8fcdc7285d465c`，与上游 GitHub release 的摘要一致。
- 严格代码签名检查通过，Gatekeeper 评估为 `Notarized Developer ID`，签发身份 `Matt Kiazyk (ZU6GR6B2FY)`。
- Xcodes 的 `installPath` 配置为 `/Volumes/StreamTranslateDev/Applications`，`localPath` 配置为 `/Volumes/StreamTranslateDev/Downloads`，应用已打开。
- 用户已完成 Apple 账户登录；Xcode 26.6（Apple Silicon，17F113）下载完成，归档位于 `Downloads/Xcode-26.6.0+17F113.xip`，大小 2,318,258,791 字节。
- 默认 `/usr/bin/xip` 解压期间观察到系统盘余量快速下降到约 1.2 GiB，已对该次解压进程发送 SIGTERM，未删除用户数据。随后使用已签名 Xcodes 自带的 `unxip`，明确将工作目录、输出及 `TMPDIR` 指向外接开发空间，成功完成解压。
- 完整 Xcode 位于 `/Volumes/StreamTranslateDev/Applications/Xcode.app`。`codesign --verify --deep --strict` 通过；`spctl` 结果为 `accepted / Apple System / Software Signing`。证据：项目 `build/xcode-signature-check.log`。
- `xcodebuild -version` 已实际返回 `Xcode 26.6 / Build version 17F113`。iPhoneOS 26.5 和 iPhone Simulator 26.5 SDK 已就绪；本轮已安装 iOS 26.5（23F73）arm64 模拟器运行时，并启动专用测试设备。
- 全局 `xcode-select` 仍为原 Command Line Tools，未切换到外接盘。构建脚本已支持 `IOS_DERIVED_DATA_PATH`，以便将编译产物放在外接盘。
- 用户已完成管理员授权。`xcodebuild -runFirstLaunch` 返回 `Install Succeeded`，随后 `-checkFirstLaunchStatus` 返回 0；证据：`build/xcode-first-launch.log`。
- 真正的 iPhoneOS SDK 核心/UI 类型检查通过：`build/companion-shared-iphoneos-check.log`、`build/companion-phone-iphoneos-check.log`。
- **完整 arm64 iPhoneOS App 编译、链接和 bundle 校验通过**：`build/companion-phone-device-build.log` 与初次对照的 `build/companion-phone-target-build.log` 均为 `BUILD SUCCEEDED`。
- 产物：`/Volumes/StreamTranslateDev/DerivedData/phone-device/Build/Products/Debug-iphoneos/StreamTranslatePhone.app`，Debug 约 1.5 MiB。Mach-O 构建信息为 `platform IOS / minos 17.0 / sdk 26.5`，不是 Catalyst。
- 构建目标图只包含手机 App 与 CompanionKit，不编译 Mac 的 ASR/翻译模型、X509 或 WhisperKit。唯一警告为未使用 AppIntents 时跳过元数据提取，不是编译错误。

## 当前开发方式与后续真机步骤

下载、管理员授权、初始化和原生编译都已完成。用户已反馈完成账户登录，并明确选择先不连接 iPhone。当前继续使用模拟器开发，**无需连接手机或等待设备签名**。设备产物仍为未签名构建，尚不能安装到真实手机。

之后进行真机验收时才需要：

1. 连接要测试的 iPhone，解锁并按系统提示确认信任。
2. 确认 Xcode Apple Accounts 中的 Team 可用于开发签名；本轮不读取账户凭据，不擅自创建证书。
3. 在手机目标的 Signing & Capabilities 选择用户自己的 Team，按提示完成开发者模式与设备准备，再运行 App。

上轮钥匙串检查只有 Mac 本地签名身份；用户后续登录不等于本项目已完成设备签名。没有伪造 Team、描述文件或替代 iOS 签名。密码和验证码仅在系统/登录界面输入，不发送到聊天。

## 模拟器组件尝试与取舍

Xcode 26.6 的 scheme + `generic/platform=iOS` 在没有运行时时会报告平台未安装。曾开始下载 Apple 官方的 iOS 26.5 arm64 运行时（约 8.52 GB），并核对了系统 MobileAsset 元数据中的官方地址、大小和 SHA-256，尝试分段下载。

随后验证标准的 `xcodebuild -target StreamTranslatePhone -sdk iphoneos` 路径可在**不安装模拟器运行时**的情况下完成真正的设备 SDK 构建，更新构建脚本并暂时停止下载。用户选择先不连接手机后，恢复下载以支持模拟器开发。

最终完整下载 8,522,825,728 字节，SHA-256 为 `00aec28a0ad0a66e2722cf59f895a058c7b5a2c41bb68b5c2fe5f35d6c855b6d`，与 Apple MobileAsset 元数据一致。归档是 Apple 加密补丁格式，使用系统 `aa patch` 与该公开资产的归档元数据展开，再通过 `xcodebuild -importPlatform` 导入 DMG。系统验证结果为 `signatureState: Verified`；不修改或绕过签名。下载和展开文件保存在外接盘，官方导入的运行时镜像由系统保存在 `/Library/Developer/CoreSimulator/Images`（约 8.49 GB）。

证据：`build/ios-runtime-sha256.log`、`build/ios-runtime-hash-read.log`、`build/ios-runtime-patch.log`、`build/ios-runtime-import.log`。专用设备：`StreamTranslate QA`，UUID `4D7CF131-8544-493D-9A6C-847C2FAD9AAD`，iPhone 17 Pro / iOS 26.5；首次启动完成见 `build/phone-simulator-boot.log`。

首次测试遇到 `iOS 26.5 is not installed`，尽管 `simctl` 已能启动 App。对照发现当前 SDK 构建为 `23F81a`（SDK 元数据版本 26.5.1），默认映射指向不存在的同构建运行时；已安装运行时为 `23F73`。显式指定 Simulator SDK、等待启动均未解决；使用 Apple `simctl` 支持的映射后，`xcodebuild -showdestinations` 正常列出测试设备。没有切换全局 Xcode，也没有修改 Xcode 内部文件：

```sh
DEVELOPER_DIR=/Volumes/StreamTranslateDev/Applications/Xcode.app/Contents/Developer \
xcrun simctl runtime match set iphoneos26.5 23F73 --sdkBuild 23F81a
```

该本机映射只针对这个 SDK 构建；原始映射记录在 `build/phone-runtime-match-before.json`。以后安装匹配版本后可用同命令把 `23F73` 换成 `--default` 撤销。映射不写进跨机器构建脚本。对照证据：`build/phone-destinations-after-boot.log`、`build/phone-simulator-destinations.log`、`build/phone-destinations-matched.log`。实际 App 和界面测试结果见[模拟器验收记录](phone-simulator-verification.md)。真机仍须验证扫码、无线、锁屏与共享隐私。

## 安装完成后的继续验证

1. 工具签名、版本、首次初始化与原生设备构建已验证。
2. 优先使用项目级 `DEVELOPER_DIR`，避免不必要地切换全局命令行工具。
3. 继续将 DerivedData 和大型下载放在上述 APFS 开发空间；根据用户先不接手机的选择，安装所需模拟器运行时并进行 UI/字幕联调。
4. 真机验收阶段再配置用户的签名 Team 与真实 iPhone；编译或模拟器通过不等于真机已运行。
5. 真实手机还需要用户连接设备、确认信任与开发者模式，才能执行安装及双机测试。

初始化完成后，本机可使用以下命令先验证未签名 iPhoneOS 编译：

```sh
DEVELOPER_DIR=/Volumes/StreamTranslateDev/Applications/Xcode.app/Contents/Developer \
TMPDIR=/Volumes/StreamTranslateDev/Temporary \
IOS_DERIVED_DATA_PATH=/Volumes/StreamTranslateDev/DerivedData/phone-device \
IOS_DESTINATION='generic/platform=iOS' \
zsh scripts/build-phone.sh
```

这不是可安装到真机的签名包，之后仍需用户的签名 Team。

## 重新挂载

外接 SSD 需保持连接。重启后如挂载点不存在，可运行：

```sh
hdiutil attach /Volumes/PortableSSD/StreamTranslate-Development/StreamTranslateDev.sparseimage -nobrowse
```

拔出 SSD 前应先退出 Xcode、Xcodes、构建任务，再弹出 `StreamTranslateDev`，最后弹出 `PortableSSD`。不要在运行中拔盘。

## 来源

- [Apple Xcode 系统要求](https://developer.apple.com/xcode/system-requirements)
- [Apple Developer 下载](https://developer.apple.com/download/)
- [Apple 组件下载与安装说明](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)
- [Xcodes 上游项目与登录说明](https://github.com/XcodesOrg/XcodesApp)
- [本次安装的 Xcodes release](https://github.com/XcodesOrg/XcodesApp/releases/tag/v4.0.5b40)
