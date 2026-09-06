# 1.4.1 窗口交互修复

## 用户症状与复现

用户实际运行 1.4.0、字幕窗约 1158×958pt：从边框无法调整大小，点击手机图标看起来无响应。保留正在进行的采集，先在安装版上复现，再用隔离的真实窗口测试修复；不读取或上传字幕内容。

- 鼠标命中检查：右边框向内 1/3/6pt 的位置属于后面的应用，8/10/14pt 属于字幕 App。实际从内侧 10pt 拖动可把宽度从 1158 改为 1098，再恢复。这不是整个缩放算法失效，而是用户通常抓取的外边框没有接收事件。
- 真实鼠标点击手机按钮后，连接窗口已创建，但层级为 0，字幕窗为 3。大字幕窗挡住了连接窗口，重复点击也没有可见效果。`build/window-phone-click-before.log` 返回 `PHONE IN FRONT false`。
- `build/window-border-before.log` 显示 `EDGE MISSES CAPTION APP`；探针拒绝向后面的应用发送点击。

初始假设按证据排序：透明边距导致边框无法命中；连接窗口层级不正确；手势抢占/尺寸偏好回写冲突。内侧真实拖动正常，削弱第三项。分别修改前两项，并分别验证，未改动音频或翻译管线。

## 修复

1. `FloatingCaptionView` 对最外侧 6pt 缩放区域绘制低透明度边框底色，使 WindowServer 将鼠标事件送到本窗口，而不是穿透到后方。原来的边缘/角落缩放计算保持不变；操作态出现右下角缩放提示。
2. `openCompanionWindow()` 将用户明确打开的连接窗口置于字幕窗上方（层级 4），并支持加入当前桌面/全屏辅助空间。原有仅手机显示的入口保护仍在；不是把窗口设为无条件自动弹出。

## 正确的测试范围

此前仅测 `resizeEdges` 的计算、调用 `sendEvent`，无法发现 WindowServer 根本没有把鼠标事件发给 App。离屏截图也无法验证跨窗口遮挡。本次按 diagnose 技能增加了真实 WindowServer → AppKit → SwiftUI → 连接窗口的反馈回路。

`Tools/WindowInteractionProbe.swift` 使用已有辅助功能/事件发送授权，没有自动申请新权限。只操作明确指定的本项目 App；点击前检查真实鼠标命中属于目标窗口，拒绝点击其他窗口。拖动测试恢复窗口尺寸、位置和鼠标位置，只记录几何数据与按钮名称，不记录字幕。

`--window-interaction-fixture` 在正式窗口实现中注入隔离偏好与合成字幕，使用真实设置/尺寸观察回调，不启动录音、模型、监听或遥控文件循环。三分钟自动退出；正常退出删除该偏好域。探针 `--pid` 显式指定其 PID；省略时仅测试 `/Applications/StreamTranslate.app`。

验证日志：

- `build/window-edge-scan-after.log`：1/3/6/8/10/14/17pt 均命中字幕 App。
- `build/window-drag-{right-edge,left-edge,top-edge,bottom-edge,corner}-after.log`：四边与右下角通过系统鼠标事件改变尺寸，且恢复原尺寸；不是程序直接设置新尺寸充当拖动结果。
- `build/window-phone-click-after.log`、`build/window-phone-click-final.log`：点击手机按钮、关闭再点击，均 `PHONE IN FRONT true`，连接窗层级 4、字幕层级 3。
- 核心回归、隐私检查与正式安装后复测结果另见 `build/window-fix-*` 日志；未宣称实际全屏演示软件与所有多屏布局已经逐一验收。

复现命令（会移动鼠标/操作目标 App 的窗口，勿与人工操作并发）：

```sh
swiftc Tools/WindowInteractionProbe.swift -o build/WindowInteractionProbe
# 可先运行 build/StreamTranslate.app/Contents/MacOS/StreamTranslate --window-interaction-fixture
# 再追加 --pid 对应PID；下列省略 PID 时仅操作正式安装版。
build/WindowInteractionProbe inspect
build/WindowInteractionProbe close-phone
build/WindowInteractionProbe drag-right-edge
build/WindowInteractionProbe drag-left-edge
build/WindowInteractionProbe drag-top-edge
build/WindowInteractionProbe drag-bottom-edge
build/WindowInteractionProbe drag-corner
build/WindowInteractionProbe phone-click
```

后续防回归重点：带透明窗口装饰的命中测试必须经过 WindowServer，显式打开的控制窗口必须做实际遮挡与再次打开验证；不能只靠尺寸算法单元测试或“窗口存在”判断可用。

## 正式安装与最终回归

2026-09-06 已通过 `scripts/install-local.sh` 安装并启动 1.4.1（15），严格签名验证通过，保持原本地签名身份；旧 1.4.0 保存在 `/Applications/StreamTranslate.app.previous`，原有更早备份移入 `build/app-backups/`，未删除。安装日志：`build/install-1.4.1.log`。

- `build/window-fix-core-tests.log`：273 个核心测试体，0 个失败断言（CLT 顺序适配器，不是全量原生 XCTest）。
- `build/window-fix-privacy-check.log`：`visible=0, independentTranslationReady=true, pass=true`。
- `build/window-installed-edge-scan.log`：正式安装版外边框 1/3/6pt 已命中本应用。
- `build/window-installed-drag-{right-edge,left-edge,top-edge,bottom-edge,corner}.log`：原窗口 1158×958pt，四边和右下角真实拖动均按预期改变宽高；每项 `RESTORE VERIFIED true`，尺寸与位置均恢复。
- 测试工具首次恢复顶边拖动时发现：先设尺寸、后设位置会被屏幕可用高度约束截短。已改为先恢复位置、再恢复尺寸，并断言恢复结果；手动恢复原始几何后重跑了整套正式安装版检查。该问题属于测试工具，不是用户窗口缩放代码。
- `build/window-installed-phone-click.log`、`build/window-installed-phone-reopen.log`：实际点击与关闭后再次打开均 `PHONE IN FRONT true`，手机窗口层级 4、字幕窗层级 3。

正式 App 的模型与英中双向翻译会话已就绪，手机连接窗已打开。未自动恢复录音，未启用或代为确认明文网页分享；真实 iPhone 扫码连接仍需用户验收。隔离测试 App 已退出。
