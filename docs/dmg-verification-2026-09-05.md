# DMG 交付验收 — 2026-09-05

交付：StreamTranslate 1.2.1 build 10，Apple Silicon / macOS 26+ 完整模型版。

文件：`/Volumes/PortableSSD/StreamTranslate-Distribution/release-build10/StreamTranslate-1.2.1-10-AppleSilicon-Local-Unnotarized.dmg`

- 大小：2,308,330,609 字节（约 2.31GB）。
- SHA-256：`b8c82fa9b9e1cdc9d4f2841b51c6d884a366686ccf89b043e90bf67760cbecaa`。
- DMG 内含 App、指向 `/Applications` 的快捷入口、中文安装说明。
- App 内含 Qwen3-ASR 0.6B Q8 / Hy-MT2 1.8B Q4_K_M、原生运行时及许可。
- 没有分发用户偏好、录音、日志、Python 环境或签名私钥。
- 当前 `/Applications/StreamTranslate.app` 原安装未替换，仍可使用其本机优化运行库。

## 已验证

1. 234 项核心测试通过，包括新增 5 项随包模型解析测试。使用 CLT 的顺序断言适配器；不是完整 Xcode UI 测试。
2. 模型文件为实际数据而非外盘软链接；SHA-256 与既有验收权重一致。
3. 28 个 Mach-O 文件的 arm64 架构、动态库相对路径、逐项签名及完整 App 签名通过校验。
4. 校验 18 项必要许可/归属文件；另保留模型卡。包含 llama.cpp 所用 JSON、HTTP、hash、UI vendor 及固定版本 BoringSSL 的许可。
5. `hdiutil verify` 验证最终 DMG 的 CRC 完整性通过。
6. 从最终 DMG 只读挂载路径，用独立临时 HOME、私有 Unix socket 实际运行两套模型成功；未录制实时音频。
7. 最终随包 Qwen 正确识别否定、条件及百分比测试句，推理约 0.488 秒；Hy-MT 输出“在备份完成之前，不要重启服务器。”，请求约 0.209 秒。这是单句功能检查，不是端到端延迟结论。
8. 通用 CPU 基线 Qwen 额外通过 14 段音频（8 段真人朗读、6 段合成语音）；输出与此前本机 native 构建的对应记录逐字一致。没有据此保证所有输入精度完全相同。

证据：`build/dmg-tests.log`、`build/dmg-qwen-portable-comparison.json`、
`build/dmg-qwen-portable-corpus.jsonl`、`build/dmg-shipping-smoke.json`、
`build/dmg-final-verify.log`，以及 DMG 旁的 `.audit.json` / `.dmg.sha256`。

## 分发限制与修正

- **没有 Apple Developer ID 和公证。** 使用现有本地证书签名；同一分发代码候选的 Gatekeeper 检查返回 `rejected`、退出码 3。
  后续只补充许可并重新签名/封装，没有获得 Apple 公证，不能承诺接收方直接打开。
- 尚未在另一台干净 Mac 或 M1/M2 实机上完成安装验证；Apple 语言资源下载和系统权限仍须在接收方首次配置。
- 发现旧 Qwen 含 M4 native CPU 指令，改为 `apple-m1` / `GGML_NATIVE=OFF` / ARMv8.2 + dotprod + fp16，保留 Metal。详见分发文档的来源证据。
- ExFAT 工作目录产生 AppleDouble 签名干扰，改为外盘承载的 HFS+ 暂存映像；最终 App 校验不含这类文件。
- 兼容系统 Python 3.9 的散列实现；没有要求接收方安装 Python。
- 打包排查期间从保留的暂存映像继续完成最终封装，未再完整重跑所有构建步骤。最终产物已单独验证；最终压缩使用 zlib level 1，脚本默认 level 6。
- 中间候选保留在外盘的 `rejected-m4-native` / `intermediate-packages`，不要发送这些文件。

操作说明及开发者签名流程见 [DMG 分发](dmg-distribution.md)。
