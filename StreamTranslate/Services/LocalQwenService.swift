import Foundation
import Darwin

enum LocalReviewError: Error {
    case unavailable, cancelled, timeout, invalidResponse
}

protocol RecognitionReviewProviding: AnyObject, Sendable {
    var isReady: Bool { get }
    func transcribe(_ samples: [Float]) async throws -> String
    func cancel()
}

/// A bounded in-memory copy of the *same* 16 kHz samples sent to SpeechAnalyzer.
/// No continuous recording is written to disk. Old audio is overwritten.
final class ReviewAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float]
    private var end: Int64 = 0

    init(capacity: Int = 640_000) { samples = .init(repeating: 0, count: max(1, capacity)) }

    func append(_ input: [Float]) {
        lock.withLock {
            for sample in input {
                samples[Int(end % Int64(samples.count))] = sample
                end += 1
            }
        }
    }

    func slice(start: Int64, end requestedEnd: Int64) -> [Float]? {
        lock.withLock {
            guard start >= max(0, end - Int64(samples.count)), requestedEnd <= end,
                  requestedEnd > start else { return nil }
            return (start..<requestedEnd).map { samples[Int($0 % Int64(samples.count))] }
        }
    }

    func contextualSlice(start: Int64, end requestedEnd: Int64) -> [Float]? {
        lock.withLock {
            let oldest = max(0, end - Int64(samples.count))
            guard start >= oldest, requestedEnd <= end, requestedEnd > start else { return nil }
            let lower = max(oldest, start - 32_000)
            let upper = min(end, requestedEnd + 8_000)
            return (lower..<upper).map { samples[Int($0 % Int64(samples.count))] }
        }
    }
}

enum RecognitionReviewPolicy {
    private static func normalizedReviewSpelling(_ raw: String, original: String, language: SpokenLanguage) -> String {
        let quotationMarks = CharacterSet(charactersIn: "\"“”「」『』")
        // A reviewer added quotation marks spanning several sentences and
        // changed who appeared to say them. Audio-only review may restore
        // punctuation, but must not introduce quote scope absent in fast ASR.
        var candidate = original.rangeOfCharacter(from: quotationMarks) == nil
            ? String(String.UnicodeScalarView(raw.unicodeScalars.filter { !quotationMarks.contains($0) })) : raw
        // Preserve a contiguous source predicate. Qwen inserted a comma inside
        // 问题出在, turning an excluded explanation into the apparent cause.
        // Move only that new comma before the predicate, never rewrite words
        // or override a comma that already existed in the original source.
        let splitPredicate = #"问题\s*[，,]\s*出在"#
        if language == .chinese, original.contains("问题出在"),
           original.range(of: splitPredicate, options: .regularExpression) == nil {
            candidate = candidate.replacingOccurrences(of: splitPredicate,
                with: "，问题出在", options: .regularExpression)
            if candidate.hasPrefix("，问题出在") { candidate.removeFirst() }
        }
        return matchingPercentageSpelling(candidate, original: original, language: language)
    }

