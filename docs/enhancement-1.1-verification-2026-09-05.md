# 1.1 增强版实现与本机验收

设备：Apple M4、16GB、macOS 26.4。版本：1.1.0，build 2。

## 已实施

1. `FinalizedCaptionText` 明确分开冻结的阅读画面与识别器的最终原文。历史、最终翻译使用 `recognizedText`，不再把早期冻结错误带入最终内容。旧音频范围的迟到 final 不会重置新范围的稳定前缀。
2. 草稿翻译保留增长量／句末触发，并增加基于单调时钟的 600ms 调度截止时间。待处理文字更新不会延长截止时间；没有后续识别回调时，定时器也会提交。若距上次请求已超过 600ms，新候选立即提交。最终结果、清空历史、新片段和语言变化取消过期定时器。
3. 草稿至少需要两个英文词或四个中文字符，避免把“大家好”的早期“大”译成“big”。完整短句仍走最终翻译，不受草稿门槛限制。
4. 新增 `apple-speech-transcriber-zh`：固定普通话、`zh_CN`、设备端连续识别；英文 ID 保持不变。自动模式保留 Whisper，手动选择的 Whisper 不被擅自替换。加载失败提供手动 Whisper 回退提示。
5. macOS 26.4 明确请求 Apple Translation `.lowLatency`；26.0–26.3 保持原配置。预期的草稿取消不再显示为翻译错误。
6. 标准 macOS 设置快捷键 ⌘, 接入实际设置页，不再打开 `EmptyView`。与菜单栏设置使用同一配置和视图模型。
7. 安装脚本保留上一版签名 App；已有旧回退副本移入 `build/app-backups/`，不直接删除。
8. 过滤识别器在完整句子之后单独产生的纯标点片段，避免出现只包含“。”及其译文“.”的字幕；短词和数字不被过滤。
9. 修复真实系统音频中最终范围去掉静音后，草稿未退场的问题。记录草稿起止范围；同一句的修剪 final 清除草稿、定时器及旧起点队列请求，而跨入后续音频的新草稿仍保留。

本版没有集成 Qwen 或 Hy-MT2，也没有增加常驻大型模型。此前实验只证明它们能在本机运行、量化和术语提示有收益，尚不足以支持把大模型精修作为默认路径。后续可选精修仍需真实内容对照及并发负载验证。

## 自动回归

测试源码共 213 个用例。本机 CLT 缺少 `Testing` 模块，未宣称运行了标准 Xcode/Swift Testing 全套。

`python3 Tools/run_portable_tests.py` 使用明确的顺序断言适配器，编译真实生产 Swift 源码并执行 **165 个核心测试用例**。原始测试文件未为适配器改写；生成副本位于 `build/portable-tests/`。四个涉及窗口事件或共享日志的文件（48 个测试）明确排除，不计入通过数；最终断言结果见验收日志。

新增覆盖包含：

- 冻结前缀已经错误时，最终英文纠正进入历史；中文数字与否定纠正保留。
- 少量新增文字即使没有下一次 ASR 回调，也能触发截止时间提交。
- 连续新候选合并为最新文本而不重置截止时间。
- final／清空历史／新片段／语言切换取消过期任务。
- 单个中文字符不会在计时器到期后绕过上下文门槛；完整短句仍提交历史。
- 较旧片段 final 不破坏新片段稳定前缀。
- 中英文模型能力、自动模式回退、持久化及旧配置迁移。
- macOS 26.4 两个翻译方向均选择低延迟策略。
- 纯标点不是语音；“好”“15%”这样的短结果仍然有效。
- 实际捕获的范围变化 `partial 0–309120 → final 75840–304320`：最终结果必须清掉原草稿及待译请求；稍微重叠但进入新音频的草稿不能被旧 final 清除。修复前这条回归有两个断言失败，记录在 `build/portable-tests-duplicate-red.log`。

## 对照一：最终内容纠正

完全相同的识别序列中，早期 partial 为 `I want to discuss ...`，随后模型最终结果为：

```text
We should discuss the deployment process today.
```

旧实现会把冻结后的 `I want to discuss the deployment process today.` 传给历史和翻译。新实现保留实时稳定阅读，但最终历史和翻译源使用完整的 `We should ...`。这项收益来自修复已确认的数据流问题，不依赖更大模型。

## 对照二：真实识别序列上的翻译调度

使用既有合成音频，按真实速度每 100ms 输入一批，经过生产 Apple 识别、CaptionViewModel、草稿队列、最终批量翻译。另一个只读观察器在**同一组 ASR 回调**上运行旧增长量规则，记录旧规则何时会发请求。不是同时运行两版 App，也不是完整旧版端到端测速。

| 音频 | 旧规则草稿请求数 | 新版实际草稿请求数 | 同一片段内请求间隔中位：旧 → 新 |
| --- | ---: | ---: | ---: |
| 英文 6.858 秒 | 3 | 6 | 1.010 → 0.605 秒 |
| 中文 13.089 秒 | 5 | 16 | 2.592 → 0.607 秒 |
| 中文 70.244 秒（五次重复，中间 1.2 秒静音） | 25 | 89 | 2.846 → 0.606 秒 |

