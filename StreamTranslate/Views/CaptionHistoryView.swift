import SwiftUI

private struct HistorySelectionRevision: Equatable {
    let id: UUID?
    let revision: Int
}

/// Only the history window reads full journals; live captions never load them.
struct CaptionHistoryView: View {
    @Environment(CaptionViewModel.self) private var viewModel
    let store: CaptionHistoryStore
    @State private var sessions: [CaptionHistorySession] = []
    @State private var selectedID: UUID?
    @State private var captions: [CaptionEntry] = []
    @State private var loadedID: UUID?
    @State private var isLoading = true
    @State private var isClearing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("历史记录").font(.headline)
                    Text("字幕自动保存在这台 Mac 上，重启后仍可查看。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    Task { await clearAll() }
                } label: {
                    Label("清空全部记录", systemImage: "trash")
                }
                .disabled(isClearing || (sessions.isEmpty && viewModel.captionHistory.isEmpty
                    && errorMessage == nil && store.errorMessage == nil && store.readWarning == nil))
                .help("删除历史窗口中的全部记录，同时清空当前字幕。之后的新字幕继续保存；诊断日志单独保留。")
            }
            .padding(16)
            Divider()
            if let message = errorMessage ?? store.errorMessage ?? store.readWarning {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("重新读取") { Task { await reload(); await loadSelected() } }
                }
                .padding(12)
                Divider()
            }
            if sessions.isEmpty {
                if isLoading {
                    ProgressView("正在读取记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("还没有字幕记录", systemImage: "text.bubble",
                        description: Text("开始翻译后，完整字幕会自动保存在这里。悬浮窗只显示最近 100 条。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HSplitView {
                    List(sessions, selection: $selectedID) { session in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                                .font(.callout.weight(.medium))
                            Text(session.preview).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 5)
                        .tag(session.id)
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                    transcript
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .task(id: store.sessionListRevision) { await reload() }
        .task(id: HistorySelectionRevision(id: selectedID,
            revision: selectedID.flatMap { store.sessionRevisions[$0] } ?? 0)) {
            // Coalesce source/translation/review bursts. Updates to a different
            // session never re-read the selected transcript.
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await loadSelected()
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let selected = sessions.first(where: { $0.id == selectedID }) {
                    Text(selected.startedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                Text(loadedID == selectedID ? "\(captions.count) 条字幕" : "正在读取…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            if loadedID != selectedID {
                ProgressView("正在读取字幕…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(captions) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary)
                            Text(entry.originalText).font(.system(size: 14))
                            if !entry.translatedText.isEmpty {
                                Text(entry.translatedText).font(.system(size: 14))
                                    .foregroundStyle(Color(red: 0.47, green: 0.78, blue: 1.0))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
                .textSelection(.enabled)
            }
            .id(selectedID)
            }
        }
    }

    @MainActor private func reload() async {
        guard !isClearing else { return }
        do {
            let loaded = try await store.sessions()
            guard !Task.isCancelled, !isClearing else { return }
            sessions = loaded
            if !loaded.contains(where: { $0.id == selectedID }) { selectedID = loaded.first?.id }
            errorMessage = nil
            isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "读取记录失败：\(error.localizedDescription)"
            isLoading = false
        }
    }

    @MainActor private func loadSelected() async {
        guard let id = selectedID, !isClearing else { captions = []; return }
        do {
            let loaded = try await store.captions(in: id)
            guard !Task.isCancelled, selectedID == id, !isClearing else { return }
            captions = loaded
            loadedID = id
        } catch {
            guard !Task.isCancelled, selectedID == id else { return }
            captions = []
            loadedID = id
            errorMessage = "读取字幕失败：\(error.localizedDescription)"
        }
    }

    @MainActor private func clearAll() async {
        guard !isClearing else { return }
        isClearing = true
        viewModel.clearHistory()
        do {
            try await store.clear()
            sessions = []; captions = []; selectedID = nil; loadedID = nil
            errorMessage = nil
        } catch {
            errorMessage = "清空记录失败：\(error.localizedDescription)"
        }
        isClearing = false
        await reload()
    }
}
