import Foundation
import AppKit

/// Synthetic text only: no user transcript, audio or preferences. Drives the
/// production mind-map model stage by stage through the configured provider
/// (cloud first, or `--local`) and prints each merged map.
///
///   ConversationSummaryProbe            five-stage merge/correction check
///   ConversationSummaryProbe --long     many topics under a small topic budget
@MainActor private final class ProbeSource {
    var rows: [CaptionEntry] = []
    var minutes = 0.0
}

@main enum ConversationSummaryProbe {
    static let stages: [[String]] = [
        ["本期节目由云声耳机赞助，输入优惠码可以享受九折。广告到这里结束。",
         "先说新版本发布。产品经理说原计划下周发布，主要变化是字幕延迟更低。"],
        ["接下来说招聘。团队打算招两名后端工程师，重点是音频处理经验。",
         "面试会分两轮，第一轮是线上编程。"],
        ["回到发布的事。刚才说下周发布，其实不对，测试发现长时间运行会卡顿，所以推迟到月底。",
         "推迟期间先修复性能问题，再做一轮五小时的稳定性测试。"],
        ["好的好的。嗯，大家还有什么问题吗？没有的话我们继续。", "对，没错，就是这样。"],
        ["招聘那边有结果了：已经发出一个录用通知，另一个岗位下周再面。"]
    ]

    static let longTopics = ["新版本发布计划", "后端招聘", "季度预算", "办公室搬迁", "客户投诉处理", "安全审计",
        "年会安排", "数据备份策略", "移动端改版", "合作伙伴大会", "实习生计划", "服务器扩容", "文档规范", "培训课程"]

    @MainActor static func main() async throws {
        let options = CommandLine.arguments
        let source = ProbeSource()
        let started = Date()
        let service: () -> any ConversationSummaryProviding
        if options.contains("--local") {
            service = { LocalSummaryService() }
        } else {
            guard let configuration = SummaryCloudConfiguration.load() else {
                print("NO CLOUD CONFIGURATION"); exit(2)
            }
            print("SUMMARY CLOUD MODEL \(configuration.model)")
            service = { AutomaticSummaryService(configuration: configuration) }
        }
        let model = ConversationSummaryModel(
            now: { started.addingTimeInterval(source.minutes * 60) },
            cloudAvailable: { false }, makeService: service)
        model.begin(sessionStartedAt: started) { source.rows }
        model.isExpanded = true
        let plan: [[String]] = options.contains("--long")
            ? longTopics.map { ["下面讨论\($0)。关于\($0)，负责人说明了目前进展和一个待定事项。", "\($0)的结论是先按现有方案推进，两周后复查。"] }
            : stages
        for (index, stage) in plan.enumerated() {
            source.rows += stage.map { CaptionEntry(timestamp: .now, englishText: "", chineseText: $0, sourceLanguage: .chinese) }
            source.minutes += options.contains("--long") ? 4 : 1
            let began = Date()
            model.requestNow()
            while model.isGenerating { try await Task.sleep(for: .milliseconds(50)) }
            if let error = model.errorMessage { print("STAGE \(index + 1) FAILED: \(error)"); exit(1) }
            print(String(format: "STAGE %d seconds=%.2f topics=%d points=%d changed=%@ backend=%@",
                index + 1, Date().timeIntervalSince(began), model.map.topics.count, model.map.pointCount,
                model.recentlyChangedTopicIDs.joined(separator: ","), model.backendDescription))
            if !options.contains("--long") || index == plan.count - 1 { print(model.map.outline); print("----") }
            fflush(stdout)
        }
        model.collapse()
    }
}
