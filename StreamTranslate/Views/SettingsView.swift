import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case listening, appearance, intelligence, privacy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .listening: "声音与语言"
        case .appearance: "字幕外观"
        case .intelligence: "识别与翻译"
        case .privacy: "隐私与诊断"
        }
    }
    var symbol: String {
        switch self {
        case .listening: "waveform"
        case .appearance: "textformat.size"
        case .intelligence: "slider.horizontal.3"
        case .privacy: "lock.shield"
        }
    }
    var subtitle: String {
        switch self {
        case .listening: "选择要听的声音，以及它使用的语言。"
        case .appearance: "让字幕以舒服的大小，安静地留在画面里。"
        case .intelligence: "选择识别方式，在响应速度与准确度之间找到平衡。"
        case .privacy: "了解数据去向，只在需要排查时留下诊断记录。"
        }
    }
}

private enum SettingsTheme {
    static let background = Color(red: 0.063, green: 0.067, blue: 0.071)
    static let sidebar = Color(red: 0.078, green: 0.082, blue: 0.086)
    static let card = Color.white.opacity(0.035)
    static let line = Color.white.opacity(0.075)
    static let ink = Color(red: 0.95, green: 0.94, blue: 0.92)
    static let muted = Color(white: 0.62)
    static let accent = Color(red: 0.84, green: 0.22, blue: 0.20)
}

struct SettingsView: View {
    @Environment(CaptionSettings.self) private var settings
    @Environment(CaptionViewModel.self) private var viewModel
    @State private var page: SettingsPage

    init(initialPage: SettingsPage = .listening) {
        _page = State(initialValue: initialPage)
    }

