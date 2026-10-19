# 云端优先总结 · 1.8.0

此配置只用于对话总结。语音识别、Apple 翻译、Qwen 校对和 Hy-MT 翻译的模型、请求、配置与调度均不改动。

展开总结后，优先通过智增增的 OpenAI 兼容 Chat Completions API 调用 `deepseek-v4.1-flash`。发送本批新增字幕原文和话题标签目录，不发送音频；提供商会收到这些文字。API 使用 JSON object 模式，提示词附带本批节点 JSON Schema；最终结果仍由应用校验，这不等于提供商在解码时强制执行 schema。正常云端处理不加载本地总结模型。面板标明云端或本地状态，原有增量脑图和节点合并规则保持。

超时、HTTP 错误、流式响应截断、无有效内容或脑图结构校验失败时，同一批输入转用原来的本地 Qwen3-4B-Instruct-2507。云端失败后等待 60 秒再尝试，避免连续字幕反复触发失败请求；这段时间复用一个本地 worker。重试云端时释放本地 worker；暂停、折叠或取消不会再启动本地回退。两端都失败时保留此前完成图并暂停更新。达到脑图容量限制不会为了重试而加载本地模型。

## 私有配置

根目录 `.env` 受 `.gitignore` 的 `.env*` 规则保护。模板是 [summary-api.env.example](summary-api.env.example)，只放占位值。不要将真实密钥放入源码、模板、日志或 Git。

`python3 scripts/install-summary-env.py` 将总结所需变量写入 `~/Library/Application Support/StreamTranslate/Configuration/.env`，权限为 600；目录为 700，文件不在 App 包或模型目录中。本地安装脚本会执行此步骤。修改配置后重新启动 App；本地模型重装不会移动此文件。

App 优先读取该配置文件；开发时可读取当前目录 `.env`，或通过 `STREAMTRANSLATE_SUMMARY_ENV` 指定文件。文件值优先于进程同名变量，避免其他工具的全局 OpenAI 设置覆盖总结配置。此读取器只在总结服务中使用，不向翻译功能注入环境变量。

| 变量 | 用途 |
|---|---|
| `MODEL_PROVIDER` | 当前接入值为 `zhizengzeng` |
| `ZHIZENGZENG_OPENAI_API_KEY` | 请求鉴权，不输出到日志 |
| `OPENAI_BASE_URL` | HTTPS API 根地址，自动追加 `/chat/completions` |
| `OPENAI_MODEL` | 总结模型名称 |
| `CHAT_COMPLETIONS_MAX_TOKENS` | 配置上限；脑图实际最多使用 2,048 输出 tokens |
| `CHAT_COMPLETIONS_MAX_CONCURRENT_REQUESTS` | 保留配置；实时增量总结始终串行，一个请求 |
| `CHAT_COMPLETIONS_REQUESTS_PER_SECOND` | 同一云端服务请求的频率上限，最高 20 |
| `CHAT_COMPLETIONS_INSECURE_TLS` | 保留为 `false`；客户端始终验证证书，不提供跳过验证行为 |

兼容网关无 choices 的用量统计帧；它不会被当作正文或完成信号。仅移除已观察到的根对象 `type: json_object` 格式标记，其他多余字段或不合法节点仍拒绝，节点及来源编号校验不放宽。

请求使用短暂 URLSession，不使用磁盘 URL 缓存，不跟随 HTTP 重定向；不记录密钥、请求文字和提供商错误正文。请求空闲超时 15 秒，总超时 45 秒；这些时限不包括回退后本地模型的加载与生成时间。失败后回退可以增加等待时间。

## 验证与边界

顺序回归 371 项通过，耗时 11.378 秒，其中 34 项既有总结测试、11 项新增云端/回退测试；排除 7 项会改动用户日志的 AppLoggerTests 和 1 项依赖已安装翻译资产的测试。覆盖 HTTP 鉴权错误、分段 Unicode SSE、用量统计帧、格式标记、无效脑图触发回退、取消后不启动回退、同批输入与原目录保持、共享冷却及本地 worker 复用、文件覆盖其他进程的 OpenAI 配置。记录：`build/cloud-summary/full-tests.log`。

`ConversationSummaryProbe --cloud` 使用真实 API 与合成文字完成广告、记忆、住房、返回记忆和密集新增 8 条事实五阶段 SSE/apply 回放。完成时刻分别为 2.232、3.503、5.477、6.474、8.181 秒；旧广告和住房节点及证据源保持不变，退出码为 0，监测未启动本地总结 worker。这是一次固定样本，不是吞吐量、时延或分类准确率保证；不读取用户对话。记录：`build/cloud-summary/real-cloud.log`。

实测也遇到过网关格式元数据、额外统计帧及缺少来源字段的不合规响应；现有校验会拒绝不合规节点并触发本地回退。合法来源编号仍不能证明事实忠于原文。

Release 构建通过，已安装并运行 1.8.0（build 26），严格签名校验通过，指定证书 root 保持 `16e1fb8fdc0258b43bf6a5e54c1a24589cce8357`。旧版保留于 `/Applications/StreamTranslate.app.previous`。密钥扫描确认已安装 App 包、已跟踪及可提交文件均不含实际 API key，运行时配置权限为 600；检查未改动识别和翻译相关实现文件。

云端接入不保证语义分类正确。原有词面主题检索、代词续句及目录容量的限制仍在；这次改动不声称修复音频漏采。第三方模型名和可用性以提供商实际响应为准。
