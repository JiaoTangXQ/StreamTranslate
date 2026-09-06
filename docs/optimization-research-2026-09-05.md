# 16GB Apple Silicon 优化调研

日期：2026-09-05。实机：Apple M4、16GB、macOS 26.4。

后续更新：Qwen3-ASR MLX 与 Hy-MT2 Metal 已完成独立本机测试，详见 [Mac 模型核实报告](mac-model-verification-2026-09-05.md)。下文的“尚未测试”是本轮初始调研时的状态；候选模型的新结论以后续报告为准。

本轮范围：检查现有代码与项目基准，查阅模型作者和运行时维护者的资料，使用独立程序验证已有系统能力。没有修改、重新安装或切换正在使用的 App，也没有上传音频或使用付费 API。`build/research-*` 是独立实验文件。

## 结论与实施顺序

16GB 足够继续优化。优先级最高的是正确使用模型最终结果、开放 Apple 中文流式识别、改善译文刷新策略，以及给最终翻译增加术语和上下文。

| 优先级 | 工作 | 预期作用 | 证据状态 |
| --- | --- | --- | --- |
| P0 | 区分实时显示文本和 ASR 最终原文 | 避免已经纠正的识别结果再次被旧文本覆盖 | 已独立复现现有行为 |
| P0 | Apple Speech 支持固定中文语言 | 减少中文路径反复识别整段音频的计算；复用系统模型 | 本机中文流式回放两次成功 |
| P1 | 译文按短语、增长量及最长等待时间调度 | 缩短“已经识别出来，但译文迟迟不刷新”的等待 | 代码确认阈值，改善幅度待端到端测量 |
| P1 | 双语术语表、有限上下文、最终译文精修 | 改善术语、歧义和指代 | Apple 现有误译已观察到；新方案待盲评 |
| P2 | Hy-MT2 1.8B Q4 的 Metal 对照测试 | 验证小型本地翻译模型是否适合精修 | 旧测试只用 CPU，本轮未下载和重测 |
| P2 | Nemotron CoreML/ANE 与现有 Metal 对照 | 验证能否减少 GPU 竞争、改善持续运行能耗 | 社区已有 Swift 实现，未在本机验证 |
| P2 | Qwen3-ASR、Nemotron 3.5、sherpa-onnx 中文对照 | 为复杂中文、口音和混合语言选择合适后端 | 候选调研，尚无本机胜出结论 |

## 一、代码中已经确认的机会

### 1. 最终原文可能保留早期误识别

`CaptionTextStabilizer.finalize()` 保留冻结前缀；`CaptionViewModel.acceptRecognizedFinal()` 将该显示文本同时写入历史并提交最终翻译。

项目已有测试 `finalOnlyRevisesTextAfterTheFrozenPrefix`，本轮用相同输入独立运行得到：

```text
ASR final: We should discuss the deployment process today.
Caption/translation input: I want to discuss the deployment process today.
```

这是当前“不回退显示”的设计取舍，不是本轮新引入的问题。若用户更看重最终内容准确，应保留独立的 `rawFinalText`：正在阅读的实时字幕保持稳定，最终历史和精修翻译使用模型最终原文，通过句末切换或明确的修订状态呈现。不能把显示层的冻结规则当作原文真值。

参考代码：`StreamTranslate/Models/CaptionTextStabilizer.swift:56`、`StreamTranslate/ViewModels/CaptionViewModel.swift:986`、`StreamTranslateTests/CaptionTextStabilizerTests.swift:128`。

### 2. Apple 中文支持被项目路由限制住了

Apple 后端把 locale 固定成 `en_US`，输出语言也固定为英文。模型配置把所有原生流式后端都标为仅英文，所以中文／自动模式必须转到 Whisper。

本机运行 `SpeechTranscriber.supportedLocales` 和 `installedLocales` 得到：

- 支持 `zh_CN`、`zh_TW`、`zh_HK`、`yue_CN` 等语言区域。
- 已安装的语音模型覆盖 `zh_CN`、`zh_TW`。
- 因此“固定中文 + Apple 连续识别”可以直接做产品化评估。支持多个 locale 不等于自动检测语言，也不证明一句话中混说两种语言的效果。

