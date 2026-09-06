# Mac 模型本机核实：Qwen3-ASR 与 Hy-MT2

日期：2026-09-05。设备：Apple M4，16GB 统一内存，macOS 26.4，arm64。

这是 [优化调研](optimization-research-2026-09-05.md) 的后续实测。只下载模型并运行独立实验，没有改动或重新安装 `/Applications/StreamTranslate.app`，没有录制用户音频，没有把音频或文字发往云端推理服务。

## 结论

1. **两种模型都已经在本机运行，不需要 Windows、NVIDIA 显卡或 CUDA。** Qwen 使用社区 MLX 运行时，Hy-MT2 使用 llama.cpp Metal；这不意味着官方 CUDA 示例可以原样在 Mac 执行。
2. **Qwen 量化有明显速度和内存收益，但本次测试的社区流式实现不能直接替换现有识别。** 整段识别完整，流式识别出现漏词、重复和数字断裂。当前更值得评估的用途是句末／短段复核。
3. **Hy-MT2 Metal 可用于可选的最终翻译精修，暂不建议替换 Apple 实时翻译。** Metal 比 CPU 更快，术语提示有效，但仍明显慢于系统翻译，且没有证明总体准确率更高。
4. 16GB 上应优先优化当前字幕调度和最终原文正确性，保留轻量实时路径。新模型逐个引入，不把多个识别器与精修器全部常驻。

## 一、环境、版本与测量方法

- Python 3.12.13；`mlx-qwen3-asr==0.3.5`；`mlx==0.32.2`、`mlx-metal==0.32.2`。未安装 PyTorch 或 CUDA。
- Qwen 官方模型：`Qwen/Qwen3-ASR-0.6B`，revision `5eb144179a02acc5e5ba31e748d22b0cf3e303b0`。
- Hy-MT2 官方文件：`tencent/Hy-MT2-1.8B-GGUF/Hy-MT2-1.8B-Q4_K_M.gguf`，revision `1cd5208700acedef4ef93019b6cfc148b8522d45`。
- llama.cpp 官方 macOS arm64 二进制：`b10809`，commit `5266f24da`。压缩包 SHA-256 与官方 release asset digest 一致：`7d692df9e1e386e62f1c12b843903218041e6cd74c9415aa39a7ed3176f9eaa2`。
- 模型放在 `/Volumes/PortableSSD/StreamTranslate-verification-20260905/`；Python 环境、测试脚本和原始输出在 `build/verification/`，后者由 Git 忽略。
- Qwen 推理指定本地路径和 `HF_HUB_OFFLINE=1`。Hy-MT2 服务仅监听 `127.0.0.1`，测试后退出；复测增加临时 API key。
- 重型推理任务串行运行，避免实验相互争用 GPU。没有关闭用户正在运行的其他程序，因此不是独占硬件基准。
- ASR 输入为既有 Samantha 英文合成语音 6.858 秒、Tingting 中文合成语音 13.089 秒，转为 16kHz 单声道 PCM。不是会议、噪声或口音准确率测试。
- 流式每 100ms 输入一批音频，按绝对时间截止点回放，在对应音频实际到达后才输入；记录首个原文、句末延迟和最终文字。离线耗时不包含等待音频录完的时间，不能当作字幕首字延迟。

