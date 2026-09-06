# Mac → iPhone 私密字幕：苹果原生传输方案调研

日期：2026-09-05

适用对象：StreamTranslate 项目与产品决策。
状态：官方资料、SDK 与现有结构核查完成；尚未开发传输功能，尚无 Mac／iPhone 双机性能实测。

## 一、结论

推荐采用 **Network framework + Bonjour 自动发现 + 安全配对 + 可恢复的字幕会话**。支持局域网和 Apple 点对点 Wi-Fi 两类路径，而不是通过 AirDrop 逐条发送字幕。

当前可确定的是框架、连接策略和可靠性设计；不能仅凭文档确定哪一种无线路径、哪一种传输协议在用户设备上最快。候选协议为 QUIC 可靠流和 TCP + TLS：以 TCP + TLS 建立兼容性对照，重点评估 QUIC，经过同负载双机测试后决定默认顺序。产品保留安全的兼容路径，不因某种协议失败而退回明文。

默认连接策略建议是“可达且稳定的局域网优先；无法互通时按需尝试苹果近距离直连”。这不是认定局域网永远最快，而是避免在用户分享视频、参加会议时，未经验证就额外启用可能影响其他网络业务的点对点无线活动。

## 二、先分清：配对方式、无线链路、传输协议是三件事

- 扫码／配对码：解决“连接哪台电脑、信任谁”，不是传输协议，扫码本身不增加字幕传送速度。
- Bonjour：发现附近的服务，不等于身份认证。
- 局域网、Apple 点对点 Wi-Fi：决定数据走哪条网络路径。
- QUIC、TCP + TLS：负责加密、可靠交付和连接行为。
- 字幕会话协议：决定重连后显示什么、如何替换精修结果、如何避免重复。

只优化无线链路，而没有状态恢复、身份认证和流量管理，仍然只是演示样例。

## 三、苹果生态能力的核查结果

