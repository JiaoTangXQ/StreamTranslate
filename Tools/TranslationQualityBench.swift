import Foundation
import FoundationModels
@preconcurrency import Translation

/// Fixed bilingual contrasts, not a general-purpose accuracy benchmark.
@main enum TranslationQualityBench {
    static func emit(_ fields: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
    }
    static func main() async throws {
        guard #available(macOS 26.4, *) else { exit(2) }
        emit(["event": "availability", "system_model": String(describing: SystemLanguageModel.default.availability)])
        let strategyName = CommandLine.arguments.dropFirst().first ?? "low"
        let strategy: TranslationSession.Strategy = strategyName == "high" ? .highFidelity : .lowLatency
        for language in ["en", "zh-Hans"] {
            let session = TranslationSession(installedSource: .init(identifier: language),
                target: .init(identifier: language == "en" ? "zh-Hans" : "en"), preferredStrategy: strategy)
            guard await session.isReady else { emit(["event":"unavailable", "language":language]); continue }
            for (index, source) in (language == "en" ? english : chinese).enumerated() {
                let start = ContinuousClock.now
                do {
                    let response = try await session.translate(source)
                    let duration = start.duration(to: .now)
                    emit(["event":"translation", "strategy":strategyName, "language":language, "index":index,
                          "seconds":Double(duration.components.seconds) + Double(duration.components.attoseconds)/1e18,
                          "source":source, "target":response.targetText])
                } catch { emit(["event":"error", "language":language, "index":index, "error":String(describing:error)]) }
            }
        }
    }
    static let english = [
        "Hello, everyone.",
        "Revenue fell by fifteen percent, not fifty percent, compared with the previous quarter.",
        "Do not restart the server until the backup has finished.",
        "The deployment failed because the Kubernetes readiness probe timed out after the database migration.",
        "Drain the queue and keep the feature flag disabled until the incident review.",
        "We ruled out a memory leak. It was a cache eviction problem.",
        "The service is eventually consistent, so a successful write may not be immediately visible to another client.",
        "The key-value cache grows as the conversation gets longer, even though the model weights stay the same size.",
        "The meeting will start in five minutes, not at five o'clock.",
        "She said the plan was not impossible, but it would take twice as long.",
        "I used to think the update was safe. I no longer do.",
        "If the error rate exceeds one percent, roll back; otherwise continue the rollout."
    ]
    static let chinese = [
        "大家好。",
        "收入下降了百分之十五，不是百分之五十。",
        "备份完成之前，不要重启服务器。",
        "数据库迁移之后，就绪探针超时，导致部署失败。",
        "请排空队列，并保持功能开关关闭，直到事故复盘结束。",
        "我们已经排除了内存泄漏，问题出在缓存淘汰策略。",
        "这个服务采用最终一致性，所以写入成功不代表其他客户端能立即读到。",
        "模型权重没有变大，但随着对话增长，键值缓存会占用更多内存。",
        "会议将在五分钟后开始，不是五点开始。",
        "她并不是说这个方案不可能，而是说完成它需要两倍的时间。",
        "我以前觉得这次更新很安全，现在不这么想了。",
        "如果错误率超过百分之一，就回滚，否则继续发布。"
    ]
}
