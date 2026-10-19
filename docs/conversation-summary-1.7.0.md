# 本机对话总结 · 1.7.1

悬浮字幕窗右侧的 **总结** 默认折叠。首次展开后立即在本机生成「在聊什么、主要内容」两部分中文摘要；展开期间，新完成的原文字幕会自动触发更新，生成中的文字逐步显示。

自动更新只在侧栏展开且未暂停时运行。点击 **暂停** 停止生成并释放模型，**继续** 恢复更新；生成失败后点击 **重试**。无需逐次手动更新。

## 内容范围

- 输入是本次开始收音以来已完成字幕的完整原文，从本机会话归档读取，包含移出 100 条实时缓存的早期字幕；尚未完成的流式一句不参与。
- 首次生成分段处理全部原文，每段连同此前摘要生成下一版；后续更新只处理新增字幕，并保留此前摘要。若早期原文发生修正，自动重新处理完整会话。
- 后续变化以首次变化为起点合并等待 2 秒，持续讲话不会不断推迟该次计划。若模型仍忙，变化只覆盖一个最新待处理请求，完成当前任务后再安排处理；2 秒是调度等待，不是摘要完成时限。
- 逐步显示的文字属于草稿。所有分段正常生成结束后，才提交已完成摘要、覆盖条数和更新状态；取消、报错或输出被截断会丢弃草稿，保留此前完成的摘要。
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

连续更新复用同一个模型进程，没有并行模型实例。空闲 15 秒后，即使侧栏仍展开也释放模型；之后有新原文时重新加载，没有原文变化时不再推理。

折叠、暂停、最小化字幕窗、进入仅手机显示、清空、切换收音会话、退出 App，或收到内存压力警告时取消待处理任务并释放模型。旧请求即使迟到返回，也不能覆盖新一代结果。

失败和内存压力会暂停自动更新，等待用户点击 **重试**；不会每来一句新字幕就重复启动失败任务。暂停或失败时保留此前已完成的摘要。

本机 Apple `SystemLanguageModel` CLI 探测返回 `deviceNotEligible`；本功能当前未使用 Apple Foundation Models。

## 验证与限制

1.7.1 顺序回归 339 项通过，其中 13 项总结测试通过；仍排除会改动用户日志的 7 项 `AppLoggerTests` 和 1 项依赖已安装翻译资产的测试。总结测试在原有全量原文、增量修订、会话范围与清空测试之外，新增 6 项覆盖自动更新合并、单进程复用、暂停后拒绝草稿与待处理任务、空闲释放、失败暂停，以及 SSE 分段 Unicode 和截断处理。记录：`build/summary-live-full-tests.log`。

最终真实模型探测使用固定合成文字，记录在 `build/summary-live-real-model.log`：

| 阶段 | 自探针启动累计耗时 |
| --- | --- |
| 模型准备完成 | 24.39 秒 |
| 首个可显示文字 | 33.86 秒 |
| 首次摘要完成 | 48.32 秒，71 次流式更新回调 |
| 增量摘要完成 | 79.50 秒；该次增量耗时 31.18 秒 |

以上均为单次样本，不是耗时上限。首轮探针曾与已安装 App 的总结进程同时运行并超时；结束后只运行一个总结进程的复测成功，探针及其子进程已退出。这不能证明真实 ASR 并发性能。增量样本仍保留了已过时的未定语义，说明模型可能未能一致修正旧摘要；不能据此宣称语义准确。

1.7.0 历史验证：顺序回归 333 项通过，排除会改动用户日志的 7 项 `AppLoggerTests` 和 1 项依赖已安装翻译资产的测试。固定合成文字的模型探测观察到准备约 13.4 秒、首次正文约 16.9 秒、增量约 16.1 秒；输入中的后续决定可以修正旧摘要，早期主题及停字幕仍需排查的状态得到保留，但输出仍转述了一句写作要求。这些记录不代表 1.7.1 的流式输出时延或准确性；长会话需要更多请求。

1.7.0 同一 4B 模型的一次双请求测试观察到子进程峰值 RSS 约 3.7 GiB。这是历史样本，不是 1.7.1 的内存测量或上限；持续复用进程会改变内存保留时间。真实 ASR 并发负载尚未验收。

`Tools/ConversationSummaryProbe.swift` 使用真实本机模型和固定合成文字，记录首次流式更新与更新次数，不读取用户对话或音频。在项目根目录复现：

```sh
python3 Tools/build_local_tool.py Tools/ConversationSummaryProbe.swift \
  build/summary-probe/ConversationSummaryProbe
build/summary-probe/ConversationSummaryProbe
```

界面夹具使用合成字幕和假总结提供器，不录音、不加载总结模型、不读取真实记录：

```sh
python3 Tools/build_local_tool.py Tools/CaptionInteractionBenchmark.swift \
  build/interaction-bench/CaptionInteractionBenchmark
build/interaction-bench/CaptionInteractionBenchmark 3000 build/summary-live-preview
```

最终界面夹具等待 `draftText` 非空后再截取流式状态；300pt 宽下的流式、空白、加载、暂停、错误和完成状态，以及 620pt 宽下的完成状态均通过检查。截图位于 `build/summary-live-preview/`。外层 Light 外观下摘要仍保持深色。标签避开窗口缩放区域；最小化前同步折叠并恢复高度，折叠保留窗口底边，避免临时增高被保存或反复上移。截图只能验证显示；此前鼠标自动化夹具未能定位 AX 字幕窗口。

1.7.1（build 23）Release 构建成功，已安装并启动 `/Applications/StreamTranslate.app`，`codesign --verify --deep --strict` 通过；旧版 1.7.0 保留在 `/Applications/StreamTranslate.app.previous`。

| 最终审核项 | 结论 |
| --- | --- |
| 回归、真实单实例 SSE、界面截图、Release、安装及签名 | 上述检查通过；独立审核未发现必须修改的代码问题 |
| 摘要语义 | 已知存在误述和旧未定语义残留，须核对原文 |
| 真实 ASR 并发性能 | 未验证 |
| 实际内存压力、鼠标、键盘、VoiceOver | 未实测；自动化回归不能替代系统场景验收 |

这些检查不能证明原先长时间运行后停字幕的问题已经解决。
