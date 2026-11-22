import Foundation
import CryptoKit
import Testing
import CompanionKit
@testable import StreamTranslate

private let vectorRoom = String(repeating: "a", count: 64)
private let vectorStream = String(repeating: "b", count: 32)
private let vectorKey = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))

@Test func phoneAudioOpensTheExactBytesTheBrowserSeals() throws {
    // Produced by Relay/audio.test.mjs with the browser's WebCrypto steps.
    let sealed = "CQkJCQkJCQkJCQkJDrTDiI0c9YNgb4tvfdtFKsiRG2B+C7GsH+y8lKEMrops4Z5v"
    let batch = try PhoneAudioBatch.open(sealed: sealed, stream: vectorStream, sequence: 7, room: vectorRoom, key: vectorKey)
    #expect(batch.firstFrame == 258)
    #expect(batch.isEnd)
    #expect(batch.samples == [0, 1000, -1000, 32767, -32768])
    // The sequence and stream are authenticated, not just transported.
    #expect(throws: (any Error).self) {
        try PhoneAudioBatch.open(sealed: sealed, stream: vectorStream, sequence: 8, room: vectorRoom, key: vectorKey)
    }
    #expect(throws: (any Error).self) {
        try PhoneAudioBatch.open(sealed: sealed, stream: String(repeating: "c", count: 32), sequence: 7, room: vectorRoom, key: vectorKey)
    }
    #expect(throws: (any Error).self) {
        try PhoneAudioBatch.open(sealed: sealed, stream: vectorStream, sequence: 7, room: vectorRoom, key: SymmetricKey(size: .bits256))
    }
}

@Test func phoneAudioRoundTripsAndRejectsTampering() throws {
    let batch = PhoneAudioBatch(stream: vectorStream, sequence: 3, firstFrame: 12, isEnd: false,
                                samples: (0..<1_600).map { Int16($0 % 200 - 100) })
    let sealed = try batch.seal(room: vectorRoom, key: vectorKey)
    #expect(try PhoneAudioBatch.open(sealed: sealed, stream: vectorStream, sequence: 3, room: vectorRoom, key: vectorKey) == batch)
    var bytes = [UInt8](Data(base64Encoded: sealed)!)
    bytes[20] ^= 1
    #expect(throws: (any Error).self) {
        try PhoneAudioBatch.open(sealed: Data(bytes).base64EncodedString(), stream: vectorStream, sequence: 3,
                                 room: vectorRoom, key: vectorKey)
    }
    #expect(!PhoneAudioBatch.isValidStream("XYZ"))
}

private func frames(_ count: Int, value: Int16) -> [Int16] {
    [Int16](repeating: value, count: count * PhoneAudioBatch.frameSamples)
}

@Test func phoneAudioCaptureFillsLostFramesWithSilenceAndDropsRepeats() async {
    let service = PhoneAudioCaptureService(stream: vectorStream)
    let stream = service.makeAudioStream()
    let first = service.append(PhoneAudioBatch(stream: vectorStream, sequence: 1, firstFrame: 0, isEnd: false, samples: frames(2, value: 1000)))
    #expect(first.count == 2)
    // A retried upload of frames already delivered adds nothing.
    #expect(service.append(PhoneAudioBatch(stream: vectorStream, sequence: 2, firstFrame: 0, isEnd: false, samples: frames(2, value: 1000))).isEmpty)
    // Frames 2–4 were lost: three silent frames keep the timeline aligned.
    let gap = service.append(PhoneAudioBatch(stream: vectorStream, sequence: 3, firstFrame: 5, isEnd: false, samples: frames(1, value: 2000)))
    #expect(gap.count == 4)
    #expect(gap.prefix(3).allSatisfy { $0.samples.allSatisfy { $0 == 0 } && $0.samples.count == 1_600 })
    #expect(abs(gap[3].samples[0] - 2000 / 32_768) < 0.0001)
    // A long outage is capped instead of replayed as minutes of silence.
    let outage = service.append(PhoneAudioBatch(stream: vectorStream, sequence: 4, firstFrame: 1_000, isEnd: false, samples: frames(1, value: 5)))
    #expect(outage.count == Int(PhoneAudioCaptureService.maximumGapFrames) + 1)
    // Another phone stream cannot inject audio into this capture.
    #expect(service.append(PhoneAudioBatch(stream: String(repeating: "c", count: 32), sequence: 1, firstFrame: 1_001, isEnd: false, samples: frames(1, value: 7))).isEmpty)
    service.append(PhoneAudioBatch(stream: vectorStream, sequence: 5, firstFrame: 1_001, isEnd: true, samples: []))
    var received = 0
    for await _ in stream { received += 1 }
    #expect(received == 2 + 4 + outage.count)
}

@Test func phoneAudioArrivingBeforeRecognitionStartsIsKept() async {
    // The coordinator appends the first upload, then recognition asks for
    // the stream once it is ready.
    let service = PhoneAudioCaptureService(stream: vectorStream)
    service.append(PhoneAudioBatch(stream: vectorStream, sequence: 1, firstFrame: 0, isEnd: false, samples: frames(10, value: 300)))
    let stream = service.makeAudioStream()
    service.append(PhoneAudioBatch(stream: vectorStream, sequence: 2, firstFrame: 10, isEnd: true, samples: frames(1, value: 300)))
    var received: [Int64] = []
    for await chunk in stream { received.append(chunk.sequence) }
    #expect(received == Array(0..<11))
}

