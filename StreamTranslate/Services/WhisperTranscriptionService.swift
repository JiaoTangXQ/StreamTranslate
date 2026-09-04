import Foundation
import WhisperKit

enum TranscriptionPass: Sendable, Equatable {
    case preview
    case final
}

final class WhisperTranscriptionService: @unchecked Sendable {
    private let whisperKit: WhisperKit

    private init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    static func load(
        modelId: String,
        onDownloadProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> WhisperTranscriptionService {
        let downloadBase = defaultDownloadBase
        let cachedFolder = localModelFolder(
            modelId: modelId,
            downloadBase: downloadBase
        )
        let modelFolder: URL
        if isCompleteModelFolder(cachedFolder) {
            modelFolder = cachedFolder
            onDownloadProgress(1)
        } else {
            modelFolder = try await WhisperKit.download(
                variant: modelId,
                downloadBase: downloadBase,
                progressCallback: { progress in
                    onDownloadProgress(progress.fractionCompleted)
                }
            )
        }
        let kit = try await WhisperKit(
            downloadBase: downloadBase,
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        return WhisperTranscriptionService(whisperKit: kit)
    }

    static var defaultDownloadBase: URL {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("huggingface", isDirectory: true)
    }

    static func localModelFolder(
        modelId: String,
        downloadBase: URL
    ) -> URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(modelId, isDirectory: true)
    }

    static func isCompleteModelFolder(_ folder: URL) -> Bool {
        let requiredPaths = [
            "config.json",
            "AudioEncoder.mlmodelc/coremldata.bin",
            "MelSpectrogram.mlmodelc/coremldata.bin",
            "TextDecoder.mlmodelc/coremldata.bin",
        ]
        return requiredPaths.allSatisfy {
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent($0).path
            )
        }
    }

    func transcribe(
        _ samples: [Float],
        languageHint: SpokenLanguage? = nil,
        prompt: String? = nil,
        currentAudioOffset: TimeInterval? = nil,
        pass: TranscriptionPass = .final
    ) async throws -> TranscriptionOutput? {
        guard !samples.isEmpty else { return nil }

        var options = pass == .preview
            ? Self.previewDecodingOptions
            : Self.decodingOptions
        if let languageHint {
            options.language = languageHint.rawValue
            options.detectLanguage = false
        }
        if let prompt,
           let tokenizer = whisperKit.tokenizer {
            let promptText = " " + String(
                prompt.trimmingCharacters(in: .whitespacesAndNewlines).suffix(240)
            )
            options.promptTokens = tokenizer
                .encode(text: promptText)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                .suffix(128)
                .map { $0 }
        }
        if currentAudioOffset != nil {
            options.withoutTimestamps = false
            options.wordTimestamps = true
        }

        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        let allWords = results.flatMap(\.allWords)
        let currentWords: [WordTiming]
        if let currentAudioOffset {
            let boundary = Float(currentAudioOffset) - 0.1
            currentWords = allWords.filter { $0.end >= boundary }
        } else {
            currentWords = allWords
        }
        let text: String
        if currentAudioOffset != nil {
            text = currentWords
                .map(\.word)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }
        guard !TranscriptionTextPolicy.isDegenerateRepetition(text) else {
            return nil
        }
        guard !TranscriptionTextPolicy.isNonSpeechOnly(text) else { return nil }

        let reportedLanguage = results.first?.language ?? ""
        let language = languageHint ?? SpokenLanguage.resolve(
            whisperCode: reportedLanguage,
            text: text
        )
        let timestampOffset = Float(currentAudioOffset ?? 0)
        let words = currentWords.map { word in
            WordTimestamp(
                word: word.word,
                start: max(0, word.start - timestampOffset),
                end: max(0, word.end - timestampOffset),
                confidence: word.probability
            )
        }
        let allSegments = results.flatMap(\.segments)
        let segments: [TranscriptionSegment]
        if let currentAudioOffset {
            let boundary = Float(currentAudioOffset) - 0.1
            segments = allSegments.filter { $0.end >= boundary }
        } else {
            segments = allSegments
        }
        let tokenCount = segments.reduce(0) { $0 + max(1, $1.tokens.count) }
        let averageLogProbability: Float? = tokenCount > 0
            ? segments.reduce(Float.zero) {
                $0 + ($1.avgLogprob * Float(max(1, $1.tokens.count)))
            } / Float(tokenCount)
            : nil
        let noSpeechProbability: Float? = segments.isEmpty
            ? nil
            : segments.reduce(Float.zero) { $0 + $1.noSpeechProb }
                / Float(segments.count)
        return TranscriptionOutput(
            text: text,
            language: language,
            reportedLanguageCode: reportedLanguage,
            words: words,
            averageLogProbability: averageLogProbability,
            noSpeechProbability: noSpeechProbability
        )
    }

    static var decodingOptions: DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: nil,
            temperature: 0,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            chunkingStrategy: nil
        )
    }

    static var previewDecodingOptions: DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: nil,
            temperature: 0,
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            firstTokenLogProbThreshold: nil,
            noSpeechThreshold: 0.6,
            chunkingStrategy: nil
        )
    }
}
