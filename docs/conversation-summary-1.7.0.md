# 本机对话总结 · 1.7.0

悬浮字幕窗右侧的 **总结** 默认折叠。首次展开后，在本机生成「在聊什么、主要内容」两部分中文摘要；后续新增内容通过 **更新总结 · 有新内容** 手动更新。

## 内容范围

- 输入是本次开始收音以来已完成字幕的完整原文，从本机会话归档读取，包含移出 100 条实时缓存的早期字幕；尚未完成的流式一句不参与。
- 首次生成分段处理全部原文，每段连同此前摘要生成下一版；后续更新只处理新增字幕，并保留此前摘要。若早期原文发生修正，下次更新重新处理完整会话。
- 总结只属于当前收音会话。清空记录或开始新会话会清除摘要；重启 App 后摘要不保留，原有文字历史仍可在历史窗口查看。
- 摘要是 AI 对原文的压缩，可能遗漏、误述或错误归类；多次压缩也可能损失早期细节。决定、数字和未定事项以原文为准。

侧栏覆盖在字幕右侧，展开不重新压缩字幕的排版宽度。若窗口原高度低于 300pt，展开时暂时增高到 300pt，折叠后恢复保存的高度偏好。沿用原生深色界面。

## 安装

总结使用独立的 **Qwen3-4B-Instruct-2507 Q4_K_M**，不复用语音识别或翻译模型。需要先有可运行的 llama.cpp `llama-server` 及其同目录依赖。若已安装可选 Hy-MT 运行时，在项目根目录执行：

```sh
zsh scripts/install-summary-local.sh
```

默认从 `~/Library/Application Support/StreamTranslate/HyMT/runtime/` 复制运行时。也可指定已有运行时目录：

```sh
zsh scripts/install-summary-local.sh /path/to/llama.cpp/runtime
```

脚本不编译或自动安装 llama.cpp；缺少可执行的 `llama-server` 时会停止。安装结果位于 `~/Library/Application Support/StreamTranslate/Summary/`；已有 Summary 安装先保留到同级备份目录。下载模型为 2,497,280,448 字节，另需运行时、暂存及旧安装备份空间。当前 DMG 打包脚本尚未包含此总结模型，需要单独安装；模型权重不进入 git。App 运行不依赖 Python。

| 项目 | 固定来源 |
| --- | --- |
| 原始模型与许可证 | [Qwen/Qwen3-4B-Instruct-2507](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507)，Apache-2.0 |
| GGUF 权重 | [lmstudio-community/Qwen3-4B-Instruct-2507-GGUF](https://huggingface.co/lmstudio-community/Qwen3-4B-Instruct-2507-GGUF/tree/4edb920b6f14e3b9284d4502a6485103d72cde05)，`Qwen3-4B-Instruct-2507-Q4_K_M.gguf` |
| 仓库修订 | `4edb920b6f14e3b9284d4502a6485103d72cde05` |
| SHA-256 | `8cdb57cbb880d313736a9bc4e3d3d2485f145b5e19cf33783746e753e82641fc` |

脚本验证完整 SHA-256，校验不符即停止，并保留模型来源和许可证文件。安装会联网下载模型及许可证；对话内容不上传。缺少模型时，总结面板提供本安装说明入口。

## 运行与取消

总结模型按需启动，通过本机私有 Unix socket 接收文字。每次只运行一个请求，使用两个 utility 优先级 CPU 线程，关闭 GPU 计算；这项限制只适用于总结进程。CPU 推理仍会消耗内存和运算时间，长会话需要更多分段请求。

完成、失败或取消后释放模型进程。折叠、最小化字幕窗、进入仅手机显示、清空、切换收音会话、退出 App，或收到内存压力警告时取消待处理任务。旧请求即使迟到返回，也不能覆盖新一代结果。手动取消或更新失败时保留此前已完成的摘要，便于稍后重试。

本机 Apple `SystemLanguageModel` CLI 探测返回 `deviceNotEligible`；本功能当前未使用 Apple Foundation Models。

## 验证与限制

最终顺序回归为 333 项通过，其中 7 项总结测试覆盖全量原文超过 100 条、增量更新、早期修正后重算、取消后的迟到结果、失败重试、会话范围和清空。仍排除会改动用户日志的 7 项 `AppLoggerTests` 和 1 项依赖已安装翻译资产的测试。

`Tools/ConversationSummaryProbe.swift` 使用真实本机模型和固定合成文字，不读取用户对话或音频。最终一次测试准备约 13.4 秒、首次正文约 16.9 秒、增量约 16.1 秒；新增“维持手动更新、不持续自动推理”后，旧摘要的“尚未确定”得到修正，早期主题及停字幕仍需排查的状态保留。输入按旧摘要在前、新记录在后的顺序组织，并明确新记录优先。输出仍保留一句关于写作要求的转述，未能移除所有元说明。这个样本通过不代表摘要总能准确保留事实；长会话需要更多请求。

同一 4B 模型的一次双请求测试观察到子进程峰值 RSS 约 3.7 GiB，不是固定内存上限。模型会临时增加本机负载，内存压力下 App 会取消总结；完成后探测进程已退出。未验收真实 ASR 并发负载。

在项目根目录复现真实模型探测：

```sh
python3 Tools/build_local_tool.py Tools/ConversationSummaryProbe.swift \
  build/summary-probe/ConversationSummaryProbe
build/summary-probe/ConversationSummaryProbe
```

界面夹具使用合成字幕和假总结提供器，不录音、不加载总结模型、不读取真实记录：

```sh
python3 Tools/build_local_tool.py Tools/CaptionInteractionBenchmark.swift \
  build/interaction-bench/CaptionInteractionBenchmark
build/interaction-bench/CaptionInteractionBenchmark 3000 build/summary-preview
```

最终界面夹具检查了 620×300、300×300 的展开状态，以及最小尺寸下的空白、加载、错误和重试状态；外层 Light 外观下摘要保持深色。标签已避开窗口缩放区域；最小化前同步折叠并恢复高度，折叠保留窗口底边，避免临时增高被保存或反复上移。截图只能验证显示。真实鼠标自动化夹具未能定位 AX 字幕窗口，本轮鼠标、键盘、VoiceOver 和真实 ASR 并发尚未实测。

Release 构建、签名校验及本机 1.7.0（build 22）安装已通过，旧版保留在 `/Applications/StreamTranslate.app.previous`。上述检查不能证明原先长时间运行后停字幕的问题已经解决。