    /// Normalize only a spelled-out integer percentage already present in the
    /// fast source. This lets alignment retain "ninety-five percent" / "百分之
    /// 九十五" as 95%, without inventing, changing or dropping a quantity.
    private static func matchingPercentageSpelling(_ candidate: String, original: String, language: SpokenLanguage) -> String {
        let source = original as NSString
        let numbers = try! NSRegularExpression(pattern: #"(?i)(?<![\d.])(\d+)\s*(?:%|percent\b)"#)
        var labels: [Int: String] = [:]
        for match in numbers.matches(in: original, range: NSRange(location: 0, length: source.length)) {
            if let value = Int(source.substring(with: match.range(at: 1))), (0...100).contains(value) {
                labels[value] = source.substring(with: match.range)
            }
        }
        guard !labels.isEmpty else { return candidate }
        let word = "(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred)"
        let pattern = language == .chinese ? #"百分之([零〇一二两三四五六七八九十百]+)"#
            : "(?i)\\b(" + word + "(?:[ -]+" + word + "){0,3})\\s+percent\\b"
        let regex = try! NSRegularExpression(pattern: pattern)
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: language == .chinese ? "zh_CN" : "en_US")
        let input = candidate as NSString
        var result = candidate
        for match in regex.matches(in: candidate, range: NSRange(location: 0, length: input.length)).reversed() {
            if let value = formatter.number(from: input.substring(with: match.range(at: 1))),
               value.doubleValue == Double(value.intValue), let label = labels[value.intValue],
               let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: label)
            }
        }
        return result
    }

    private static func lexicalRanges(_ text: String, language: SpokenLanguage) -> [Range<String.Index>] {
        if language == .chinese {
            return text.indices.filter { text[$0].isLetter || text[$0].isNumber }
                .map { $0..<text.index(after: $0) }
        }
        var result: [Range<String.Index>] = []
        var begin: String.Index?
        for index in text.indices {
            if text[index].isLetter || text[index].isNumber { if begin == nil { begin = index } }
            else if let start = begin { result.append(start..<index); begin = nil }
        }
        if let begin { result.append(begin..<text.endIndex) }
        return result
    }

    static func hasPriorDisagreement(_ prior: String, with original: String, language: SpokenLanguage) -> Bool {
        let source = lexicalRanges(original, language: language).map { original[$0].lowercased() }
        let prefix = lexicalRanges(prior, language: language).map { prior[$0].lowercased() }
        guard prefix.count >= (language == .chinese ? 8 : 4), prefix.count <= source.count else { return false }
        let differences = zip(prefix, source).filter { $0 != $1 }.count
        return differences > 0 && Double(differences) / Double(prefix.count) <= 0.25
    }

    /// Context helps some homophones but can also turn a correct "cache" into
    /// "cash". Only edits supported by both audio views may replace fast ASR.
    /// These are two views of one model, not independent statistical evidence.
    static func consensus(primary: String, contextual: String, original: String, language: SpokenLanguage,
                          priorHypothesis: String = "") -> String? {
        // The primary pass contains only this utterance. Semi-global clipping
        // here can discard a real tail when digits become spelled-out numbers.
        let first = normalizedReviewSpelling(primary, original: original, language: language)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard accepts(first, replacing: original, language: language),
              let second = candidate(contextual, for: original, language: language) else { return nil }
        func units(_ text: String) -> [String] {
            lexicalRanges(text, language: language).map { text[$0].lowercased() }
        }
        let source = units(original), a = units(first), b = units(second)
        if a == b { return first }
        // When the full views disagree, retain only matching one-word repairs.
        // Do not splice deletions/insertions from contradictory hypotheses.
        func substitutions(_ text: String, _ words: [String]) -> [Int: String] {
            let ranges = lexicalRanges(text, language: language)
            var cost = Array(repeating: Array(repeating: 0, count: words.count + 1), count: source.count + 1)
            for i in 0...source.count { cost[i][0] = i }
            for j in 0...words.count { cost[0][j] = j }
            for i in 1...source.count {
                for j in 1...words.count {
                    cost[i][j] = min(cost[i - 1][j] + 1, cost[i][j - 1] + 1,
                                     cost[i - 1][j - 1] + (source[i - 1] == words[j - 1] ? 0 : 1))
                }
            }
            var replacements: [Int: String] = [:], blocked: Set<Int> = []
            var i = source.count, j = words.count
            while i > 0 || j > 0 {
                if i > 0, j > 0,
                   cost[i][j] == cost[i - 1][j - 1] + (source[i - 1] == words[j - 1] ? 0 : 1) {
                    if source[i - 1] != words[j - 1] { replacements[i - 1] = String(text[ranges[j - 1]]) }
                    i -= 1; j -= 1
                } else if i > 0, j == 0 || cost[i][j] == cost[i - 1][j] + 1 {
                    blocked.formUnion([i - 2, i - 1, i]); i -= 1
                } else {
                    blocked.formUnion([i - 1, i]); j -= 1
                }
            }
            return replacements.filter { !blocked.contains($0.key) }
        }
        let editsA = substitutions(first, a), editsB = substitutions(second, b)
        let ranges = lexicalRanges(original, language: language)
        let prior = units(priorHypothesis)
        let usePrior = hasPriorDisagreement(priorHypothesis, with: original, language: language)
        let critical: Set<String> = ["not", "no", "never", "without", "unless", "until", "i", "we", "you", "he", "she", "it", "they",
            "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "fifteen", "fifty", "hundred", "thousand",
            "不", "没", "无", "我", "你", "他", "她", "它", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万"]
        var result = original
        for index in Set(editsA.keys).union(editsB.keys).sorted(by: >) {
            let replacement: String
            if let a = editsA[index], a.lowercased() == editsB[index]?.lowercased() {
                replacement = a
            } else if usePrior, index < prior.count,
                      !critical.contains(source[index]), !critical.contains(prior[index]),
                      !source[index].contains(where: { $0.isNumber }), !prior[index].contains(where: { $0.isNumber }),
                      let supported = [editsA[index], editsB[index]].compactMap({ $0 }).first(where: { $0.lowercased() == prior[index] }) {
                // The preceding Apple hypothesis is another recognition family,
                // not another decode of the same Qwen model. Restrict this
                // fallback to ordinary words, never numbers/negation/pronouns.
                replacement = supported
            } else { continue }
            // Never partially rewrite an apostrophe-delimited contraction.
            let range = ranges[index]
            if range.lowerBound > original.startIndex,
               "'’".contains(original[original.index(before: range.lowerBound)]) { continue }
            if range.upperBound < original.endIndex, "'’".contains(original[range.upperBound]) { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result == original || !accepts(result, replacing: original, language: language) ? nil : result
    }

    /// Align only the current utterance within a context-enriched hypothesis.
    /// Semi-global edit alignment strips neighboring words on either side;
    /// those words belong to other captions and must not be duplicated here.
    static func candidate(_ rawHypothesis: String, for original: String, language: SpokenLanguage) -> String? {
        let hypothesis = normalizedReviewSpelling(rawHypothesis, original: original, language: language)
        let originalRanges = lexicalRanges(original, language: language)
        let candidateRanges = lexicalRanges(hypothesis, language: language)
        let lhs = originalRanges.map { original[$0].lowercased() }
        let rhs = candidateRanges.map { hypothesis[$0].lowercased() }
        guard lhs.count >= 3, lhs.count <= 512, !rhs.isEmpty, rhs.count <= 640 else { return nil }
        var costs = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for i in 1...lhs.count {
            costs[i][0] = i
            for j in 1...rhs.count {
                costs[i][j] = min(costs[i - 1][j] + 1, costs[i][j - 1] + 1,
                                  costs[i - 1][j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1))
            }
        }
        // Prefer the earliest equally good end: a repeated phrase in following
        // audio must not pull this caption into the next utterance.
        let bestEnd = (1...rhs.count).min { costs[lhs.count][$0] < costs[lhs.count][$1] }!
        var i = lhs.count, j = bestEnd
        while i > 0, j > 0 {
            if costs[i][j] == costs[i - 1][j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1) { i -= 1; j -= 1 }
            else if costs[i][j] == costs[i - 1][j] + 1 { i -= 1 }
            else { j -= 1 }
        }
        guard j < bestEnd else { return nil }
        var end = candidateRanges[bestEnd - 1].upperBound
        while end < hypothesis.endIndex, !hypothesis[end].isLetter, !hypothesis[end].isNumber {
            end = hypothesis.index(after: end)
        }
        let clipped = String(hypothesis[candidateRanges[j].lowerBound..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return accepts(clipped, replacing: original, language: language) ? clipped : nil
    }

    static func accepts(_ rawCandidate: String, replacing original: String, language: SpokenLanguage) -> Bool {
        let candidate = normalizedReviewSpelling(rawCandidate, original: original, language: language)
        guard !TranscriptionTextPolicy.isNonSpeechOnly(candidate),
              !TranscriptionTextPolicy.isDegenerateRepetition(candidate),
              candidate.count <= 1600 else { return false }
        func units(_ value: String) -> [String] {
            if language == .chinese {
                return value.lowercased().filter { $0.isLetter || $0.isNumber }.map(String.init)
            }
            return value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let lhs = units(original), rhs = units(candidate)
        guard lhs.count >= 3, !rhs.isEmpty, rhs.count <= lhs.count * 2,
              Double(rhs.count) >= Double(lhs.count) * 0.9 else { return false }
        // Conservative same-language guard: formatting changes (95 -> ninety
        // five) may skip a review, but never remove or alter a known quantity
        // or negation just because two views of one model agree.
        let critical: Set<String> = language == .chinese
            ? ["不", "没", "无", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "亿"]
            : ["not", "no", "never", "without", "unless", "until", "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion", "half", "third", "quarter"]
        func markers(_ text: String, words: [String]) -> [String] {
            var result = words.filter { critical.contains($0) || $0.contains(where: { $0.isNumber }) }
            if language == .english {
                let regex = try! NSRegularExpression(pattern: #"(?i)\b\w+n['’]t\b|\bcannot\b"#)
                let count = regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
                result += Array(repeating: "not", count: count)
            }
            return result
        }
        guard markers(original, words: lhs) == markers(candidate, words: rhs) else { return false }
        let unfinished: Set<String> = language == .chinese
            ? ["从", "到", "的", "把", "将", "比", "和", "或"]
            : ["from", "to", "by", "with", "of", "and", "or", "than", "the", "a", "an"]
        if let tail = rhs.last, unfinished.contains(tail), lhs.last != tail { return false }
        var previous = Array(0...rhs.count)
        for (i, a) in lhs.enumerated() {
            var row = [i + 1]
            for (j, b) in rhs.enumerated() {
                row.append(min(row[j] + 1, previous[j + 1] + 1, previous[j] + (a == b ? 0 : 1)))
            }
            previous = row
        }
        // A verifier may repair words/punctuation, not replace the whole utterance.
        return Double(previous.last!) / Double(max(lhs.count, rhs.count)) <= 0.45
    }
}

/// Isolated native Metal worker. Serialized requests, deadlines and killable
/// process boundaries keep a runtime failure from blocking the caption UI.
final class LocalQwenService: RecognitionReviewProviding, @unchecked Sendable {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StreamTranslate/Qwen")
    static var assets: LocalModelAssets? { .resolve(name: "Qwen", executableName: "QwenHelper") }
    static var isInstalled: Bool { assets != nil }

    private let queue = DispatchQueue(label: "StreamTranslate.qwen-review", qos: .userInitiated)
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var ready = false
    private var input: FileHandle?
    private var output: FileHandle?
    private var pendingBytes = Data()
    private let modelURL: URL
    private let executableURL: URL

    init(modelURL: URL? = nil) {
        let assets = Self.assets
        self.modelURL = modelURL ?? assets?.model ?? Self.root.appendingPathComponent("model.gguf")
        self.executableURL = assets?.executable ?? Self.root.appendingPathComponent("runtime/QwenHelper")
    }

    var isReady: Bool { lock.withLock { ready && !cancelled } }

    func prepare() async throws {
        try await perform {
            guard self.modelURL.isFileURL,
                  FileManager.default.isReadableFile(atPath: self.modelURL.path),
                  FileManager.default.isExecutableFile(atPath: self.executableURL.path) else {
                throw LocalReviewError.unavailable
            }
            let child = Process(), stdin = Pipe(), stdout = Pipe()
            child.executableURL = self.executableURL
            child.arguments = [self.modelURL.path]
            child.standardInput = stdin
            child.standardOutput = stdout
            child.standardError = FileHandle.nullDevice
            try self.lock.withLock {
                guard !self.cancelled else { throw LocalReviewError.cancelled }
                try child.run()
                self.process = child
            }
            self.input = stdin.fileHandleForWriting
            self.output = stdout.fileHandleForReading
            let line = try self.readLine(timeout: 45)
            guard line.hasPrefix("READY\t") else { throw LocalReviewError.invalidResponse }
            self.lock.withLock { self.ready = !self.cancelled }
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await perform {
            guard self.isReady, samples.count >= 8000, samples.count <= 384_000 else {
                throw LocalReviewError.unavailable
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("streamtranslate-review-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let wav = folder.appendingPathComponent("audio.wav")
            try Self.wavData(samples).write(to: wav, options: .atomic)
            let id = UUID().uuidString
            try self.input?.write(contentsOf: Data("\(id)\t\(wav.path)\n".utf8))
            let fields = try self.readLine(timeout: 4).split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, fields[0] == id, fields[1] == "OK" else {
                throw LocalReviewError.invalidResponse
            }
            return String(fields[3]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            ready = false
            if let process, process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    deinit { if let process, process.isRunning { process.terminate() } }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { self.cancel(); continuation.resume(throwing: error) }
            }
        }
    }

    private func readLine(timeout: TimeInterval) throws -> String {
        guard let output else { throw LocalReviewError.unavailable }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if lock.withLock({ cancelled }) { throw LocalReviewError.cancelled }
            if let newline = pendingBytes.firstIndex(of: 10) {
                let line = String(decoding: pendingBytes[..<newline], as: UTF8.self)
                pendingBytes.removeSubrange(...newline)
                return line
            }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0 { if errno == EINTR { continue }; throw LocalReviewError.invalidResponse }
            if result > 0 {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                guard count > 0 else { throw LocalReviewError.invalidResponse }
                pendingBytes.append(contentsOf: bytes.prefix(count))
                guard pendingBytes.count <= 16_384 else { throw LocalReviewError.invalidResponse }
            }
        }
        throw LocalReviewError.timeout
    }

    static func wavData(_ samples: [Float]) -> Data {
        var result = Data()
        func ascii(_ value: String) { result.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(samples.count * 2 + 36)); ascii("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        ascii("data"); u32(UInt32(samples.count * 2))
        for sample in samples {
            let value = sample.isFinite ? min(1, max(-1, sample)) : 0
            u16(UInt16(bitPattern: Int16((value * 32767).rounded())))
        }
        return result
    }
}
