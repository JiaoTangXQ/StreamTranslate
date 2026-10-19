import SwiftUI

@Observable
final class CaptionControlsVisibility {
    private(set) var isVisible = true
    // Pointer timestamps are bookkeeping, not display state. Observing them
    // invalidated the entire caption view on every hover event and timer tick.
    @ObservationIgnored private var lastActivity = Date()
    func reveal(at date: Date = .now) {
        lastActivity = date
        if !isVisible { isVisible = true }
    }
    func update(at date: Date = .now, keepVisible: Bool) {
        if keepVisible { reveal(at: date) }
        else if isVisible, date.timeIntervalSince(lastActivity) >= 3 { isVisible = false }
    }
}

/// Controls stay in the reading surface. The popover is for a single choice,
/// not another settings hierarchy; source changes are direct buttons.
struct CaptionQuickControls: View {
    @Environment(CaptionViewModel.self) private var viewModel
    @Environment(CaptionSettings.self) private var settings
    @State private var languageOpen = false
    @State private var hovered = false
    @State private var keyboardNavigation = false
    @FocusState private var focused: String?
    let onEngagement: (Bool) -> Void
    let onSettings: () -> Void
    let onPhone: () -> Void
    let onMinimize: () -> Void
    var onHistory: () -> Void = {}

    private var switchingDisabled: Bool {
        viewModel.isChangingCaptureConfiguration || viewModel.isStartingCapture
            || viewModel.isFinalizingCapture || viewModel.isLoading
    }
    private var toggleDisabled: Bool {
        if viewModel.isChangingCaptureConfiguration || viewModel.isRecording { return false }
        return viewModel.isStartingCapture || viewModel.isFinalizingCapture
            || viewModel.isLoading || !viewModel.isTranslationReady
    }
    private var feedback: String {
        if let error = viewModel.historyStore?.errorMessage { return error }
        if !viewModel.quickControlMessage.isEmpty { return viewModel.quickControlMessage }
        return viewModel.isRecording ? "" : viewModel.statusMessage
    }
    var body: some View {
        VStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                bar(compact: false)
                bar(compact: true)
            }
            if !feedback.isEmpty {
                Text(feedback).font(.caption).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            }
        }
        .padding(6)
        .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.16)))
        .foregroundStyle(.white)
        .onHover { hovered = $0; reportEngagement() }
        .onContinuousHover { phase in
            if case .active = phase { keyboardNavigation = false; reportEngagement() }
        }
        .onKeyPress(.tab) { keyboardNavigation = true; reportEngagement(); return .ignored }
        .onChange(of: focused) { reportEngagement() }
        .onChange(of: languageOpen) { reportEngagement() }
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: compact ? 2 : 6) {
            action(viewModel.isChangingCaptureConfiguration ? "取消恢复" : viewModel.isRecording ? "停止翻译" : "开始翻译",
                   icon: viewModel.isChangingCaptureConfiguration || viewModel.isRecording ? "stop.fill" : "play.fill") {
                viewModel.toggleCapture(source: settings.audioInputSource,
                    sensitivity: settings.speechDetectionSensitivity,
                    recognitionMode: settings.recognitionLanguageMode,
                    recognitionVocabulary: settings.recognitionVocabulary,
                    captureDiagnosticsEnabled: settings.captureDiagnosticsEnabled)
            }.disabled(toggleDisabled)
            Divider().frame(height: 20)
            source(.microphone, title: "麦克风", icon: "mic.fill", compact: compact)
            source(.systemAudio, title: "电脑音频", icon: "desktopcomputer", compact: compact)
            Button { languageOpen.toggle() } label: {
                HStack(spacing: 3) {
                    if compact {
                        Image(systemName: "character.bubble").frame(width: 30)
                    } else {
                        Text(settings.recognitionLanguageMode == .english ? "英文" : settings.recognitionLanguageMode.displayName)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }.font(.system(size: 12, weight: .medium)).frame(minHeight: 32)
                    .padding(.horizontal, compact ? 0 : 6)
            }
            .buttonStyle(.plain).focused($focused, equals: "language")
            .help("识别语言：自动 / 中文 / 英文")
            .accessibilityLabel("识别语言，当前\(settings.recognitionLanguageMode.displayName)")
            .disabled(switchingDisabled)
            .popover(isPresented: $languageOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("识别哪种语言？").font(.headline)
                    ForEach(RecognitionLanguageMode.allCases) { mode in
                        Button {
                            languageOpen = false
                            viewModel.changeCaptureConfiguration(settings: settings, mode: mode)
                        } label: {
                            HStack {
                                Text(mode == .english ? "英文" : mode.displayName)
                                Spacer()
                                if mode == settings.recognitionLanguageMode { Image(systemName: "checkmark") }
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
                    Text("自动适合中英文交替；首次可能下载多语模型。固定语言可使用专用流式识别。录音中切换会短暂中断并自动恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(width: 250)
            }
            Spacer(minLength: 0)
            action("查看历史记录", icon: "clock.arrow.circlepath", perform: onHistory)
            action("在手机看字幕", icon: "iphone", perform: onPhone)
            action("更多设置", icon: "slider.horizontal.3", perform: onSettings)
            action("最小化", icon: "minus", perform: onMinimize)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    private func source(_ source: AudioInputSource, title: String, icon: String, compact: Bool) -> some View {
        Button { viewModel.changeCaptureConfiguration(settings: settings, source: source) } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                if !compact { Text(title).font(.system(size: 12, weight: .medium)) }
            }.frame(minWidth: 30, minHeight: 32).padding(.horizontal, compact ? 0 : 6)
                .background(settings.audioInputSource == source ? Color.cyan.opacity(0.23) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).focused($focused, equals: source.rawValue)
            .help("切换到\(title)；正在翻译时自动收尾并恢复")
            .accessibilityLabel(title).accessibilityAddTraits(settings.audioInputSource == source ? .isSelected : [])
            .disabled(switchingDisabled)
    }
    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focused, equals: title)
            .help(title).accessibilityLabel(title)
    }
    private func reportEngagement() { onEngagement(hovered || (keyboardNavigation && focused != nil) || languageOpen) }
}