    private var captureBusy: Bool {
        viewModel.isRecording || viewModel.isStartingCapture || viewModel.isFinalizingCapture
    }
    private var modelBusy: Bool { captureBusy || viewModel.isLoading }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(SettingsTheme.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(page.title).font(.system(size: 26, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(page.subtitle).font(.system(size: 12)).foregroundStyle(SettingsTheme.muted)
                }.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 22)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if captureBusy && page != .appearance {
                            Label("正在翻译。停止后可修改声音、语言和模型设置。", systemImage: "lock")
                                .font(.system(size: 12)).foregroundStyle(SettingsTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        switch page {
                        case .listening: listening
                        case .appearance: appearance
                        case .intelligence: intelligence
                        case .privacy: privacy
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 28)
                }
                .id(page)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 540, idealHeight: 650)
        .background(SettingsTheme.background)
        .foregroundStyle(SettingsTheme.ink)
        .tint(SettingsTheme.accent)
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .background(SettingsWindowVisibility().allowsHitTesting(false))
        .onChange(of: settings.selectedModelId) { _, newModelId in
            guard !viewModel.isChangingCaptureConfiguration, !modelBusy else { return }
            viewModel.switchModel(to: newModelId)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                if let icon = NSImage(named: "StreamTranslate") {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 34, height: 34)
                } else {
                    Image(systemName: "waveform").font(.system(size: 22)).foregroundStyle(SettingsTheme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("StreamTranslate").font(.system(size: 12, weight: .semibold))
                    Text("让理解，安静发生。").font(.system(size: 10)).foregroundStyle(SettingsTheme.muted)
                }
            }.padding(.horizontal, 16).padding(.top, 28).padding(.bottom, 34)
            VStack(spacing: 6) {
                ForEach(SettingsPage.allCases) { item in
                    Button {
                        page = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).frame(width: 18)
                            Text(item.title)
                            Spacer(minLength: 0)
                            if page == item {
                                Circle().fill(SettingsTheme.accent).frame(width: 5, height: 5)
                            }
                        }
                        .font(.system(size: 13, weight: page == item ? .medium : .regular))
                        .foregroundStyle(page == item ? SettingsTheme.ink : SettingsTheme.muted)
                        .padding(.horizontal, 12).frame(height: 42)
                        .background(page == item ? Color.white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-page-\(item.rawValue)")
                    .accessibilityAddTraits(page == item ? [.isSelected] : [])
                }
            }.padding(.horizontal, 10)
            Spacer()
            VStack(alignment: .leading, spacing: 7) {
                Label("识别与翻译在本机完成", systemImage: "desktopcomputer")
                    .font(.system(size: 10))
                Text("设置即时保存").font(.system(size: 10))
            }.foregroundStyle(SettingsTheme.muted).padding(20)
        }
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(SettingsTheme.sidebar)
    }

    private var listening: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 18) {
            section("音频来源") {
                HStack(spacing: 10) {
                    sourceChoice(.systemAudio, icon: "desktopcomputer")
                    sourceChoice(.microphone, icon: "mic")
                }.disabled(captureBusy)
                if settings.audioInputSource == .microphone {
                    if settings.selectedModel.backend == .whisperKit {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("收音灵敏度").font(.system(size: 13))
                            Picker("收音灵敏度", selection: $settings.speechDetectionSensitivity) {
                                ForEach(SpeechDetectionSensitivity.allCases) { Text($0.displayName).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().disabled(captureBusy)
                        }
                        note(settings.speechDetectionSensitivity.detail)
                    } else {
                        note("当前流式模型会自动判断说话停顿，无需设置收音灵敏度。")
                    }
                }
            }
            section("语言") {
                Picker("识别语言", selection: $settings.recognitionLanguageMode) {
                    ForEach(RecognitionLanguageMode.allCases) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented).disabled(modelBusy)
                note(settings.recognitionLanguageMode.detail)
                Divider().overlay(SettingsTheme.line)
                Picker("中文译文", selection: $settings.translationTarget) {
                    ForEach(TranslationTarget.allCases) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented).disabled(captureBusy)
                note("中文语音译为英文；英文语音译为所选中文。")
            }
            section("专有词汇") {
                TextField("例如：项目名称、人名、Kubernetes", text: $settings.recognitionVocabulary, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .lineLimit(2...4).padding(12)
                    .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(SettingsTheme.line))
                    .accessibilityLabel("专有词汇")
                    .disabled(captureBusy)
                note("多个词汇用英文逗号分隔，将作为识别上下文提供给当前模型。")
            }
        }
    }

    private func sourceChoice(_ source: AudioInputSource, icon: String) -> some View {
        let selected = settings.audioInputSource == source
        return Button {
            settings.audioInputSource = source
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: icon).font(.system(size: 17))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? SettingsTheme.accent : SettingsTheme.muted.opacity(0.5))
                }
                Text(source.displayName).font(.system(size: 13, weight: .medium))
                Text(source.detail).font(.system(size: 11)).foregroundStyle(SettingsTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.white.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.white.opacity(0.28) : SettingsTheme.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(source.displayName)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var appearance: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 18) {
            section("阅读预览") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("让每一句话，都被理解。")
                        .font(.system(size: settings.fontSize))
                    Text("字幕会留在这里，界面退到背景。")
                        .font(.system(size: settings.fontSize - 1)).foregroundStyle(SettingsTheme.muted)
                }.frame(maxWidth: .infinity, minHeight: 104, alignment: .leading).padding(16)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                note("按实际字号预览。使用示例文字，不会启动录音或显示你的会议内容。")
            }
            section("字幕窗口") {
                dimension("文字大小", value: $settings.fontSize, range: 10...24, step: 1)
                Divider().overlay(SettingsTheme.line)
                dimension("窗口宽度", value: $settings.panelWidth, range: 400...max(1000, NSScreen.main?.visibleFrame.width ?? 1000), step: 20)
                Divider().overlay(SettingsTheme.line)
                dimension("窗口高度", value: $settings.panelHeight, range: 144...max(600, NSScreen.main?.visibleFrame.height ?? 600), step: 4)
                note("这些设置只影响 Mac 字幕。手机字号可在手机阅读页轻点屏幕后调整。")
            }
        }
    }

    private func dimension(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text("\(Int(value.wrappedValue)) 磅").font(.system(size: 12, design: .monospaced)).foregroundStyle(SettingsTheme.muted)
            }
            Slider(value: Binding(get: { value.wrappedValue }, set: {
                let snapped = (($0 - range.lowerBound) / step).rounded() * step + range.lowerBound
                value.wrappedValue = min(range.upperBound, max(range.lowerBound, snapped))
            }), in: range).accessibilityLabel(title)
        }
    }

    private var intelligence: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 18) {
            section("语音识别模型") {
                note("切换模型会同步调整它支持的识别语言，不会自动开始录音。")
                ForEach(ASRModel.available) { model in
                    Button {
                        settings.selectedModelId = model.id
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: settings.selectedModelId == model.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(settings.selectedModelId == model.id ? SettingsTheme.accent : SettingsTheme.muted.opacity(0.5))
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.priorityName).font(.system(size: 13, weight: .medium))
                                Text("\(model.name) · \(model.size)").font(.system(size: 11)).foregroundStyle(SettingsTheme.muted)
                                Text(model.tradeoff).font(.system(size: 11)).foregroundStyle(SettingsTheme.muted)
                            }
                            Spacer(minLength: 0)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(settings.selectedModelId == model.id ? Color.white.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(modelBusy)
                        .accessibilityLabel("\(model.priorityName)，\(model.name)")
                        .accessibilityAddTraits(settings.selectedModelId == model.id ? [.isSelected] : [])
                }
                if viewModel.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在准备语音模型…").font(.system(size: 12)).foregroundStyle(SettingsTheme.muted)
                    }
                }
            }
            section("本地增强") {
                Toggle(isOn: $settings.recognitionReviewEnabled) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("句尾识别复核").font(.system(size: 13, weight: .medium))
                        note("Qwen · 本机 Metal 加速")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.switch).disabled(captureBusy)
                note(LocalQwenService.isInstalled
                    ? "先显示流式字幕，再复核同一句。适用于 Apple 和 Nemotron，后台模型就绪后生效；不上传音频。"
                    : "复核模型暂不可用，继续使用原有识别。若模型在外置磁盘，请保持磁盘连接。")
                Divider().overlay(SettingsTheme.line)
                Toggle(isOn: $settings.translationRefinementEnabled) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("译文终稿精修").font(.system(size: 13, weight: .medium))
                        note("Hy-MT · 中英双向")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.switch).disabled(captureBusy)
                note(LocalHYTranslationService.isInstalled
                    ? "先显示快速译文，再精修终稿。内存紧张时自动使用系统翻译；并非每句都能获得提升。"
                    : "增强模型暂不可用，继续使用 Apple 翻译。若模型在外置磁盘，请保持磁盘连接。")
            }
        }
    }

    private var privacy: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 18) {
            section("数据去向") {
                Label("音频处理留在这台 Mac", systemImage: "desktopcomputer")
                    .font(.system(size: 14, weight: .medium))
                note("语音识别和翻译在本机完成。手机字幕启用后会传输文字，不传输原始音频。")
                Divider().overlay(SettingsTheme.line)
                note("跨网络模式将加密字幕经你的中转服务器发送给手机；局域网快速连接使用未加密的 HTTP，仅适合可信网络。连接方式在「手机字幕」中管理。")
            }
            section("故障诊断") {
                Toggle(isOn: $settings.captureDiagnosticsEnabled) {
                    Text("保存音频与详细诊断记录").font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.switch).disabled(captureBusy)
                note("仅建议在排查问题时开启。记录包含原始音频与识别、翻译过程，可能涉及隐私，长时间使用会占用较多磁盘空间。")
                if settings.captureDiagnosticsEnabled {
                    Label("诊断记录已开启，请留意录制内容的隐私。", systemImage: "exclamationmark.shield")
                        .font(.system(size: 12)).foregroundStyle(SettingsTheme.accent)
                }
                note("关闭后不再生成新记录，已有记录不会自动删除。")
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(SettingsTheme.muted)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(SettingsTheme.line))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(SettingsTheme.muted)
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
}

/// Preserve the private-window guard and keep settings above the caption overlay.
private struct SettingsWindowVisibility: NSViewRepresentable {
    final class AttachmentView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            window.hidesOnDeactivate = true
            window.title = "设置"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0.063, green: 0.067, blue: 0.071, alpha: 1)
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
        }
    }
    func makeNSView(context: Context) -> AttachmentView { AttachmentView() }
    func updateNSView(_ view: AttachmentView, context: Context) {}
}
