import Foundation
import AppKit

/// Synthetic text only. No user transcript, audio, preferences or shared log.
@main enum ConversationSummaryProbe {
    @MainActor static func main() async throws {
        let service = LocalSummaryService()
        defer { service.cancel() }
        let start = Date()
        try await service.prepare()
        print("SUMMARY MODEL READY seconds=\(Date().timeIntervalSince(start))")
        let input = """
        用户：软件用了半小时后鼠标经过界面很卡，界面显示还在运行，但没有新字幕。重启后恢复。
        开发者：确认历史字幕全量布局增加了界面耗时。静默停字幕的原因还没有通过真实语音复现。
        用户：悬浮窗最多显示100条就行，完整记录保存在本机，另外加查看历史和一键清空。
        开发者：已确定保留100条实时字幕，完整文字本地保存。清空只删除历史记录，诊断日志单独保留。
        用户：再加一个右侧可折叠的AI总结，让人知道这次对话大概在说什么。
        开发者：先在本机按需生成中文总结，有新内容时手动更新；是否持续自动更新暂未确定。
        用户：总结不要说停字幕问题已经解决，也不要捏造我们没有决定的事情。
        """
        let text = try await service.summarize(input, previous: "")
        print(text)
        print("SUMMARY COMPLETE seconds=\(Date().timeIntervalSince(start))")
        let updated = try await service.summarize("补充讨论：暂时维持手动更新总结。有新字幕时显示更新提示，不持续自动推理。原来的静默停字幕问题仍需继续排查。", previous: text)
        print("INCREMENTAL SUMMARY\n\(updated)")
        print("INCREMENTAL COMPLETE seconds=\(Date().timeIntervalSince(start))")
    }
}
