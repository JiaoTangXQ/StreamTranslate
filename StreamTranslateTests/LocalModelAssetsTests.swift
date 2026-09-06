import Foundation
import Testing
@testable import StreamTranslate

private func withAssetFixture(_ body: (URL, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root.appendingPathComponent("Moved App.app"), root.appendingPathComponent("New User"))
}

private func makeAsset(_ url: URL, executable: Bool = false, empty: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((empty ? "" : "fixture").utf8).write(to: url)
    if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
}

@Test func bundledModelsWorkWithoutUserInstallation() throws {
    try withAssetFixture { app, support in
        try makeAsset(app.appendingPathComponent("Contents/Helpers/Qwen/QwenHelper"), executable: true)
        let model = app.appendingPathComponent("Contents/Resources/Models/Qwen.gguf")
        try makeAsset(model)
        #expect(LocalModelAssets.resolve(name: "Qwen", executableName: "QwenHelper", bundleURL: app, supportURL: support)?.model == model)
    }
}

@Test func bundledPairWinsOverExternalDevelopmentModel() throws {
    try withAssetFixture { app, support in
        for (helper, model) in [
            (app.appendingPathComponent("Contents/Helpers/HyMT/llama-server"), app.appendingPathComponent("Contents/Resources/Models/HyMT.gguf")),
            (support.appendingPathComponent("HyMT/runtime/llama-server"), support.appendingPathComponent("HyMT/model.gguf"))
        ] { try makeAsset(helper, executable: true); try makeAsset(model) }
        let pair = LocalModelAssets.resolve(name: "HyMT", executableName: "llama-server", bundleURL: app, supportURL: support)
        #expect(pair?.executable.path.hasPrefix(app.path) == true)
        #expect(pair?.model.path.hasPrefix(app.path) == true)
    }
}

@Test func incompleteBundleFallsBackToCompleteLocalPair() throws {
    try withAssetFixture { app, support in
        try makeAsset(app.appendingPathComponent("Contents/Helpers/Qwen/QwenHelper"), executable: true)
        try makeAsset(support.appendingPathComponent("Qwen/runtime/QwenHelper"), executable: true)
        let model = support.appendingPathComponent("Qwen/model.gguf")
        try makeAsset(model)
        let pair = LocalModelAssets.resolve(name: "Qwen", executableName: "QwenHelper", bundleURL: app, supportURL: support)
        #expect(pair?.model == model)
        #expect(pair?.executable.path.hasPrefix(support.path) == true)
    }
}

@Test func missingOrEmptyModelsDoNotEnableEnhancement() throws {
    try withAssetFixture { app, support in
        let helper = app.appendingPathComponent("Contents/Helpers/Qwen/QwenHelper")
        try makeAsset(helper, executable: true)
        #expect(LocalModelAssets.resolve(name: "Qwen", executableName: "QwenHelper", bundleURL: app, supportURL: support) == nil)
        try makeAsset(app.appendingPathComponent("Contents/Resources/Models/Qwen.gguf"), empty: true)
        #expect(LocalModelAssets.resolve(name: "Qwen", executableName: "QwenHelper", bundleURL: app, supportURL: support) == nil)
    }
}

@Test func externalModelSymlinksRemainSupported() throws {
    try withAssetFixture { app, support in
        try makeAsset(support.appendingPathComponent("Qwen/runtime/QwenHelper"), executable: true)
        let external = support.appendingPathComponent("external.gguf")
        try makeAsset(external)
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("Qwen/model.gguf"), withDestinationURL: external)
        #expect(LocalModelAssets.resolve(name: "Qwen", executableName: "QwenHelper", bundleURL: app, supportURL: support) != nil)
        try FileManager.default.removeItem(at: external)
        #expect(LocalModelAssets.resolve(name: "Qwen", executableName: "QwenHelper", bundleURL: app, supportURL: support) == nil)
    }
}
