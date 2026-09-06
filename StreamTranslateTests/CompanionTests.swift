import Testing
import Foundation
import AppKit
import CompanionKit
@testable import StreamTranslate

private func companionTestRow(_ text: String = "Hello", id: UUID = UUID()) -> CompanionCaption {
    .init(id: id, timestamp: Date(timeIntervalSince1970: 100), original: text, translation: "你好", language: "en")
}

@Test func companionFrameRoundTripsAcrossEverySplit() throws {
    let frame = try CompanionFrameDecoder.encode(.snapshot(.init(captions: [companionTestRow()])))
    for split in 0...frame.count {
        var decoder = CompanionFrameDecoder()
        let result = try decoder.append(Data(frame.prefix(split))) + decoder.append(Data(frame.dropFirst(split)))
        #expect(result.count == 1)
        if case .snapshot(let snapshot) = result.first { #expect(snapshot.captions.first?.translation == "你好") }
        else { Issue.record("Lost snapshot at byte split \(split)") }
    }
}

@Test func companionFrameReadsCoalescedMessages() throws {
    var decoder = CompanionFrameDecoder()
    let data = try CompanionFrameDecoder.encode(.ping(1)) + CompanionFrameDecoder.encode(.pong(1))
    #expect(try decoder.append(data).count == 2)
}

@Test func companionFrameRejectsOversizedHeaderBeforePayload() {
    var decoder = CompanionFrameDecoder()
    do { _ = try decoder.append(Data([255, 255, 255, 255])); Issue.record("Accepted oversized frame") }
    catch { #expect(error is CompanionProtocolError) }
}

@Test func companionFrameRejectsEmptyFrame() {
    var decoder = CompanionFrameDecoder()
    do { _ = try decoder.append(Data([0, 0, 0, 0])); Issue.record("Accepted empty frame") }
    catch { #expect(error is CompanionProtocolError) }
}

@Test func companionFrameRejectsMalformedJSON() {
    var decoder = CompanionFrameDecoder()
    do { _ = try decoder.append(Data([0, 0, 0, 1, 33])); Issue.record("Accepted malformed JSON") }
    catch { #expect(true) }
}

@Test func companionHistoryIsBounded() {
    let snapshot = CompanionSnapshot(captions: (0..<500).map { companionTestRow("\($0)") })
    #expect(snapshot.captions.count == CompanionLimits.maximumHistory)
    #expect(snapshot.captions.last?.original == "499")
}

@Test func companionTextIsBounded() {
    let row = companionTestRow(String(repeating: "字", count: 100_000))
    #expect(row.original.count == CompanionLimits.maximumTextCharacters)
}

@Test func companionSnapshotRejectsDuplicateIDs() {
    let row = companionTestRow()
    var replica = CompanionReplica()
    #expect(!replica.accept(.init(captions: [row, row])))
    #expect(replica.snapshot == nil)
}

@Test func companionRefinementReplacesSameRow() {
    var row = companionTestRow()
    let first = CompanionSnapshot(sequence: 10, captions: [row])
    row.translation = "你好，很高兴认识你"
    var second = first
    second.sequence = 11
    second.captions = [row]
    let delta = CompanionDelta(previous: first, current: second)
    var replica = CompanionReplica()
    #expect(replica.accept(first))
    #expect(replica.apply(delta))
    #expect(replica.snapshot?.captions.count == 1)
    #expect(replica.snapshot?.captions.first?.translation == row.translation)
}

@Test func companionDeltaOmitsUnchangedHistory() {
    let first = CompanionSnapshot(captions: [companionTestRow()])
    var second = first
    second.sequence = 1
    second.streaming = companionTestRow("Next")
    #expect(CompanionDelta(previous: first, current: second).upserts.isEmpty)
}

@Test func companionDeltaRemovesEvictedHistory() {
    let first = CompanionSnapshot(captions: [companionTestRow("one"), companionTestRow("two")])
    var second = first
    second.sequence = 1
    second.captions.removeFirst()
    var replica = CompanionReplica()
    replica.accept(first)
    #expect(replica.apply(.init(previous: first, current: second)))
    #expect(replica.snapshot?.captions.map(\.original) == ["two"])
}

@Test func companionMissingSequenceRequestsSnapshotInsteadOfMerging() {
    let first = CompanionSnapshot(sequence: 10, captions: [companionTestRow()])
    var second = first
    second.sequence = 12
    var replica = CompanionReplica()
    replica.accept(first)
    #expect(!replica.apply(.init(previous: first, current: second)))
    #expect(replica.snapshot?.sequence == 10)
}

@Test func companionOldSessionDeltaCannotOverwriteNewSession() {
    let first = CompanionSnapshot(sequence: 10)
    var second = first
    second.sequence = 11
    var replica = CompanionReplica()
    let newSession = CompanionSnapshot()
    replica.accept(newSession)
    #expect(!replica.apply(.init(previous: first, current: second)))
    #expect(replica.snapshot?.sessionID == newSession.sessionID)
}

@Test func companionSnapshotClearsStreamingAndHistory() {
    var replica = CompanionReplica()
    replica.accept(.init(captions: [companionTestRow()], streaming: companionTestRow()))
    #expect(replica.accept(.init()))
    #expect(replica.snapshot?.captions.isEmpty == true)
    #expect(replica.snapshot?.streaming == nil)
}

@Test func companionOldSnapshotDoesNotRegressSequence() {
    let first = CompanionSnapshot(sequence: 20)
    var old = first
    old.sequence = 19
    var replica = CompanionReplica()
    replica.accept(first)
    #expect(!replica.accept(old))
}

private func companionTestInvitation(now: Date = Date()) throws -> CompanionInvitation {
    .init(serviceName: "StreamTranslate-test", fingerprint: String(repeating: "a", count: 64),
          secret: try CompanionSecrets.random(), expiresAt: now.addingTimeInterval(120), serverID: UUID())
}

@Test func companionInvitationRoundTrips() throws {
    let invitation = try companionTestInvitation()
    #expect(try CompanionInvitation.parse(invitation.url()) == invitation)
}

@Test func companionInvitationRejectsExpiredAndWrongScheme() throws {
    let invitation = try companionTestInvitation()
    do {
        _ = try CompanionInvitation.parse(invitation.url(), now: invitation.expiresAt.addingTimeInterval(1))
        Issue.record("Accepted expired invitation")
    } catch { #expect(error is CompanionProtocolError) }
    do {
        _ = try CompanionInvitation.parse(invitation.url().replacingOccurrences(of: "streamtranslate:", with: "http:"))
        Issue.record("Accepted wrong URL scheme")
    } catch { #expect(error is CompanionProtocolError) }
}

@Test func companionInvitationRejectsShortSecrets() throws {
    var invitation = try companionTestInvitation()
    invitation.secret = Data([1, 2, 3]).base64EncodedString()
    do { _ = try CompanionInvitation.parse(invitation.url()); Issue.record("Accepted short secret") }
    catch { #expect(error is CompanionProtocolError) }
}

@Test func companionUnauthorizedClientGetsNoCredential() throws {
    var authorizer = CompanionAuthorizer()
    authorizer.invite(try companionTestInvitation())
    #expect(try authorizer.authorize(.init(clientID: UUID(), name: "attacker", invitation: "wrong")) == nil)
    #expect(authorizer.clients.isEmpty)
}

@Test func companionInvitationIsSingleUseAndOnlyOnePhone() throws {
    var authorizer = CompanionAuthorizer()
    let invitation = try companionTestInvitation()
    authorizer.invite(invitation)
    let request = CompanionAuthentication(clientID: UUID(), name: "phone", invitation: invitation.secret)
    #expect(try authorizer.authorize(request) != nil)
    #expect(authorizer.invitation == nil)
    #expect(try authorizer.authorize(request) == nil)
    #expect(try authorizer.authorize(.init(clientID: UUID(), name: "other", invitation: invitation.secret)) == nil)
}

@Test func companionCredentialsSurviveReconnectButNotRevocation() throws {
    var authorizer = CompanionAuthorizer()
    let invitation = try companionTestInvitation()
    authorizer.invite(invitation)
    let request = CompanionAuthentication(clientID: UUID(), name: "phone", invitation: invitation.secret)
    guard let client = try authorizer.authorize(request) else { Issue.record("Pairing failed"); return }
    let reconnect = CompanionAuthentication(clientID: client.id, name: "phone", credential: client.credential)
    #expect(try authorizer.authorize(reconnect) != nil)
    var restored = CompanionAuthorizer(clients: authorizer.clients)
    #expect(try restored.authorize(reconnect) != nil)
    restored.revokeAll()
    #expect(try restored.authorize(reconnect) == nil)
}

@Test func companionUnsupportedProtocolCannotPair() throws {
    var authorizer = CompanionAuthorizer()
    let invitation = try companionTestInvitation()
    authorizer.invite(invitation)
    var request = CompanionAuthentication(clientID: UUID(), name: "phone", invitation: invitation.secret)
    request.version = 999
    #expect(try authorizer.authorize(request) == nil)
}

@Test func companionExpiredInviteCannotAuthorizeEvenWithValidSecret() throws {
    var authorizer = CompanionAuthorizer()
    let invitation = try companionTestInvitation()
    authorizer.invite(invitation)
    #expect(try authorizer.authorize(.init(clientID: UUID(), name: "phone", invitation: invitation.secret),
                                     now: invitation.expiresAt.addingTimeInterval(1)) == nil)
}

@Test func companionSecretsHave256BitsAndDistinctValues() throws {
    let first = try CompanionSecrets.random(), second = try CompanionSecrets.random()
    #expect(Data(base64Encoded: first)?.count == 32)
    #expect(first != second)
    #expect(CompanionSecrets.equal(first, first))
    #expect(!CompanionSecrets.equal(first, second))
}

@Test func companionPrivatePolicyNeverRestoresOnDisconnect() {
    #expect(!CaptionVisibilityPolicy(phoneOnly: true).permitsCaptionWindows)
    #expect(!CaptionVisibilityPolicy(phoneOnly: true).permitsSetupWindows)
    #expect(!CaptionVisibilityPolicy(phoneOnly: true).shouldRestoreAfterDisconnect())
    #expect(CaptionVisibilityPolicy(phoneOnly: false).permitsCaptionWindows)
}

@Test @MainActor func companionPrivatePreferencePersistsWithoutEnablingNetworkByDefault() {
    let name = "StreamTranslate.companion.test.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = CaptionSettings(defaults: defaults)
    #expect(!settings.companionEnabled)
    #expect(!settings.companionPeerToPeer)
    settings.phoneOnlyDisplay = true
    #expect(CaptionSettings(defaults: defaults).phoneOnlyDisplay)
}

@Test @MainActor func companionPublisherUsesSourceDirectionAndClearChangesSession() {
    let vm = CaptionViewModel()
    vm.addCaption(english: "Hello", chinese: "你好", sourceLanguage: .chinese)
    let before = CompanionCaptionPublisher.snapshot(vm, streamingID: UUID())
    #expect(before.captions.first?.original == "你好")
    #expect(before.captions.first?.translation == "Hello")
    vm.clearHistory()
    let after = CompanionCaptionPublisher.snapshot(vm, streamingID: UUID())
    #expect(after.sessionID != before.sessionID)
    #expect(after.captions.isEmpty)
}

@Test @MainActor func companionNewCaptureDoesNotExposePreviousMeetingHistory() {
    let vm = CaptionViewModel()
    vm.addCaption(english: "Previous meeting", chinese: "上一场会议")
    let oldSession = vm.companionSessionID
    vm.beginCompanionSession()
    let fresh = CompanionCaptionPublisher.snapshot(vm, streamingID: UUID())
    #expect(fresh.sessionID != oldSession)
    #expect(fresh.captions.isEmpty)
    #expect(vm.captionHistory.count == 1)
    vm.addCaption(english: "Current meeting", chinese: "当前会议")
    let current = CompanionCaptionPublisher.snapshot(vm, streamingID: UUID())
    #expect(current.captions.count == 1)
    #expect(current.captions.first?.original == "Current meeting")
    #expect(vm.captionHistory.count == 2)
}

@Test @MainActor func companionInstalledTranslationRunsWithoutAnyWindow() async throws {
    let service = TranslationService()
    let visibleBefore = NSApp.windows.filter(\.isVisible).count
    for direction in TranslationDirection.allCases {
        guard await service.installIndependentSession(direction: direction, chineseTarget: .simplifiedChinese) else {
            print("SKIP HEADLESS TRANSLATION: language assets not already installed")
            return
        }
        try await service.prepare(direction)
    }
    let chinese = try await service.translate("The presentation will start in five minutes.", direction: .englishToChinese)
    let english = try await service.translate("请在手机上查看实时字幕。", direction: .chineseToEnglish)
    #expect(!chinese.isEmpty)
    #expect(!english.isEmpty)
    #expect(chinese != "The presentation will start in five minutes.")
    #expect(english != "请在手机上查看实时字幕。")
    #expect(NSApp.windows.filter(\.isVisible).count == visibleBefore)
    print("HEADLESS TRANSLATION: both installed directions completed without a new visible window")
}
