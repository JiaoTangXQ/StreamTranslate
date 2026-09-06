# DMG 分发

完整模型版支持 Apple Silicon / macOS 26+，建议 16GB 内存。双击 DMG 后将 App 拖至 Applications；
这不是自动安装的 PKG。App 内含两个默认增强模型及原生 Metal 运行时，不依赖开发机的模型路径。
Apple 语言资源及系统权限仍需在接收方电脑首次配置；Intel 及旧版 macOS 不受支持。

## 构建

```sh
zsh scripts/build-dmg.sh /path/to/output-directory
```

输出磁盘至少需要 10GiB 可用空间。脚本保留独立临时 staging 供核查，不覆盖已有发布文件。
输入为现有 `~/Library/Application Support/StreamTranslate/{Qwen,HyMT}` 安装；
可通过 `MODEL_SUPPORT_DIR` 指定另一个已备齐运行时、许可证和模型的目录。
Qwen 从固定版本源码重新编译为 M1 基线，不复用可能含 M4 专用指令的本机运行库。
源码默认位于 `build/refinement/qwen-cpp-src`，可通过 `QWEN_SOURCE_DIR` 指定；
`CMAKE_BIN` 可指定 CMake 可执行文件。编译命令禁止 `-march=native` / `-mcpu=native`。
它不是任意模型打包器：默认模型 SHA-256 不匹配即失败。

打包过程构建 Release、复制实际权重（不保留外盘软链接）、收集许可和来源说明、
逐项签名原生组件、校验动态库路径和模型散列，生成压缩 DMG 及外部 SHA-256 / 审计清单。
临时构建依赖、Python、测试录音、日志和用户设置不随包分发。

## 签名与公证

默认 `StreamTranslate Local Code Signing` 仅用于本地签名完整性，**不是 Apple Developer ID**。
生成文件明确带 `Local-Unnotarized` 标记，不能保证在接收方 Gatekeeper 下直接打开。
不要为了安装而全局禁用安全检查；企业管理策略可能直接禁止本地签名 App。

获得开发者自己的证书和已配置的 Keychain 公证 profile 后，可使用：

```sh
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-existing-keychain-profile' \
zsh scripts/build-dmg.sh /path/to/new-output-directory
```

脚本不会代为注册开发者、导出私钥或创建账户。上述流程需联网提交 DMG 给 Apple，成功后附加公证票据。
审计 JSON 中的 Gatekeeper 字段只记录本地静态审计，并不代替公证结果。
正式发布仍应在另一台开启 Gatekeeper、经浏览器下载带 quarantine 标记的 Mac 上验证首次安装。

Apple 参考：[Developer ID](https://developer.apple.com/developer-id/)、
[公证软件](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。

## 验证

```sh
python3 Tools/run_portable_tests.py
python3 Tools/verify_distribution.py '/path/to/StreamTranslate.app'
python3 Tools/smoke_distribution.py '/path/to/StreamTranslate.app' '/path/to/test.wav'
hdiutil verify '/path/to/release.dmg'
```

原生 smoke 使用随包权重、清空的 HOME 环境及私有 Unix socket，不录制实时音频；
它不能代替干净 Mac 上的 Apple 语言资源下载、系统权限和 Gatekeeper 验证。
开发机原来的小体积安装仍可通过本地 Application Support 使用外盘模型；
新的完整 DMG 安装则优先使用 App 内模型，不混用开发机的同名旧模型。

## CPU 兼容性检查

本机旧 Qwen 编译命令含 `-march=native` 和 `-mcpu=native+dotprod+i8mm+nosve+sme`，
因此不能直接把它当成 M1 通用二进制分发。分发构建使用 `-mcpu=apple-m1`、
`GGML_NATIVE=OFF` 和 `armv8.2-a+dotprod+fp16`；保留 Metal 加速，未改模型权重。
上游 CMake 在 Release 中直接添加 native 参数，所以使用 RelWithDebInfo 配置并显式
覆盖为 `-O3 -DNDEBUG`（无调试信息），避免改变已固定的上游源码。

Hy-MT 使用的官方 llama.cpp b10809 发布流程选择标准 `macos-26` arm64 runner，
GitHub 将其硬件列为 M1。这是构建来源证据，不等于在接收方电脑实测成功。
参考：[该版本发布流程](https://github.com/ggml-org/llama.cpp/blob/b10809/.github/workflows/release.yml)、
[GitHub runner 规格](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。
本轮实际执行测试仍只有这台 M4；M1/M2 及干净系统首次安装需额外设备验收。