独立实验复用现有 ASR 服务，只有 locale 和输出语言改成中文，按音频原速输入。输入是 Tingting 合成的 13.089 秒中文，含“百分之十五，不是百分之五十”。

| 指标 | 第一次 | 第二次 |
| --- | ---: | ---: |
| 首个原始字符 | 1.052 秒 | 1.049 秒 |
| 输入结束到最终结果 | 0.140 秒 | 0.139 秒 |
| 总时长 | 13.229 秒 | 13.228 秒 |

两次文字相同，主要内容保留，数字呈现为 `15%`、`50%`、`5分钟`，标点和空格仍有改进空间。首个结果只有“大”，不能将首字时间称作首个可用译文时间。现有基准的 `translationReady` 按三个英文空格词计数，不适合中文，本报告不使用该项数字。

这只是合成语音可行性验证，不证明 Apple 中文比 Whisper、Qwen 更准。产品接入还应参数化语言能力、检查实际音频格式、更新设置联动，并保留 Whisper 的自动语言回退。

来源：[Apple supportedLocales](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales)。

### 3. 译文等待不限于模型推理

`PartialTranslationPolicy` 在初次请求后，通常需要再增长 5 个英文词或 10 个中文字符，或遇到句末标点，才发起下一次翻译。它没有最长等待时间。在每秒两个英文词的假设下，5 个词就是约 2.5 秒；这是阈值推算，不是实测延迟。

建议保留现有最新请求合并、过期结果保护和稳定前缀，再加入短语边界与最长等待时间，先以 400–700 毫秒作为待测参数区间。不能简单地每个 token 都翻译，否则会增加功耗和字幕改写。

当前草稿与最终翻译共享 `TranslationGate`，最终任务还有 25 毫秒合批等待。若将慢速精修引入此队列，会阻塞实时草稿。精修应有独立且有界的任务队列、结果版本和超时；过时的精修可跳过，原始历史应保留。

参考代码：`CaptionTextStabilizer.swift:283`、`CaptionViewModel.swift:1049`。

### 4. 长会话和系统负载

- `AudioCaptureService.makeAudioStream()` 使用默认无界缓冲。识别持续跟不上时有积压风险，不能只检查“每秒处理多少音频”。应记录最老待处理音频的年龄，并设计缓冲上限及明确的超载处理；原生流式识别不能无提示地丢帧。
- `captionHistory`、草稿队列中的已结束片段集合会随会话增长。优先量化长会话开销，再设计归档和裁剪。
- `AppLogger` 即使 Diagnostics 关闭也会记录 partial，每次打开文件、移动到末尾、写入、关闭。可改为异步批量写入和日志级别控制；收益待测，通常不是第一优先级。
- 若增加模型，应保持单个 ASR 常驻。精修模型按需使用，避免把 Apple、Whisper、Nemotron 和大型翻译模型全部常驻。

## 二、翻译速度和精度

### 1. macOS 26.4 新策略：可接入，但本机未验证质量升级

SDK 提供 `TranslationSession.Strategy.lowLatency` 和 `.highFidelity`。Apple 说明高保真优先使用 Apple Intelligence，不可用时可以退回传统模型。

本轮用 10 句自行编写的技术／会议文本，串行调用已安装的英译中资产；包含数字、否定、术语和指代。先默认、低延迟、高保真，再反向复测后两项。没有请求额外模型下载。

| 请求策略 | 每句中位时间 | 十句总时间 |
| --- | ---: | ---: |
| 默认 | 49 ms | 519 ms |
| lowLatency | 37 ms | 360 ms |
| highFidelity | 46 ms | 465 ms |
| highFidelity 复测 | 49 ms | 477 ms |
| lowLatency 复测 | 36 ms | 361 ms |

三种请求策略的十句译文相同。FoundationModels 报告 `unavailable(deviceNotEligible)`，但两个翻译策略的语言状态都报告 `installed`。结合 Apple 的回退说明，怀疑高保真请求发生了回退；这些检查没有直接证明实际使用的翻译模型，也没有定位设备不符合条件的具体原因。

因此：显式低延迟策略值得接入和继续测试；目前只能观察到小样本的毫秒级时间差，不能承诺整体字幕显著提速。不能把高保真开关当作这台 Mac 上已确认的精度提升。

