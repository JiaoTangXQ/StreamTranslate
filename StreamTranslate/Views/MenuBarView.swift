import SwiftUI

struct MenuBarView: View {
    @Environment(CaptionViewModel.self) private var viewModel
    @Environment(CaptionSettings.self) private var settings
    var onToggleCapture: () -> Void
    var onOpenTranscript: () -> Void
    var onOpenSettings: () -> Void
    var onOpenPhone: () -> Void
    var onTogglePhoneOnly: () -> Void
    var onQuit: () -> Void

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(viewModel.isRecording ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("Cmd+Shift+T")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button(action: onToggleCapture) {
                Text(buttonLabel)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(
                viewModel.isStartingCapture
                    || viewModel.isFinalizingCapture
                    || viewModel.isPreparingTranslation
                    || !viewModel.isTranslationReady
                    || (viewModel.isLoading && !viewModel.isModelReady)
            )

            if settings.audioInputSource == .microphone,
               settings.selectedModel.backend == .whisperKit {
                HStack {
                    Text("收音灵敏度")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("收音灵敏度", selection: $settings.speechDetectionSensitivity) {
                        ForEach(SpeechDetectionSensitivity.allCases) { sensitivity in
                            Text(sensitivity.displayName).tag(sensitivity)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 112)
                }
                .disabled(
                    viewModel.isRecording
                        || viewModel.isStartingCapture
                        || viewModel.isFinalizingCapture
                )
            }

            Divider()

            if settings.phoneOnlyDisplay {
                Text("仅手机显示 · 电脑字幕已隐藏").font(.caption).foregroundStyle(.secondary)
                MenuBarActionButton("退出仅手机模式（显示电脑字幕）", action: onTogglePhoneOnly)
            } else {
                MenuBarActionButton("手机字幕…", action: onOpenPhone)
                MenuBarActionButton("查看历史记录…", action: onOpenTranscript)
                MenuBarActionButton("设置…", action: onOpenSettings)
            }
            MenuBarActionButton("退出 StreamTranslate", action: onQuit)
        }
        .padding(12)
        .frame(width: 220)
    }

    private var statusLabel: String {
        if viewModel.isLoading { return "正在准备语音模型…" }
        if viewModel.isPreparingTranslation { return "正在准备翻译…" }
        if viewModel.isFinalizingCapture { return "正在完成最后一句…" }
        if viewModel.isStartingCapture { return "正在启动收音…" }
        if viewModel.isRecording { return "正在翻译" }
        if viewModel.isModelReady { return "已就绪" }
        return "待机"
    }

    private var buttonLabel: String {
        if viewModel.isRecording { return "停止翻译" }
        if viewModel.isLoading { return "正在加载…" }
        if viewModel.isPreparingTranslation { return "正在准备…" }
        if viewModel.isFinalizingCapture { return "正在收尾…" }
        if viewModel.isStartingCapture { return "正在启动…" }
        return "开始翻译"
    }
}

private struct MenuBarActionButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(title)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(title)
    }
}
