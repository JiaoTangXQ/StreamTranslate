import Foundation

enum AudioInputSource: String, CaseIterable, Identifiable {
    case microphone
    case systemAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System Audio"
        }
    }

    var detail: String {
        switch self {
        case .microphone: return "People speaking near this Mac"
        case .systemAudio: return "Audio playing on this Mac"
        }
    }
}

enum SpeechDetectionSensitivity: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case farField
    case nearby

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .farField: return "Far (2–3 m)"
        case .nearby: return "Near (≤1 m)"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Adapts to room noise. Recommended for most meetings."
        case .farField:
            return "Detects quieter speakers, but may also react to keyboard and room noise."
        case .nearby:
            return "Ignores more distant sound when the speaker is close to the Mac."
        }
    }
}

enum RecognitionLanguageMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case chinese
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "自动"
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "每段独立判断中文或英文，适合双语交替。"
        case .chinese:
            return "固定按中文识别，避免短句被误判成其他语言。"
        case .english:
            return "固定按英文识别，避免短句被误判成其他语言。"
        }
    }

    var languageHint: SpokenLanguage? {
        switch self {
        case .automatic: return nil
        case .chinese: return .chinese
        case .english: return .english
        }
    }
}

/// BCP-47 targets that the Apple Translation framework understands for
/// English → Chinese. The raw value is what gets written to UserDefaults and
/// passed to `Locale.Language(identifier:)`, so it must round-trip cleanly.
enum TranslationTarget: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChineseTaiwan = "zh-Hant-TW"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChineseTaiwan: return "繁體中文（台灣）"
        }
    }
}

struct ASRModel: Identifiable, Hashable {
    enum Backend: String, Hashable, Sendable {
        case nemotron
        case appleSpeech
        case whisperKit
    }

    let id: String
    let backend: Backend
    let priorityName: String
    let name: String
    let size: String
    let tradeoff: String
    let firstPreviewInterval: TimeInterval
    let subsequentPreviewInterval: TimeInterval
    let maximumUtteranceDuration: TimeInterval
    let usesRollingAudioContext: Bool

    static let available: [ASRModel] = [
        ASRModel(
            id: "nvidia-nemotron-streaming-en-0.6b",
            backend: .nemotron,
            priorityName: "最低延迟（本机安装）",
            name: "Nemotron Streaming English",
            size: "667MB / 约1GB内存",
            tradeoff: "Metal增量识别；仅固定英文模式",
            firstPreviewInterval: 0,
            subsequentPreviewInterval: 0,
            maximumUtteranceDuration: 0,
            usesRollingAudioContext: false
        ),
        ASRModel(
            id: "apple-speech-transcriber-en",
            backend: .appleSpeech,
            priorityName: "英译中流式",
            name: "Apple Speech English",
            size: "系统内置",
            tradeoff: "连续增量识别；仅固定英文模式",
            firstPreviewInterval: 0,
            subsequentPreviewInterval: 0,
            maximumUtteranceDuration: 0,
            usesRollingAudioContext: false
        ),
        ASRModel(
            id: "openai_whisper-small",
            backend: .whisperKit,
            priorityName: "速度优先",
            name: "Whisper Small Multilingual",
            size: "~465MB",
            tradeoff: "延迟较低",
            firstPreviewInterval: 0.75,
            subsequentPreviewInterval: 0.75,
            maximumUtteranceDuration: 8,
            usesRollingAudioContext: false
        ),
        ASRModel(
            id: "openai_whisper-large-v3-v20240930_626MB",
            backend: .whisperKit,
            priorityName: "准确度优先",
            name: "Whisper Large-v3 Turbo",
            size: "~626MB",
            tradeoff: "通常识别更准，延迟较高",
            firstPreviewInterval: 1,
            subsequentPreviewInterval: 1.5,
            maximumUtteranceDuration: 15,
            usesRollingAudioContext: true
        ),
    ]

    static let defaultModel = available[1]

    static let whisperFallback = available.first {
        $0.id == "openai_whisper-small"
    }!

    var supportsOnlyEnglish: Bool {
        backend != .whisperKit
    }

