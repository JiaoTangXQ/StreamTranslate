import Foundation
import Darwin

@main
struct CaptionStabilityAnalyzer {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(
                Data("usage: analyze-caption-stability <pipeline.jsonl>\n".utf8)
            )
            exit(2)
        }

        let contents = try String(
            contentsOfFile: CommandLine.arguments[1],
            encoding: .utf8
        )
        var stabilizers: [Int64: CaptionTextStabilizer] = [:]
        var previousRaw: [Int64: String] = [:]
        var previousStable: [Int64: String] = [:]
        var lastTranslationRequest: [Int64: String] = [:]
        var partialCount = 0
        var rawTransitions = 0
        var rawRewrites = 0
        var optimizedTranslationRequests = 0
        var partialStableRollbacks = 0
        var finalCount = 0
        var finalCorrections = 0

        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = object["event"] as? String,
                  let segmentID = object["segmentID"] as? Int64,
                  let sourceText = object["sourceText"] as? String else {
                continue
            }

            let language = SpokenLanguage(
                rawValue: object["language"] as? String ?? ""
            ) ?? .unknown
            var stabilizer = stabilizers[segmentID] ?? CaptionTextStabilizer()

            if event == "partial_recognized" {
                partialCount += 1
                if let previous = previousRaw[segmentID] {
                    rawTransitions += 1
                    if previous != sourceText, !sourceText.hasPrefix(previous) {
                        rawRewrites += 1
                    }
                }
                previousRaw[segmentID] = sourceText

                let presentation = stabilizer.update(
                    text: sourceText,
                    segmentStartSample: segmentID,
                    language: language
                )
                let oldStable = previousStable[segmentID] ?? ""
                if !presentation.stable.hasPrefix(oldStable) {
                    partialStableRollbacks += 1
                }
                previousStable[segmentID] = presentation.stable

                let previousRequest = lastTranslationRequest[segmentID] ?? ""
                if PartialTranslationPolicy.shouldRequest(
                    previousText: previousRequest,
                    stableText: presentation.stable,
                    language: language
                ) {
                    optimizedTranslationRequests += 1
                    lastTranslationRequest[segmentID] = presentation.stable
                }
            } else if event == "final_recognized" {
                finalCount += 1
                let presentation = stabilizer.finalize(
                    text: sourceText,
                    segmentStartSample: segmentID
                )
                let oldStable = previousStable[segmentID] ?? ""
                if !presentation.stable.hasPrefix(oldStable) {
                    finalCorrections += 1
                }
            }

            stabilizers[segmentID] = stabilizer
        }

        let rewriteRate = rawTransitions == 0
            ? 0
            : Double(rawRewrites) / Double(rawTransitions) * 100
        let translationReduction = partialCount == 0
            ? 0
            : (1 - Double(optimizedTranslationRequests) / Double(partialCount)) * 100

        print("partial_snapshots=\(partialCount)")
        print(String(format: "raw_rewrite_rate=%.1f%%", rewriteRate))
        print("partial_stable_text_rollbacks=\(partialStableRollbacks)")
        print("old_partial_translation_requests=\(partialCount)")
        print("new_partial_translation_requests=\(optimizedTranslationRequests)")
        print(String(format: "partial_translation_reduction=%.1f%%", translationReduction))
        print("final_snapshots=\(finalCount)")
        print("exact_final_corrections=\(finalCorrections)")
    }
}
