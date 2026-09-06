@preconcurrency import AVFoundation
import Foundation
import WhisperKit
import Darwin

/// Load once, then compare whole-utterance recognition on exactly the corpus
/// audio. Does not claim these timings are live first-caption latency.
@main enum WhisperCorpusBench {
    struct Item: Decodable { let id: String; let language: String; let reference: String; let audio: String }
    static func emit(_ fields: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: WhisperCorpusBench <manifest> <model-folder> [vocabulary]"); exit(2) }
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let started = Date()
        let kit = try await WhisperKit(modelFolder: args[2], verbose: false, prewarm: true, load: true, download: false)
        emit(["event":"loaded", "seconds":Date().timeIntervalSince(started), "model":args[2]])
        for item in items {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: item.audio))
            guard file.processingFormat.sampleRate == 16000,
                  let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)) else { exit(3) }
            try file.read(into:buffer)
            let audio = Array(UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength)))
            var options = WhisperTranscriptionService.decodingOptions
            options.language = item.language; options.detectLanguage = false
            if args.count > 3, let tokenizer = kit.tokenizer {
                options.promptTokens = tokenizer.encode(text: " " + args[3]).filter { $0 < tokenizer.specialTokens.specialTokenBegin }.suffix(128).map { $0 }
            }
            let start = Date()
            let result = try await kit.transcribe(audioArray:audio,decodeOptions:options)
            var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
            emit(["event":"result", "id":item.id, "reference":item.reference,
                  "text":result.map(\.text).joined(separator:" ").trimmingCharacters(in:.whitespacesAndNewlines),
                  "seconds":Date().timeIntervalSince(start), "audio_seconds":Double(audio.count)/16000,
                  "process_peak_rss":usage.ru_maxrss])
        }
    }
}