@Test func remoteDevicesAreSavedOnlyWhenTheRelayReportsAChange() {
    let now = 1_000_000.0, day = 86_400_000.0
    let one = RemoteRelayDevice(hash: String(repeating: "1", count: 64), expires: now + 90 * day)
    let two = RemoteRelayDevice(hash: String(repeating: "2", count: 64), expires: now + 90 * day)
    #expect(RemoteRelayDevice.reconciled(saved: [], reported: [one], now: now) == [one])
    #expect(RemoteRelayDevice.reconciled(saved: [one], reported: [one], now: now) == nil)
    // Heartbeat renewal by minutes is not rewritten; by days it is.
    #expect(RemoteRelayDevice.reconciled(saved: [one], reported: [.init(hash: one.hash, expires: one.expires + 60_000)], now: now) == nil)
    #expect(RemoteRelayDevice.reconciled(saved: [one], reported: [.init(hash: one.hash, expires: one.expires + 2 * day)], now: now)?.first?.expires == one.expires + 2 * day)
    // The relay dropped a browser: it is removed, not resurrected.
    #expect(RemoteRelayDevice.reconciled(saved: [one, two], reported: [two], now: now) == [two])
    // Expired or malformed entries never persist.
    #expect(RemoteRelayDevice.reconciled(saved: [one], reported: [one, .init(hash: "bad", expires: now + day),
        .init(hash: String(repeating: "3", count: 64), expires: now - 1)], now: now) == nil)
}

@Test func phoneSnapshotsCarryTheMindMapOnlyWhenItChanges() throws {
    let map = CompanionMindMap(revision: 1, topics: [.init(title: "发布计划", summary: "推迟到月底", advertisement: false,
        branches: [.init(title: "原因", points: ["性能问题"])])])
    let id = UUID()
    let first = CompanionSnapshot(sessionID: id, sequence: 1, status: .listening, mindMap: map, phoneMicrophone: .listening)
    var replica = CompanionReplica()
    #expect(replica.accept(first))
    let second = CompanionSnapshot(sessionID: id, sequence: 2, status: .listening, mindMap: map, phoneMicrophone: .listening)
    let unchanged = CompanionDelta(previous: first, current: second)
    #expect(unchanged.mindMap == nil)
    #expect(replica.apply(unchanged))
    #expect(replica.snapshot?.mindMap == map)
    var updated = map; updated.revision = 2; updated.topics[0].summary = "改到下月初"
    let third = CompanionSnapshot(sessionID: id, sequence: 3, status: .stopped, mindMap: updated,
                                  phoneMicrophone: .refused, notice: "电脑正在用自己的音源收音")
    let changed = CompanionDelta(previous: second, current: third)
    #expect(changed.mindMap == updated)
    #expect(replica.apply(changed))
    #expect(replica.snapshot?.mindMap?.topics.first?.summary == "改到下月初")
    #expect(replica.snapshot?.phoneMicrophone == .refused)
    #expect(replica.snapshot?.notice == "电脑正在用自己的音源收音")
    // Older readers' payloads (no new fields) still decode.
    let old = #"{"sessionID":"\#(id.uuidString)","sequence":1,"captions":[],"status":"ready"}"#
    let decoded = try JSONDecoder().decode(CompanionSnapshot.self, from: Data(old.utf8))
    #expect(decoded.mindMap == nil && decoded.phoneMicrophone == nil)
}

@Test @MainActor func phoneMicrophoneIsNeverPersistedAsTheMacSource() {
    let suite = "PhoneSource-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(AudioInputSource.phoneMicrophone.rawValue, forKey: "audioInputSource")
    #expect(CaptionSettings(defaults: defaults).audioInputSource == .microphone)
    #expect(CaptionSettings(defaults: defaults).phoneMicrophoneEnabled)
}

@Test @MainActor func publishedMindMapMatchesTheMacMap() throws {
    let map = try ConversationMindMap().applying(
        #"{"topics":[{"id":"","kind":"advertisement","title":"赞助","summary":"","branches":[{"title":"优惠","points":[{"text":"九折","detail":""}]}]},{"id":"","kind":"discussion","title":"发布计划","summary":"推迟到月底","branches":[{"title":"原因","points":[{"text":"性能问题","detail":"长时间运行会卡顿"}]}]}],"remove":[]}"#,
        limits: MindMapLimits.forSession(minutes: 5, local: false)).map
    let phone = CompanionCaptionPublisher.companionMap(map, revision: 4)
    #expect(phone.revision == 4)
    #expect(phone.topics.map(\.title) == ["赞助", "发布计划"])
    #expect(phone.topics.map(\.advertisement) == [true, false])
    #expect(phone.topics[1].branches.first?.points == ["性能问题"])
    #expect(phone.isValid)
}