    var usesNativeStreaming: Bool {
        backend != .whisperKit
    }
}

@MainActor
@Observable
final class CaptionSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var audioInputSource: AudioInputSource {
        didSet {
            defaults.set(audioInputSource.rawValue, forKey: "audioInputSource")
        }
    }

    var panelWidth: CGFloat {
        didSet { defaults.set(Double(panelWidth), forKey: "panelWidth") }
    }

    var panelHeight: CGFloat {
        didSet { defaults.set(Double(panelHeight), forKey: "panelHeight") }
    }

    var speechDetectionSensitivity: SpeechDetectionSensitivity {
        didSet {
            defaults.set(
                speechDetectionSensitivity.rawValue,
                forKey: "speechDetectionSensitivity"
            )
        }
    }

    var recognitionLanguageMode: RecognitionLanguageMode {
        didSet {
            defaults.set(
                recognitionLanguageMode.rawValue,
                forKey: "recognitionLanguageMode"
            )
            if recognitionLanguageMode != .english,
               selectedModel.supportsOnlyEnglish {
                selectedModelId = ASRModel.whisperFallback.id
            }
        }
    }

    var recognitionVocabulary: String {
        didSet {
            defaults.set(recognitionVocabulary, forKey: "recognitionVocabulary")
        }
    }

    var captureDiagnosticsEnabled: Bool {
        didSet {
            defaults.set(captureDiagnosticsEnabled, forKey: "captureDiagnosticsEnabled")
        }
    }

    var fontSize: CGFloat {
        didSet { defaults.set(Double(fontSize), forKey: "fontSize") }
    }

    var selectedModelId: String {
        didSet {
            defaults.set(selectedModelId, forKey: "selectedModelId")
            if selectedModel.supportsOnlyEnglish,
               recognitionLanguageMode != .english {
                recognitionLanguageMode = .english
            }
        }
    }

    var translationTarget: TranslationTarget {
        didSet {
            defaults.set(translationTarget.rawValue, forKey: "translationTarget")
        }
    }

    var selectedModel: ASRModel {
        ASRModel.available.first { $0.id == selectedModelId } ?? ASRModel.defaultModel
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedAudioInput = defaults.string(forKey: "audioInputSource")
            .flatMap(AudioInputSource.init(rawValue:))
        audioInputSource = savedAudioInput ?? .microphone

        let savedWidth = defaults.double(forKey: "panelWidth")
        panelWidth = savedWidth > 0 ? CGFloat(savedWidth) : 620

        let savedHeight = defaults.double(forKey: "panelHeight")
        panelHeight = savedHeight > 0 ? CGFloat(savedHeight) : 200

        let savedSensitivity = defaults.string(forKey: "speechDetectionSensitivity")
            .flatMap(SpeechDetectionSensitivity.init(rawValue:))
        speechDetectionSensitivity = savedSensitivity ?? .automatic

        let savedRecognitionMode = defaults.string(forKey: "recognitionLanguageMode")
            .flatMap(RecognitionLanguageMode.init(rawValue:))
        recognitionLanguageMode = savedRecognitionMode ?? .english

        recognitionVocabulary = defaults.string(forKey: "recognitionVocabulary") ?? ""

        captureDiagnosticsEnabled = defaults.bool(forKey: "captureDiagnosticsEnabled")

        let savedFontSize = defaults.double(forKey: "fontSize")
        fontSize = savedFontSize > 0 ? CGFloat(savedFontSize) : 15

        let savedModelId = defaults.string(forKey: "selectedModelId")
        // Migrate model IDs that are no longer supported to the low-latency
        // multilingual default.
        if let saved = savedModelId, ASRModel.available.contains(where: { $0.id == saved }) {
            selectedModelId = saved
        } else {
            selectedModelId = ASRModel.defaultModel.id
        }

        let savedTarget = defaults.string(forKey: "translationTarget")
            .flatMap(TranslationTarget.init(rawValue:))
        translationTarget = savedTarget ?? .simplifiedChinese

        if selectedModel.supportsOnlyEnglish,
           recognitionLanguageMode != .english {
            recognitionLanguageMode = .english
        }
    }
}