来源：[Qwen 官方模型](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)、[MLX 运行时维护者](https://github.com/moona3k/mlx-qwen3-asr)、[Hy-MT2 官方 GGUF](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF)、[llama.cpp b10809](https://github.com/ggml-org/llama.cpp/releases/tag/b10809)。

## 二、Qwen3-ASR：GPU 运行、量化收益和流式限制

### 实际 GPU 证据

运行时返回 `metal_available=true`、`Device(gpu, 0)`，设备名称为 `Apple M4`。随后实际完成中英文推理，不只是成功导入库或读取配置。

### 整段识别结果

以下为模型已加载后，每种语言第二次调用的时间。每档只有两个短样本，不能用来推算生产 p95。

| 0.6B 配置 | 英文 6.858 秒 | 中文 13.089 秒 | 中文实时因子 | 该测试最终文字 |
| --- | ---: | ---: | ---: | --- |
| FP16 | 1.992 s | 2.839 s | 0.217 | 完整 |
| Q8，group 64 | 0.376 s | 0.573 s | 0.044 | 与 FP16 相同 |
| Q4，group 64 | 0.290 s | 0.413 s | 0.032 | 与 FP16 相同 |

Q8 中文约为 FP16 的 5 倍处理速度，Q4 约 6.9 倍。这是同机、同短样本的观察，不保证真实音频或其他 M 系列芯片有相同比例。FP16 首次英文调用为 4.585 秒，说明预热很重要；这些表格不包含冷加载。

中文完整输出保留“百分之十五，不是百分之五十”和“五分钟后开始”。两个样本的标点归一化后，离线各档英文 WER 和中文 CER 均为零；样本只有 20 个英文词和 53 个汉字，**不构成通用准确率结论，也不足以证明 Q4 无质量损失**。

### 16GB 内存预算不能只看模型名称或文件大小

实下载的官方权重文件为 1,876,091,704 字节，不能沿用“0.6B 约 1.2GB”作为整个运行预算。FP16 刚加载后的 MLX active 分配约 1.876GB。

本轮首先加载 FP16，再在内存量化；这一实验方式的加载／转换峰值约为 **3.752GB MLX 分配**。Q8 量化后 active 约 1.003GB，短音频推理峰值约 1.342GB；Q4 量化后 active 约 0.537GB，短音频推理峰值约 0.876GB。

这些是十进制 GB 的 MLX 分配计数，不包含所有 Python／系统开销。进程 RSS 与 GPU 分配不可简单相加，内存映射也会影响 RSS。测试时系统已有大量 swap；没有证明“16GB 同时开会议、浏览器及多个模型不会换页”。更合理的交付方式是预先量化并直接加载，不能每次启动先加载 FP16 再转换。

随后已补测直接加载预量化 Q8：将权重导出到外置盘（文件约 955MiB），新进程直接加载，**加载阶段 MLX 峰值从 3.752GB 降至 1.003GB**，短音频推理阶段峰值约 1.342GB，进程峰值 RSS 约 0.996GB。两段最终文字与前述 Q8 一致。新进程加载耗时 3.173 秒；缓存和外置盘会影响该时间，不能视为稳定冷启动指标。此轮第二次调用英文 0.456 秒、中文 0.752 秒，显示日常负载下存在波动，Q8 中文两轮宜表述为约 0.57–0.75 秒，而不是保证固定 0.57 秒。

这验证了降低启动峰值的实际路径，但仍只覆盖短音频，不等于整个 App 的内存预算已通过长时间负载测试。

### 当前社区流式实现：不通过直接替换门槛

固定 `max_context_sec=30`、`max_new_tokens=128`，其余采用运行时默认流式策略。不是对 Qwen 官方所有流式实现的评价。

| 配置 | 分块 | 英文首个原文 | 中文首个原文 | 英文最终 WER | 中文最终 CER |
| --- | ---: | ---: | ---: | ---: | ---: |
| FP16 | 2 s | 2.968 s | 2.639 s | 40.0% | 30.2% |
| FP16 | 1 s | 1.330 s | 1.340 s | 40.0% | 17.0% |
| FP16 | 0.5 s | 0.929 s | 0.857 s | 30.0% | 32.1% |
| Q8 | 2 s | 2.234 s | 2.146 s | 40.0% | 17.0% |
| Q8 | 1 s | 1.092 s | 1.098 s | 40.0% | 17.0% |

错误率仅诊断这两个合成样本。英文转小写并忽略标点；中文忽略标点和空格，数字规范化规则在脚本中显式列出。首个原文可能只有“Hello everyone”或“大家好”，不是首个可用译文。

例如英文流式最终输出遗漏了 `of live English captions and Chinese translation`，还出现 `in. In five minutes`；中文短分块出现“不是百分之之五。五十”，0.5 秒分块把“电脑”识别成“电子”等。Q8 加快计算，未消除这些流式问题。该运行时的 `finish_streaming` 处理尾部，不能假设它会对整段重新识别并修正所有前文。

代码中的 `partial_stability=1.0` 也不等于准确率 100%：最终把全部已有文字标成 stable 即可达到该值。不能拿“零改写”掩盖漏词。

同音频复测 Apple：英文首个原文 1.014 秒、句末延迟 0.038 秒；中文首字 1.029 秒、句末延迟 0.115 秒，最终主要文字完整。Apple 基准在输入后才 sleep，首批音频最多提前约 100ms，而 Qwen 在输入前等待，因此不把两者几十毫秒的差距作为胜负依据。Apple 基准的中文 `translationReady` 按英文空格词计数，本报告不使用它。

### 外置盘兼容问题

初次加载失败：`Invalid json header length .../._model.safetensors`。运行时直接遍历 `*.safetensors`，把 macOS 在外置盘上的 AppleDouble 元数据误当权重。

实验未删除这些元数据，也未改第三方库；在内置盘创建仅包含真实模型文件的符号链接目录后成功运行。产品化时要过滤 `._*` 文件并验证模型清单，且不能依赖开发目录、当前工作目录或外置盘固定名称。

## 三、Hy-MT2：Metal 确实生效，但不是最快的草稿翻译

使用 2048-token 上下文、单 slot、4 CPU 线程；官方建议的 temperature 0.7、top_p 0.6、top_k 20、repeat_penalty 1.05，固定 seed 42，输出上限 256 tokens。采用模型 chat template，不添加 system prompt。每轮先翻译一条预热句，再串行翻译与 Apple 相同的十条技术／会议文本。

复测日志明确显示：

```text
using device MTL0 (Apple M4)
offloaded 33/33 layers to GPU
MTL0_Mapped model buffer size = 1075.74 MiB
MTL0 KV buffer size = 128.00 MiB
MTL0 compute buffer size = 46.01 MiB
```

CPU 复测额外指定 `--device none --no-op-offload`，日志显示 `offloaded 0/33 layers to GPU`，排除仅设置层数但仍有可选算子卸载的歧义。

| 翻译配置 | 十句完整译文总耗时 | 每句中位耗时 |
| --- | ---: | ---: |
| Hy-MT2 Metal，第一轮 | 3.358 s | 0.347 s |
| Hy-MT2 CPU，第一轮 `-ngl 0` | 6.710 s | 0.633 s |
| Hy-MT2 CPU，反向复测且显式关闭 GPU | 5.265 s | 0.550 s |
| Hy-MT2 Metal，反向复测 | 3.591 s | 0.350 s |
| Apple lowLatency | 0.410 s | 约 0.041 s |
| Apple lowLatency 复测 | 0.398 s | 约 0.040 s |
| Apple highFidelity 请求 | 0.543 s | 约 0.055 s |

Apple 原工具使用排序后第六项标为 median，Hy-MT2 使用中间两项平均；这里保留工具输出，并用十句总时间比较。Apple 默认策略本轮总计 0.962 秒，首句 0.358 秒，包含明显首次请求开销，不与 Hy-MT2 的预热后结果混比。

Metal 相比 CPU 的整组加速为约 1.5–2 倍；不是数量级提升。Apple 低延迟整组仍约快 8–9 倍。CPU 和 Metal 的少数译文有措辞差异，输出 token 数不完全相同；这是端到端翻译比较，不是严格等 token 的纯算力测试。

每 100ms 抽样的服务 RSS 峰值：Metal 约 1.39–1.42GB，CPU 约 2.33GB。抽样可能漏过尖峰；模型映射、GPU 分配与 CPU REPACK 缓冲口径不同，这些数字不能直接作为整机占用或节能结论。

### 翻译质量：术语提示有实际收益，但不是全面胜出

| 原文概念 | Apple 本轮 | Hy-MT2 普通提示 | Hy-MT2 加术语表 |
| --- | --- | --- | --- |
| browser and the model | 浏览器和机型 | 浏览器和模型 | 浏览器和模型 |
| drain the queue | 耗尽队列 | 清空队列 | 排空队列 |
| feature flag | 功能标志 | 功能标志 | 功能开关 |
| readiness probe | 准备探针 | 准备检查 | 就绪探针 |

Hy-MT2 也有可改进之处，例如将百分比写成“十五%”“五十%”，或把 `ship the hotfix` 译成“发送热修复包”。数字和否定在本组翻译里保留，但没有做盲评、上下文一致性大样本或真实会议测试。术语表验证仅覆盖四条句子，不等于已经验证长上下文翻译能力。

因此建议：Apple 给实时草稿；Hy-MT2 可作为带术语的、可关闭的句末精修候选。精修必须独立限流并丢弃过期任务，不得阻塞草稿队列。是否值得常驻仍需与实际 ASR 同跑、测整机内存压力和能耗。

## 四、下一步实施边界

- 先实施原调研中的最终原文与稳定显示分离、Apple 固定中文路径、译文最长等待时间。这些不依赖下载另一个大模型。
- 如增加 Qwen，先评估 Q8 的短段最终复核；Q4 保留作低内存对照。当前社区固定分块流式路径暂不直接上线。
- 如增加 Hy-MT2，作为可选精修而不是默认草稿后端；准备双语术语表，并检查数字、否定、实体和过时结果。
- 正式默认后端切换前，需要代表性的 20–30 分钟音频、并发会议／浏览器负载、长会话积压、耗电和温度测试。
- 本次没有跑 Qwen 1.7B、Nemotron 新 CoreML／ANE 转换版或其他 M1/M2/M3 设备；不能将本机结论扩展成所有 16GB Mac 的性能保证。

## 五、原始证据与复测入口

`build/verification/` 中保留：

- `qwen_bench.py`，`qwen-results.jsonl`，`qwen-q8-results.jsonl`，`qwen-q4-results.jsonl`。
- `qwen-q8-export-results.jsonl`、`qwen-q8-prequantized-results.jsonl`：预量化导出与新进程直接加载验证。
- `summarize_asr.py`、`asr-summary.jsonl`：固定参考文本及归一化错误率。
- `hymt_bench.py`，`hymt-results.jsonl`，`hymt-repeat-results.jsonl` 和两轮服务器日志。
- `apple-translation-results.txt`、`apple-english-results.txt`、`apple-chinese-results.txt`。
- `requirements-lock.txt`、`sha256.txt`、下载日志及 16kHz WAV 输入。

在项目根目录、外置盘保持连接的前提下，示例复测命令：

```sh
HF_HUB_OFFLINE=1 build/verification/venv/bin/python build/verification/qwen_bench.py --bits 8 --chunks 2 1
build/verification/venv/bin/python build/verification/hymt_bench.py --order cpu metal --label=-new
```

这些是本机实验入口，不是已完成的 App 分发方案；跨机器运行还需打包运行时、模型目录管理、签名与下载校验。