来源：[Apple 策略说明](https://developer.apple.com/documentation/translation/translationsession/strategy)、[高保真回退行为](https://developer.apple.com/documentation/translation/translationsession/configuration/init(source:target:preferredstrategy:))。

### 2. 精度主要机会：术语、上下文、可靠的最终原文

本轮实际输出中，`the browser and the model compete for the same capacity` 的 `model` 被译成了“机型”，`drain the queue` 被译成了“耗尽队列”。它们表明技术场景有改进空间；不代表整体翻译准确率已被量化。

项目 Vocabulary 是 ASR 的识别提示，没有把 `model → 模型`、`readiness probe → 就绪探针` 这样的双语对应关系传给翻译器。当前翻译接口也没有提供前文上下文；批量提交独立句子不能直接视为上下文翻译。

建议：

1. 单独建立双语术语表，区分人名、产品名、需要保留的缩写和领域术语。
2. 给最终精修传入正确的 ASR 最终原文、最近 1–3 句原文和必要术语；不能只让模型润色已经有误的中文。
3. 约束只输出当前句译文，检查数字、单位、否定、实体是否遗漏。不能把术语全局替换当作通用解决方案。
4. 保留“快速初译 → 句末精修”的交付顺序；精修太慢或验证失败就保留初译。

### 3. 最值得复测的本地翻译器：Hy-MT2 1.8B

作者提供术语干预、背景信息、格式约束等提示方式，并有 GGUF 量化版本。它适合成为最终精修候选，不必替代每次实时草稿翻译。

项目旧记录显示 Hy-MT2 Q4_K_M 在 512-token 上下文、CPU `-ngl 0` 下约 2.1GB 进程 RSS，八句约 2.78 秒。llama.cpp 文档明确说明 `--n-gpu-layers 0` 关闭 GPU 推理，因此旧数据不能代表 Metal 性能。

应重新比较 CPU／Metal、短上下文／带术语上下文，以及单独运行／与 ASR 同时运行。即使 GPU 更快，也可能和 Nemotron Metal 竞争，导致最终字幕反而更慢。本轮没有重测该模型，不能宣称它已经更快或更准。

不优先使用 1.25-bit 极限量化：先建立 Q4 质量基线，再看更低位量化是否损失关键数字和术语。磁盘大小不能直接等同运行内存。

来源：[Tencent Hy-MT2 1.8B](https://huggingface.co/tencent/Hy-MT2-1.8B)、[llama.cpp Metal](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md#metal-build)。

### 4. 其他翻译路线

- [TranslateGemma 4B](https://huggingface.co/google/translategemma-4b-it)：专门翻译模型，支持 55 种语言，可以作为第二组离线精修对照。官方格式和上下文限制需要遵守，不能按普通聊天模型随意拼接提示。相对 1.8B 方案资源预算更大，本轮未运行。
- [DeepL API](https://developers.deepl.com/api-reference/translate/request-translation)：提供独立 context 和 glossary 参数。若以后接受联网，可以仅发送文字做可选精修，评估质量、费用及网络延迟。本轮默认保持完全本地，不调用云端。
- 7B 以上常驻翻译器、复杂多模型投票、直接语音到翻译的大型多模态模型：暂不作为 16GB 会议字幕的首选；需要先证明增益足以抵消内存、功耗和等待。

## 三、识别候选比较

| 方案 | 适合验证的场景 | 与 16GB Mac 的关系 | 本轮判断 |
| --- | --- | --- | --- |
| Apple Speech 中文 | 固定中文 | 本机系统资产已就绪，原生流式 | 最先接入评估 |
| 现有 Nemotron English Metal | 固定英文低延迟 | 已安装；项目记录约 1.05GB 进程 RSS | 保留基线，不声称全面更准 |
| Nemotron English CoreML／ANE | 英文、长时间运行、省电 | 社区已有同源模型转换和 Swift 接口 | 对照能耗、质量与 GPU 竞争 |
| Nemotron 3.5 CoreML／Metal | 中文、多语言、自动语言 | 原生缓存式流式识别；实现与模型语言能力需分别核验 | 中文准确率必须实测 |
| Qwen3-ASR 0.6B／1.7B MLX | 中文、口音、混合语言、最终复核 | 社区运行时估算 fp16 权重内存约 1.2／3.4GB，非整个 App 峰值 | 从 0.6B 开始；不套用 CUDA 测速 |
| sherpa-onnx Streaming Paraformer／Zipformer | 中英双语、CPU 轻量运行 | 有 macOS 和 Swift 接口，可避免争用 GPU | 资源友好的对照组，质量待测 |
| Whisper Small／Turbo | 自动识别和兼容回退 | 已有 Core ML 集成；当前分段快照会反复计算 | 保留；不把整段解码耗时当字幕延迟 |

几个需要避免的误判：

- NVIDIA 官方仍建议纯英文使用英文专用 Nemotron，而不是因版本号更高就换成 3.5。[官方模型卡](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)
- 现有项目使用的是 Metal。社区 CoreML／ANE 转换版已经存在，但它是另一套集成，不能说当前 App 已经在用 ANE。[英文 CoreML 模型](https://huggingface.co/aufklarer/Nemotron-Speech-Streaming-0.6B-CoreML-INT8)
- 英文 CoreML 模型卡注明本包是 160ms 分块，但表中的上游 WER 来自 1.12 秒分块，不能混为同一个运行点。
- 多语言 CoreML INT8 作者报告 M5 Pro 峰值 RSS 约 1238MB、320ms 分块；这不是本机 M4 实测，分块时长也不是字幕端到端时延。[作者数据](https://huggingface.co/aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8)
- FluidInference 另一个 CoreML 导出在模型卡中报告中文 560ms 档约 19.48% CER，而且需要申请访问；它说明存在中文路径，不说明中文已经优于当前方案。[模型卡](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML)
- Qwen 官方卡的流式实现说明采用 vLLM；Mac 上需要独立检查 MLX／Swift 实现。社区 MLX 运行时默认音频块为 2 秒，不能把“有 streaming 接口”直接等同亚秒延迟。[Qwen 官方](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)、[MLX 实现](https://github.com/moona3k/mlx-qwen3-asr)
- Parakeet TDT v3 的 25 种语言主要是欧洲语言，不能作为中文升级方案。[NVIDIA 模型卡](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- 项目旧 Moonshine 测试结果不理想；只有运行时、模型或目标音频有实质变化时，才值得重新投入对比。

sherpa 资料：[在线中英 Paraformer](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-paraformer/index.html)、[Swift 示例](https://k2-fsa.github.io/sherpa/onnx/swift-api/examples.html)。

## 四、16GB 的资源原则与验收

不能把“16GB”当成全部可供模型使用：系统、浏览器和会议软件也占统一内存。可以先给增强模式设置约 3–4GB 的增量内存目标，并以实际内存压力决定是否关闭精修；这是设计预算，不是已经测得的占用承诺。

旧基准的 Apple 39MB／18MB 是客户端进程 RSS，系统语音和翻译还可能在 XPC／系统服务运行。它们不能直接与模型全在进程中的 Nemotron／Hy-MT 比总成本。应同时记录 App、相关推理服务、系统内存压力和 swap 增量，避免简单相加重复计算共享页。

MacBook 与 Mac mini 的比较应控制芯片型号、供电／低电量状态、背景任务和散热条件；单凭相同 16GB 无法推导相同速度。笔记本尤其要测持续运行时的功耗和热状态，而不是只测十秒音频。

建议建立独立评测集，不用调参样本充当验收样本：

- 20–30 分钟真实目标音频：英文会议、中文、混合术语、口音、背景噪声、插话和停顿。
- 100–200 句人工核对翻译：术语、数字、单位、否定、指代、遗漏和增译；分别在人工原文与 ASR 原文上评分，区分识别错误与翻译错误。
- 至少一小时连续回放，同时运行实际会议／浏览器负载。
- 指标包括首个可理解原文、首个可用译文、句末修订完成的 p50/p95、字幕改写次数、队列积压、英文 WER、中文 CER、关键实体错误、内存压力和耗能。

当前的合成语音和少量技术句只能证明路径可运行、复现具体问题，不能量化“真实会议准确率提升百分之多少”。

建议第一轮只做 P0 和译文调度，再以相同评测集决定是否加入 Hy-MT2 Metal 和 CoreML Nemotron。这样每个新增模型都有可验证的收益，也能保留现有稳定版本作为对照。
