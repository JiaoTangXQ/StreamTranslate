import SwiftUI
import Translation

/// Only mounted in an explicitly visible preflight window, never in private
/// presentation mode. Running translation uses installedSource sessions instead.
struct TranslationSetupView: View {
    let target: TranslationTarget
    let onReady: @MainActor () -> Void
    @State private var ready: Set<TranslationDirection> = []
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("准备本地中英文翻译").font(.headline)
            Text("请在演示前允许下载语言包。下载完成后，翻译不再依赖任何窗口。")
            if errorMessage.isEmpty { ProgressView() }
            else { Text(errorMessage).foregroundStyle(.red).font(.caption) }
        }
        .padding(20)
        .translationTask(TranslationService().configuration(direction: .englishToChinese, chineseTarget: target)) { session in
            await prepare(session, direction: .englishToChinese)
        }
        .translationTask(TranslationService().configuration(direction: .chineseToEnglish, chineseTarget: target)) { session in
            await prepare(session, direction: .chineseToEnglish)
        }
    }

    @MainActor private func prepare(_ session: TranslationSession, direction: TranslationDirection) async {
        do {
            let preparation = TranslationService()
            preparation.setSession(session, for: direction)
            try await preparation.prepare(direction)
            guard !Task.isCancelled else { return }
            ready.insert(direction)
            if ready.count == TranslationDirection.allCases.count { onReady() }
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}