这里测的是请求间隔，不是单个字的等待时间，更不是“整体速度提升四倍”。增加请求次数会增加工作量；600ms 是折中参数，不是所有设备和内容的最优值。上下文门槛会主动抑制过早的单字翻译，不能把首个无意义译文变慢当成实用速度倒退。

## 完整流程结果

| 音频 | 首个原文 | 首个可见译文 | 音频结束至最后画面更新 | 进程峰值 RSS |
| --- | ---: | ---: | ---: | ---: |
| 英文 6.858 秒 | 1.131 s | 2.405 s | 0.130 s | 28.5 MB |
| 中文 13.089 秒 | 1.150 s | 3.142 s | 0.229 s | 30.1 MB |
| 中文 70.244 秒 | 1.128 s | 3.141 s | 0.130 s | 37.8 MB |

最后一轮状态均为空，没有翻译错误。70.244 秒输入的总运行时间为 70.396 秒，没有观察到持续积压。该长度不是多小时稳定性或能耗验收。

RSS 不包含 Apple XPC／系统模型服务，不能说整个系统只用了几十 MB。测试未关闭用户其他应用，没有保证零 swap。未增加额外大模型，是控制本轮资源预算的主要方式。

## 识别准确度边界与 Whisper 对照

短中文原文中的 15%、不是 50%、五分钟均保留，译文完整。70 秒五次重复中，有一次把“字幕”识别为“字母”，随后译成 alphabet。这是识别错误，不是本版最终文本分离规则能够凭空修正的错误。

Whisper Small 用相同 13.089 秒中文、固定中文提示的整段对照：加载 25.995 秒，整段推理 0.634 秒，输出包含“十十字幕”，其余主要内容和数字保留。它是整段离线耗时，不能与原生流式的首字／首译时间直接比较。

因此保留 Whisper 手动选择；不能根据这组 TTS 就断言 Apple 在所有中文、口音或真实会议中更准。真实语音重叠、专业术语、远场噪声仍需进一步验收。

## 部署与可恢复性

- 安装位置：`/Applications/StreamTranslate.app`。
- 版本：1.1.0，build 2。
- 继续使用固定本地签名证书，designated requirement 绑定同一个证书哈希 `56805944a260c023b62ec7035984033186211bb7`，不是随机 ad-hoc 签名。
- 本轮升级前 App：`build/enhancement-baseline/StreamTranslate.app`；设置快照：同目录 `preferences.plist`。
- 安装器还保留 `/Applications/StreamTranslate.app.previous`；连续安装的更早副本在 `build/app-backups/`。
- 原有用户配置保留，包括用户选定的 Whisper Small／英文／System Audio，以及字号和浮窗尺寸。不会为了展示新后端强制改变用户的模型选择。

安装后通过实际 UI 打开设置，并切换到 Apple 中文，验证模型准备与语言联动。使用已有 System Audio 权限播放中文合成语音，App 成功显示完整原文和英文译文，包含 15%、不是 50% 和五分钟。实机检查发现独立句号字幕及停止后的重复草稿，随后分别增加过滤和范围生命周期修复。诊断过程先用捕获日志确认 final 修剪静音、改变起点，再写出失败回归并验证修复；没有额外创建工单系统或协作规范。最终 **165 项核心用例零失败**。

真实 System Audio 原场景重新播放后，停止画面只有一份完整字幕，且最终译文为 five minutes，不再残留旧草稿的 five points。前后截图为 `build/enhancement-replay/duplicate-before-fix.png` 和 `installed-caption-fixed.png`。诊断范围证据在 `~/Library/Logs/StreamTranslate/Sessions/2026-09-05_14-53-49_DCFB2F13/`，修复后证据在 `2026-09-05_14-55-59_C0E2CCE5/`。诊断仅用于本地合成语音复测，正常使用关闭。

最后恢复 Whisper Small／英文／System Audio，字号 22、浮窗 434×958 保持不变，关闭诊断录制。安装版再经系统音频播放 6.858 秒英文，完整显示原文及“会议将在五分钟后开始”的中文，停止后无重复行；证据为 `installed-whisper-final-smoke.log` 和 `installed-whisper-final.png`。这次重启 Whisper 模型准备耗时约 55 秒，说明冷启动仍有优化空间，不能把此前约 26 秒加载或流式处理指标说成每次启动保证。最终 App 已准备好、录音已停止。

## 复测入口与证据

```sh
python3 Tools/run_portable_tests.py
python3 Tools/build_local_tool.py Tools/EnhancementReplayMain.swift build/enhancement-replay/EnhancementReplay
build/enhancement-replay/EnhancementReplay build/verification/chinese.wav zh
python3 Tools/analyze_enhancement_replay.py build/enhancement-replay/chinese-final.jsonl
```

原始证据位于 `build/portable-tests-installed.log`、`build/enhancement-replay/*final*`、`build/enhancement-replay/comparison.jsonl`、`build/enhancement-install-final.log`。回放程序只读取指定音频，不打开麦克风或系统录音。`build/` 文件为本机实验产物，由 Git 忽略。