| 能力 | 事实与边界 | 本项目决定 |
|---|---|---|
| AirDrop | 系统使用 BLE 与 Apple 点对点 Wi-Fi，近距离传输不必经过路由器，链路使用 TLS。它面向用户选择共享项目的流程 | 不调用共享面板逐句发送；借鉴近距离自动发现体验。[Apple 安全说明](https://support.apple.com/en-ie/guide/security/sec2261183f4/web) |
| Network framework + Apple 点对点 Wi-Fi | 公开 API 可选择启用点对点链路；不要求先配置共同 Wi-Fi 网络。AWDL 是其实现细节，不应绑定接口名或依赖私有协议 | 作为近距离直连路线；同时保留局域网。[TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)、[Apple DTS](https://developer.apple.com/forums/thread/808917) |
| Multipeer Connectivity | 当前官方文档已标记弃用，并指向 Network framework 迁移文档；不能将弃用误读成旧系统上立即失效 | 不作为新功能底座。[官方文档](https://developer.apple.com/documentation/multipeerconnectivity?language=objc)、[2026-07-14 迁移公告](https://developer.apple.com/news/site-updates/?id=07142026a) |
| Wi-Fi Aware | iOS 26 引入，官方支持设备包括 iPhone 12 及以后。但本机 macOS 26.4 SDK 中原生 Mac 的相关类型标记不可用 | 当前原生 Mac 项目不以它为前提。不能因为手机支持，就推断两端支持。[框架说明](https://developer.apple.com/documentation/wifiaware) |
| Handoff | 用于跨设备继续活动；包含接续数据流机制，但其设计重点是恢复活动，不是承诺无限字幕订阅。跨平台 App 需相同开发者 Team ID | 后续可用作“在 iPhone 继续查看”的入口，不作为第一版持续传输底座。[当前文档](https://developer.apple.com/documentation/foundation/implementing-handoff-in-your-app)、[接续流说明](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/Handoff/AdoptingHandoff/AdoptingHandoff.html) |

### Wi-Fi Aware 的本机证据

检查文件：

`/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk/System/Library/Frameworks/WiFiAware.framework/Versions/A/Modules/WiFiAware.swiftmodule/arm64e-apple-macos.swiftinterface`

`WACapabilities`（约 97 行）、`WAPublisherListener`（约 412 行）、`WASubscriberBrowser`（约 457 行）均包含 `@available(macOS, unavailable)`。

在线文档的部分元数据显示 Mac Catalyst，但本机 SDK 同时把相关 Catalyst 类型标为不可用。两者存在范围／版本差异，未把它解释成原生 macOS 支持，更没有实测 Catalyst 绕行。未来 SDK 或硬件变化时可重新评估；本结论不是宣称所有未来 Mac 永远不支持 Wi-Fi Aware。

## 四、为什么“苹果直连”不一定比局域网更快

Apple 在 TN3213 中明确警告：启用点对点 Wi-Fi 可能降低本 App 和其他 App 的网络性能；连接建立后应停止不必要的点对点发现。这个提醒直接关系到用户同时进行视频播放和屏幕共享的场景。[TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)

因此，本项目的优化目标不是文件传输峰值带宽，而是：

1. 字幕更新的尾部延迟和稳定程度。
2. 打开 App 后看到当前内容的时间。
3. 网络波动后的恢复时间。
4. 对 Mac 会议／视频网络的干扰。
5. 手机耗电、发热与长时间阅读的稳定性。

字幕文本数据量预计很小；这是基于产品数据类型的工程判断，尚未测量实际事件频率和字节数。持续点对点扫描、高频无意义保活、重复发送整段历史，可能比正文传输本身更值得先优化。

### 协议选择

Apple 当前建议自定义可靠传输优先考虑 QUIC。QUIC 支持多条可靠流；TCP + TLS 可提供单条可靠流。两者都能用于本任务，不需要为追求“最快”直接改用会丢消息的裸 UDP。[TN3213 协议选择](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework#Choose-a-protocol-to-match-your-send-mode)

建议实施顺序：

- 用 TCP + TLS 作为可解释、易对照的基线。
- 在同一字幕协议下测试 QUIC 可靠流，比较弱网恢复、尾延迟、能耗与兼容性。
- 若 QUIC 的收益稳定且连接成功率不退化，设为优先；保留 TCP + TLS 兼容路线。
- 若某设备／网络组合表现更好的是 TCP，就使用 TCP，而不是为了技术名称坚持 QUIC。
- 使用公开 Network API；不逆向 AirDrop，不硬编码 `awdl0`，不修改系统无线设置。

不能承诺协议切换、IP 变化或路径切换自动无缝；应用层必须能重建连接并同步状态。Apple DTS 的 iOS 26 点对点故障讨论中有尚未闭环的个别案例，这只能作为实机测试信号，不能推断所有设备都失败或已经修复。[讨论记录](https://developer.apple.com/forums/thread/808917)

## 五、推荐的连接与恢复设计

### 5.1 一次配对，之后自动找到首选电脑

Mac 是唯一字幕状态源，iPhone 主动加入。首次配对在演示前完成；用户确认后保存可信设备身份。以后打开手机 App，自动尝试恢复首选 Mac，不要求每次输入 IP 或扫码。

不将 IP、电脑名称、Bonjour 名称或“同一个 Apple 账号”当成已认证身份。Mac IP 变化后重新发现即可；同名设备必须能区分。

### 5.2 按需使用两类路径，而不是长期双连接

初步策略：

```打开 App
   ↓
发现首选 Mac，验证身份
   ↓
可达的局域网连接 ── 不可达时尝试 Apple 近距离直连
   ↓
取当前字幕快照 → 接收后续修订
   ↓
断线：显示恢复状态 → 重新认证与同步，不恢复电脑字幕窗
```

- 两类路径共享同一配对身份与字幕会话。
- 避免长期同时广播、发现和传送两套相同字幕。
- 路径切换设置退避和稳定观察期，避免来回切换造成更差体验。
- 如后续测试短暂并行建连有明显收益，只在恢复阶段有界使用，并及时取消多余连接。
- 苹果直连双方都需正确启用相应公开参数；开启参数是允许使用该路径，不是保证强制走某张无线接口。
- 访客 Wi-Fi、VPN、防火墙、企业管理策略都需纳入验证。直连不是绕过所有系统或组织限制的保证。
- Mac Mini 可通过网线接路由器、手机走该局域网 Wi-Fi；是否更稳仍需实际环境验证。
- 没有可达网络且不在近距离范围内时，第一版明确显示离线，不偷偷改走云端。

### 5.3 可靠性来自可恢复会话，而不是赌旧连接一直存在

每条事件至少带有会话 ID、字幕 ID、修订号和序列号。手机按修订更新同一行。重连时先取有界快照，再接增量，不重播长期积压的旧队列；清空、停止、重启均有显式状态。

分开判断：

- 网络是否可达；
- 对端是否已认证；
- 字幕引擎是否运行；
- 是否有新语音／当前只是安静。

没有人说话不能被误判为断线；TCP 连接仍在也不能被误判为字幕引擎正常。心跳只验证会话存活，不代替引擎状态。

发送队列有上限，草稿可合并为最新状态；精修通过修订号覆盖。手机慢或离线不能堵塞 Mac 的识别和翻译流程。

### 5.4 打开就能恢复，不等于后台永远连接

iOS 普通 App 会被挂起，没有可依赖的通用永久后台网络执行机制。Network.framework 不提供例外；MultipeerConnectivity 还明确规定后台断会话、前台需自行重建。[后台限制](https://developer.apple.com/forums/thread/685525)、[Network 连接边界](https://developer.apple.com/forums/thread/717396)

产品承诺应是：

> Mac 正在运行翻译、两端可达且权限正常时，打开已配对的 iPhone App，自动恢复到当前字幕。

锁屏、切 App、系统回收、用户强退后再次手动打开，都要能走恢复流程。不用静音音频、假 VoIP 或定位来保活。

Mac 活动会话可申请防止空闲系统睡眠，结束释放；这不代表覆盖用户主动睡眠、合盖或关机。[idleSystemSleepDisabled](https://developer.apple.com/documentation/foundation/processinfo/activityoptions/idlesystemsleepdisabled)

## 六、私密配对与演示安全

以下为建议设计，尚未实现：

- 每个安装实例使用独立密钥／身份，不把所有设备共用的证书私钥写进 App。
- 配对二维码包含短期邀请和需要验证的公钥指纹；邀请使用后失效，并限制重试。
- 连接必须验证已配对身份并加密。发现成功不等于授权成功；Bonjour 的安全边界也不提供这种保证。[Apple Bonjour 安全说明](https://support.apple.com/en-us/101889)
- 对端证书变化时停止发送、要求重新确认，不能接受任意自签证书或静默降低安全级别。
- 不在 Bonjour 广播中放字幕、长期凭据或不必要的持久标识。
- 日志默认只记时序、状态和错误，不记录字幕正文或配对秘密。
- 断线、认证失败、系统唤醒、App 重新激活都不能自动弹回 Mac 字幕窗。
- 连接设置、权限、语言资源准备在演示前完成；不承诺隐藏 macOS 强制隐私指示。
- 手机默认不永久存储字幕，可对 App 切换快照做遮挡。

局域网权限说明与服务声明须按目标系统配置；拒绝权限时提供可理解的诊断，不把权限失败归咎于 Wi-Fi 慢。[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

## 七、必须通过的双机测试

下列都是待验证门槛，不是现有测试结果。

| 测试族 | 关键场景 | 验收重点 |
|---|---|---|
| 链路对照 | 同路由器、路由器无互联网、双方未加入 Wi-Fi 但无线功能开启、访客隔离网、Mac 有线＋手机无线 | 连接成功率、所选路径、发现与认证耗时 |
| 协议对照 | TCP + TLS／QUIC，相同事件回放、相同硬件和网络条件 | 中位、P95／P99 延迟，抖动、恢复、资源 |
| 恢复 | 已配对冷启动、切后台、锁屏 10 秒／1 分钟／10 分钟、强退后手动打开、IP 变化 | 自动恢复当前内容，不显示假实时，不重播旧队列 |
| 安静与故障 | 几分钟无语音、Mac 引擎停止、服务重启、睡眠与唤醒、Wi-Fi 开关、端口受阻 | 区分无语音／离线／引擎异常，超时后可恢复 |
| 并发压力 | 全屏视频＋会议共享＋现有识别精修，必要时叠加 AirDrop／AirPlay 干扰 | 不因字幕连接显著损伤主任务，特别测 P2P 共存 |
| 安全 | 未配对设备、同名 Mac、伪造发现服务、凭据撤销和变更 | 不误连、不泄漏、不明文降级 |
| 长时 | 前台连续两小时；一组至少 100 次恢复循环 | 记录失败数，不只展示最好的一次；无无界队列／内存增长 |
| 私密模式 | 上述所有失败状态都通过实际共享接收端观察 | Mac 不自动恢复字幕和正文窗口 |

初步体验目标：

- 已连接、健康局域网：文本在 Mac 发布到 iPhone 显示的新增延迟 P95 不超过 200 毫秒。
- 已配对、正常权限及可达局域网：打开到拿到当前快照初步目标 P95 不超过 3 秒；首次配对和等待系统权限单独计时。
- 点对点发现／恢复单独报告，第一轮实测后再确定门槛，不把局域网指标直接套过去。
- 总体仍以零隐私泄漏、可靠恢复、演示网络不退化优先，不能用平均延迟掩盖偶发长卡顿。

测量需分离发现、连接、认证、同步、传输和渲染耗时。两台设备的时钟不能直接相减当作精确单向延迟；使用时钟偏移估计并报告误差，辅以同画面高帧率录像或往返确认。往返时间不等于单向显示耗时。

能耗、发热及会议网络影响用同设备、同屏幕亮度、同视频与翻译负载进行有／无手机连接的对照。不能把模拟器流畅视为真机无线、锁屏、能耗验证。

## 八、开发顺序与当前限制

1. 先解开现有 Apple Translation 会话与悬浮字幕视图的生命周期依赖，验证 Mac 无字幕窗运行。
2. 建立小型双机连接评测工具，比较两种路径、两种可靠协议；不先做复杂界面。
3. 确认默认连接策略，加入安全配对、状态快照、修订、断线恢复。
4. 接上原生 iPhone 阅读界面，完成两小时和共享接收端验收。
5. 按性能数据决定是否增加 Handoff 入口、路径优化；暂不引入远程云服务和手机端模型。

当前主工程使用 AppKit／SwiftUI 原生 Mac 结构。此次只检查资料与 SDK，没有建立网络服务、录音、修改运行环境或应用代码。当前 `xcodebuild -version` 返回活动开发目录只有 Command Line Tools；本轮未确认可用的完整 Xcode／iPhone 构建签名环境，也未进行真机连接测试。用户 iPhone 型号与系统版本尚待确认。

本报告依据截至 2026-09-05 可访问的 Apple 文档与当前本机 SDK。部分 Apple 网页仅返回 JavaScript 外壳，已通过其官方文档 JSON 核对关键正文／平台元数据。报告采用 Markdown 交付，进行结构与链接格式检查；未进行 PDF 或页面视觉渲染。

**最终建议：把“苹果原生自动发现、一次安全配对、打开后快速恢复”作为产品体验；把“局域网或近距离直连、QUIC 或 TCP”的选择交给有证据的连接策略，不让用户手工管理这些术语。**


<!-- INTERNAL_RESEARCH_LEDGER -->

## 内部研究记录（不进入交付正文）

工作流：依深度调研技能执行。update_plan 未在可用工具目录中，采用会话内计划替代：发现→核验→综合与交付。仅委派一个独立生命周期来源核验任务；主要传输与 SDK 判断由主代理完成。

### Claim-to-source ledger

所有来源访问日期：2026-09-05。未明确发布日期的 API 文档标记为动态文档，不根据搜索引擎“发布时间”推断发布日。

| 记录 | 来源／发布者／日期 | 证据与置信度 | 工具来源 |
|---|---|---|---|
| AirDrop BLE、P2P Wi-Fi、TLS | Apple Platform Security，2021-02-18；https://support.apple.com/en-ie/guide/security/sec2261183f4/web | 高；仅用于底层机制，不外推第三方拥有系统 AirDrop 私有特权 | turn56search4 |
| Network P2P 公开 opt-in、Bonjour、QUIC | Apple TN3151，修订 2026-07-23；https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api | 高；正文通过官方 tutorials/data/documentation JSON 读取 | turn53search3 + shell 官方 JSON |
| 迁移推荐、P2P 共存警告、QUIC 候选 | Apple TN3213，2026-07-14；https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework | 高；与官方迁移公告交叉核验 | turn56search5 + 官方 JSON |
| MCP 当前弃用 | Apple 动态文档；https://developer.apple.com/documentation/multipeerconnectivity?language=objc | 高；不把弃用写成当前机器移除 | turn56search2 |
| 迁移文档发布日期 | Apple Site Updates，2026-07-14；https://developer.apple.com/news/site-updates/?id=07142026a | 高 | turn60view1 |
| Wi-Fi Aware iPhone 设备范围 | Apple 动态文档；https://developer.apple.com/documentation/wifiaware | 高；iPhone 支持不意味着 native Mac 支持 | turn52search0 + 官方 JSON |
| 当前 native Mac API unavailable | Apple 本机 MacOSX26.4 SDK，读取日期同上；正文所列 swiftinterface | 高，限定该 SDK；与在线 Mac Catalyst 元数据存在未消除的范围差异，已披露 | exec sed/rg 行 97、412、457 |
| AWDL 非稳定 API 契约／案例未闭环 | Apple DTS Quinn 与问题作者，2025-12 至 2026-02；https://developer.apple.com/forums/thread/808917 | 官方机制说明高；作者故障仅案例级，不视为普遍缺陷 | turn59view3 |
| Handoff 的定位与 Team ID | Apple 动态文档；https://developer.apple.com/documentation/foundation/implementing-handoff-in-your-app | 高；本轮不将其作为实时订阅底座 | turn60search2、turn62view1 |
| Handoff continuation streams | Apple 归档编程指南，页面未确认更新日；https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/Handoff/AdoptingHandoff/AdoptingHandoff.html | 高：接续设计；不推出技术上不能发送多次消息 | turn60search0 |
| iOS 后台、挂起、强退 | Apple DTS Quinn，修订 2026-01-09；https://developer.apple.com/forums/thread/685525 | 高；包括 BGContinuedProcessingTask，不依赖过时遗漏 | turn61view0 |
| NWConnection 没有后台执行豁免 | Apple DTS Quinn，2022-10；https://developer.apple.com/forums/thread/717396 | 高，与新版后台总论交叉核验 | turn61view1 |
| Bonjour 非身份验证 | Apple Support，2023-08-18；https://support.apple.com/en-us/101889 | 高 | turn61view2 |
| Mac 防空闲睡眠边界 | Apple 动态 API 文档；https://developer.apple.com/documentation/foundation/processinfo/activityoptions/idlesystemsleepdisabled | 高；官方 JSON 抽取，不延伸到手动睡眠 | exec 官方 JSON |
| 本地网络权限 | Apple TN3179 动态文档；https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy | 高；本轮与上轮已读资料一致 | turn51search0 |
| TCP/QUIC 基础 API 可用性 | Apple 动态 API；https://developer.apple.com/documentation/network/nwprotocolquic/options/idletimeout | 官方元数据 iOS15/macOS12；非最终 App 最低版本承诺 | exec 官方 JSON |
| 性能、恢复、能耗目标 | 项目设计建议，无外部实测证据 | 待验证，未宣称性能保证 | 本报告第七节 |

### 检索记录与缺口

- 第一波：Apple includePeerToPeer、AirDrop/P2P、Wi-Fi Aware 设备支持、Multipeer 弃用。
- 第二波：TN3151/TN3213 官方正文、点对点共存代价、DTS 未闭环案例、当前 SDK 类型可用性。
- 独立核验：iOS 挂起/强退、Network 会话边界、Bonjour 安全、Mac idle sleep。
- 补充：Handoff 接续流与 Team ID、QUIC keepalive/idle timeout API、官方 sample metadata。
- Apple HTML 部分为 JS 壳：使用官方 JSON 补齐；没有反复重试同一个失败页面。
- 已解决：第三方是否能用苹果近距离 P2P；是否必须 MCP；“同 Wi-Fi”是否必要；扫码是否传输；生命周期能否永久后台。
- 已界定：线上 Catalyst 元数据与本机 SDK 不一致，不能据此承诺 native Mac Wi-Fi Aware；将未来平台支持列为后续复核。
- 仍未知：用户 iPhone 型号/iOS，实际连接成功率、P95/P99、耗电、共存影响、具体企业网环境、完整 Xcode/签名环境。
- 停止理由：关键选型事实已有一手来源，剩余高价值不确定性需要双机实验，而不是追加同类网页。未宣称完成性能选优。
