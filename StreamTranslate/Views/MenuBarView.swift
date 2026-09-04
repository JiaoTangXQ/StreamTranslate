import SwiftUI

struct MenuBarView: View {
    @Environment(CaptionViewModel.self) private var viewModel
    @Environment(CaptionSettings.self) private var settings
    var onToggleCapture: () -> Void
    var onOpenTranscript: () -> Void
    var onOpenSettings: () -> Void
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
                    Text("Sensitivity")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("Sensitivity", selection: $settings.speechDetectionSensitivity) {
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

            MenuBarActionButton("Open Transcript", action: onOpenTranscript)
            MenuBarActionButton("Settings...", action: onOpenSettings)
            MenuBarActionButton("Quit StreamTranslate", action: onQuit)
        }
        .padding(12)
        .frame(width: 220)
    }

    private var statusLabel: String {
        if viewModel.isLoading { return viewModel.statusMessage.isEmpty ? "Loading model..." : viewModel.statusMessage }
        if viewModel.isPreparingTranslation { return "Preparing translation..." }
        if viewModel.isFinalizingCapture { return "Finalizing last words..." }
        if viewModel.isStartingCapture { return "Starting audio..." }
        if viewModel.isRecording { return "Recording" }
        if viewModel.isModelReady { return "Ready" }
        return "Idle"
    }

    private var buttonLabel: String {
        if viewModel.isRecording { return "Stop" }
        if viewModel.isLoading { return "Loading..." }
        if viewModel.isPreparingTranslation { return "Preparing..." }
        if viewModel.isFinalizingCapture { return "Finalizing..." }
        if viewModel.isStartingCapture { return "Starting..." }
        return "Start"
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
