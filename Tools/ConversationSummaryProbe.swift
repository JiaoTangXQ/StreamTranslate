import Foundation
import AppKit

/// Synthetic text only. No user transcript, audio or preferences. The production
/// service may append process metadata to the shared diagnostic log.
@main enum ConversationSummaryProbe {
    @MainActor static func main() async throws {
        let options = CommandLine.arguments
        let override = options.firstIndex(of: "--model").flatMap { index -> LocalModelAssets? in
            guard options.indices.contains(index + 1), let base = LocalSummaryService.assets else { return nil }
            return LocalModelAssets(executable: base.executable, model: URL(fileURLWithPath: options[index + 1]))
        }
        let service = LocalSummaryService(assets: override)
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
        var updates = 0
        let text = try await service.summarize(input, previous: "") { partial in
            updates += 1
            if updates == 1 { print("STREAM FIRST UPDATE seconds=\(Date().timeIntervalSince(start)) chars=\(partial.count)"); fflush(nil) }
        }
        print("STREAM UPDATE COUNT=\(updates)")
        print(text)
        guard let map = ConversationMindMap.parse(text), map.topic != "本次对话", !map.branches.isEmpty else {
            throw SummaryError.invalidResult
        }
        print("MINDMAP topic=\(map.topic) branches=\(map.branches.count)")
        print("SUMMARY COMPLETE seconds=\(Date().timeIntervalSince(start))")
        let updated = try await service.summarize("现在明确决定：展开脑图时自动更新，折叠后暂停，不再需要手动点击更新。原来的静默停字幕问题仍需继续排查。", previous: text)
        print("INCREMENTAL SUMMARY\n\(updated)")
        print("INCREMENTAL COMPLETE seconds=\(Date().timeIntervalSince(start))")
    }
}
