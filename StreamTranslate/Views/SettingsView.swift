import SwiftUI

struct SettingsView: View {
    @Environment(CaptionSettings.self) private var settings
    @Environment(CaptionViewModel.self) private var viewModel

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Audio Input") {
                Picker("Source", selection: $settings.audioInputSource) {
                    ForEach(AudioInputSource.allCases) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.displayName)
                            Text(source.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(source)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(
                    viewModel.isRecording
                        || viewModel.isStartingCapture
                        || viewModel.isFinalizingCapture
                )

                if viewModel.isRecording
                    || viewModel.isStartingCapture
                    || viewModel.isFinalizingCapture {
                    Text("Stop recording before switching the audio source")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if settings.audioInputSource == .microphone,
                   settings.selectedModel.backend == .whisperKit {
                    Picker(
                        "Speech Detection Sensitivity",
                        selection: $settings.speechDetectionSensitivity
                    ) {
                        ForEach(SpeechDetectionSensitivity.allCases) { sensitivity in
                            Text(sensitivity.displayName).tag(sensitivity)
                        }
                    }
                    .disabled(
                        viewModel.isRecording
                            || viewModel.isStartingCapture
                            || viewModel.isFinalizingCapture
                    )

                    Text(settings.speechDetectionSensitivity.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if viewModel.isRecording
                        || viewModel.isStartingCapture
                        || viewModel.isFinalizingCapture {
                        Text("Stop recording before changing sensitivity")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else if settings.audioInputSource == .microphone {
                    Text("The selected streaming recognizer determines phrase boundaries itself; the sensitivity setting is not used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recognition Language") {
                Picker("Mode", selection: $settings.recognitionLanguageMode) {
                    ForEach(RecognitionLanguageMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(
                    viewModel.isRecording
                        || viewModel.isStartingCapture
                        || viewModel.isFinalizingCapture
                )

                Text(settings.recognitionLanguageMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Vocabulary") {
                    TextField(
                        "Argo CD, Kubernetes, project names…",
                        text: $settings.recognitionVocabulary,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .disabled(
                        viewModel.isRecording
                            || viewModel.isStartingCapture
                            || viewModel.isFinalizingCapture
                    )
                }

                Text("Comma-separated names and technical terms are supplied to the selected recognizer as context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.isRecording
                    || viewModel.isStartingCapture
                    || viewModel.isFinalizingCapture {
                    Text("Stop recording before changing recognition language")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Display") {
                LabeledContent("Panel Width") {
                    HStack {
                        Slider(value: $settings.panelWidth, in: 400...1000, step: 20)
                        Text("\(Int(settings.panelWidth))pt")
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                }

                LabeledContent("Panel Height") {
                    HStack {
                        Slider(value: $settings.panelHeight, in: 100...600, step: 20)
                        Text("\(Int(settings.panelHeight))pt")
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                }

                LabeledContent("Font Size") {
                    HStack {
                        Slider(value: $settings.fontSize, in: 10...24, step: 1)
                        Text("\(Int(settings.fontSize))pt")
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }

            Section("ASR Model") {
                Picker("Model", selection: $settings.selectedModelId) {
                    ForEach(ASRModel.available) { model in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.priorityName)
                            Text("\(model.name) · \(model.size) · \(model.tradeoff)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(model.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(
                    viewModel.isRecording
                        || viewModel.isStartingCapture
                        || viewModel.isFinalizingCapture
                        || viewModel.isLoading
                )

                if viewModel.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if viewModel.isRecording {
                    Text("Stop recording before switching models")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Translation Language") {
                Picker("Chinese variant", selection: $settings.translationTarget) {
                    ForEach(TranslationTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(viewModel.isRecording)

                if viewModel.isRecording {
                    Text("Stop recording before switching languages")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Diagnostics") {
                Toggle(
                    "Record source audio and detailed pipeline events",
                    isOn: $settings.captureDiagnosticsEnabled
                )
                .disabled(
                    viewModel.isRecording
                        || viewModel.isStartingCapture
                        || viewModel.isFinalizingCapture
                )

                Text("Use only while troubleshooting. Long sessions can consume substantial disk space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 600)
        .onChange(of: settings.selectedModelId) { _, newModelId in
            guard !viewModel.isRecording,
                  !viewModel.isStartingCapture,
                  !viewModel.isFinalizingCapture,
                  !viewModel.isLoading else { return }
            viewModel.switchModel(to: newModelId)
        }
    }
}
