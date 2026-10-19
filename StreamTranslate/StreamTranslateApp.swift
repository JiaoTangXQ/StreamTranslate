import SwiftUI
import Translation
import CompanionKit
import SystemConfiguration

@main
struct StreamTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            appDelegate.settingsContent
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { appDelegate.openSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(appDelegate.isPhoneOnly)
            }
        }
    }
}

@MainActor
final class AppWindowSlot: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?

    func show(makeWindow: () -> NSWindow) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let newWindow = makeWindow()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
        window = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let historyStore = CaptionHistoryStore()
    private lazy var viewModel = CaptionViewModel(historyStore: historyStore)
    /// Use the same state for the standard macOS Settings command (⌘,) and
    /// the menu-bar settings window; the scene must not be an empty placeholder.
    var settingsContent: some View {
        Group {
            if !settings.phoneOnlyDisplay {
                SettingsView().environment(viewModel).environment(settings)
            }
        }
    }
    var isPhoneOnly: Bool { settings.phoneOnlyDisplay }
    private var settings = CaptionSettings()
    private var floatingPanel: FloatingPanel?
    private var hotkeyManager: HotkeyManager?
    private var popover = NSPopover()
    private var translationWindow: NSWindow?
    private let companionWindowSlot = AppWindowSlot()
    private let companionServer = CompanionServer()
    private let webCompanionServer = WebCaptionServer()
    private let remoteCompanion = RemoteCaptionRelay()
    private let companionPublisher = CompanionCaptionPublisher()
    private var translationPreparationTask: Task<Void, Never>?
    private var translationPreparationID = UUID()
    private let settingsWindowSlot = AppWindowSlot()
    private let transcriptWindowSlot = AppWindowSlot()
    private var downloadProgressWindow: NSWindow?
    private var notificationObserver: Any?
    private var windowFixturePreferenceSuite: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prepare the public phone certificate without starting a second
        // audio/model instance or interrupting the currently installed app.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--window-interaction-fixture") {
            runWindowInteractionFixture()
            return
        }
        if arguments.count == 3, arguments[1] == "--reader-controls-preview" {
            Task { await ReaderControlsPreview.run(directory: URL(fileURLWithPath: arguments[2], isDirectory: true)) }
            return
        }
        if arguments.count == 3, arguments[1] == "--settings-preview" {
            Task { await SettingsPreview.run(directory: URL(fileURLWithPath: arguments[2], isDirectory: true)) }
            return
        }
        if arguments.count == 3, arguments[1] == "--export-web-profile" {
            do {
                let host = ((SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "").lowercased() + ".local"
                let identity = try WebIdentity(hostname: host, vault: CompanionVault())
                let destination = URL(fileURLWithPath: arguments[2])
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw WebError("拒绝覆盖已有描述文件。") }
                try identity.profile().write(to: destination, options: .atomic)
                print("WEB PROFILE EXPORTED: \(destination.path)")
                print("HTTPS ADDRESS: https://\(host):18443/")
                print("PUBLIC CERTIFICATE SHA256: \(identity.fingerprint)")
                exit(0)
            } catch { print("WEB PROFILE ERROR: \(error.localizedDescription)"); exit(1) }
        }
        if ProcessInfo.processInfo.arguments.contains("--companion-privacy-check") {
            runCompanionPrivacyCheck()
            return
        }
        AppLogger.clear()
        AppLogger.log("App launched. Log file: \(AppLogger.path)")

        setupStatusItem()
        setupFloatingPanel()
        setupHotkey()
        setupRemoteControl()
        updateFloatingPanelContent()
        prepareIndependentTranslation()
        observePanelSize()
        observeTranslationTarget()
        observeDownloadProgress()
        observeCompanionSettings()
        updateCompanionConfiguration()

        viewModel.preloadModel(modelId: settings.selectedModelId)
        if ProcessInfo.processInfo.arguments.contains("--open-phone-settings") {
            openCompanionWindow()
        }
        if arguments.contains("--open-settings") { openSettingsWindow() }
    }

    /// Listen for distributed notification to toggle recording (for testing/automation)
    private func runWindowInteractionFixture() {
        viewModel = CaptionViewModel()
        let suite = "StreamTranslate.window-interaction.\(UUID())"
        windowFixturePreferenceSuite = suite
        let defaults = UserDefaults(suiteName: suite)!
        settings = CaptionSettings(defaults: defaults)
        settings.panelWidth = 620; settings.panelHeight = 300
        viewModel.isRecording = true // Synthetic UI state, no capture/model tasks.
        viewModel.isModelReady = true; viewModel.isTranslationReady = true
        viewModel.streamingEnglish = "Window interaction test — synthetic captions only."
        viewModel.streamingChinese = "窗口交互测试，不录音、不分享字幕。"
        setupFloatingPanel()
        updateFloatingPanelContent()
        observePanelSize()
        openCompanionWindow()
        print("WINDOW_FIXTURE_READY pid=\(ProcessInfo.processInfo.processIdentifier)")
        fflush(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(180))
            defaults.removePersistentDomain(forName: suite)
            NSApp.terminate(nil)
        }
    }

    private func setupRemoteControl() {
        // File-based remote control: `touch /tmp/tc-toggle` to toggle recording
        AppLogger.log("Setting up remote control")
        let vm = viewModel
        let currentSettings = settings
        Task {
            let togglePath = "/tmp/tc-toggle"
            try? FileManager.default.removeItem(atPath: togglePath)
            AppLogger.log("Remote control loop started, watching \(togglePath)")
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if FileManager.default.fileExists(atPath: togglePath) {
                    try? FileManager.default.removeItem(atPath: togglePath)
                    AppLogger.log("Received file toggle trigger")
                    await MainActor.run {
                        vm.toggleCapture(
                            source: currentSettings.audioInputSource,
                            sensitivity: currentSettings.speechDetectionSensitivity,
                            recognitionMode: currentSettings.recognitionLanguageMode,
                            recognitionVocabulary: currentSettings.recognitionVocabulary,
                            captureDiagnosticsEnabled: currentSettings.captureDiagnosticsEnabled
                        )
                    }
                }
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "StreamTranslate")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let menuBarView = MenuBarView(
            onToggleCapture: { [weak self] in
                guard let self else { return }
                self.viewModel.toggleCapture(
                    source: self.settings.audioInputSource,
                    sensitivity: self.settings.speechDetectionSensitivity,
                    recognitionMode: self.settings.recognitionLanguageMode,
                    recognitionVocabulary: self.settings.recognitionVocabulary,
                    captureDiagnosticsEnabled: self.settings.captureDiagnosticsEnabled
                )
            },
            onOpenTranscript: { [weak self] in self?.openTranscriptWindow() },
            onOpenSettings: { [weak self] in self?.openSettingsWindow() },
            onOpenPhone: { [weak self] in self?.openCompanionWindow() },
            onTogglePhoneOnly: { [weak self] in
                guard let self else { return }
                self.settings.phoneOnlyDisplay.toggle()
                self.applyVisibilityPolicy()
            },
            onQuit: { [weak self] in
                self?.viewModel.stopCapture(gracefully: false)
                NSApp.terminate(nil)
            }
        )
        .environment(viewModel)
        .environment(settings)

        popover.contentSize = NSSize(width: 240, height: 250)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: menuBarView)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: viewModel.isRecording ? "captions.bubble.fill" : "captions.bubble",
                accessibilityDescription: "StreamTranslate"
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func setupFloatingPanel() {
        let width = settings.panelWidth
        let height = max(FloatingPanel.minimumCaptionHeight, settings.panelHeight)
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height)
        )
        panel.onResize = { [weak self] size in
            guard let self else { return }
            if abs(self.settings.panelWidth - size.width) > 0.5 {
                self.settings.panelWidth = size.width
            }
            let summaryExpanded = self.viewModel.conversationSummary.isExpanded
            if (!summaryExpanded || size.height > FloatingPanel.minimumSummaryHeight + 0.5 || self.settings.panelHeight >= FloatingPanel.minimumSummaryHeight),
               abs(self.settings.panelHeight - size.height) > 0.5 {
                self.settings.panelHeight = size.height
            }
        }
        panel.onRestore = { [weak self] in
            self?.floatingPanelDidRestore()
        }
        panel.onMinimize = { [weak self] in self?.viewModel.conversationSummary.collapse() }

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - width / 2
            let y = screenFrame.minY + 60
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        if !settings.phoneOnlyDisplay { panel.orderFront(nil) }
        floatingPanel = panel
    }

    private func updateFloatingPanelContent() {
        let content = FloatingCaptionView(
            onMinimize: { [weak self] in self?.minimizeFloatingPanel() },
            onSettings: { [weak self] in self?.openSettingsWindow() },
            onPhone: { [weak self] in self?.openCompanionWindow() },
            onHistory: { [weak self] in self?.openTranscriptWindow() },
            onSummaryExpansion: { [weak self] expanded in self?.updateSummaryPanelPresentation(expanded) })
            .environment(viewModel)
            .environment(settings)
        floatingPanel?.contentView = FloatingPanelHostingView(rootView: content)
    }

    private func prepareIndependentTranslation() {
        translationPreparationTask?.cancel()
        let generation = UUID()
        translationPreparationID = generation
        let target = settings.translationTarget
        translationPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for direction in TranslationDirection.allCases {
                self.viewModel.translationPreparationStarted(direction)
            }
            for direction in TranslationDirection.allCases {
                guard !Task.isCancelled, self.translationPreparationID == generation else { return }
                let installed = await self.viewModel.translationService.installIndependentSession(
                    direction: direction, chineseTarget: target)
                guard !Task.isCancelled, self.translationPreparationID == generation else { return }
                guard installed else {
                    self.viewModel.translationPreparationFailed(direction,
                        message: "请先退出仅手机模式并完成语言包准备", details: "Language assets not installed")
                    if !self.settings.phoneOnlyDisplay { self.openTranslationSetup() }
                    return
                }
                do {
                    try await self.viewModel.translationService.prepare(direction)
                    guard !Task.isCancelled, self.translationPreparationID == generation else { return }
                    self.viewModel.translationPreparationSucceeded(direction)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.viewModel.translationPreparationFailed(direction,
                        message: error.localizedDescription, details: "Independent session preparation failed")
                }
            }
        }
    }

    private func openTranslationSetup() {
        guard !settings.phoneOnlyDisplay else { return }
        if let translationWindow { translationWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "StreamTranslate — 语言包准备"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TranslationSetupView(target: settings.translationTarget) { [weak self] in
            guard let self else { return }
            self.translationWindow?.close()
            self.translationWindow = nil
            self.prepareIndependentTranslation()
        })
        window.center()
        translationWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func minimizeFloatingPanel() {
        guard let panel = floatingPanel, !panel.isMiniaturized else { return }
        viewModel.conversationSummary.collapse()
        updateSummaryPanelPresentation(false)
        panel.prepareForMinimization()
        let policyChanged = NSApp.setActivationPolicy(.regular)
        AppLogger.log("Minimizing floating panel. Dock policy changed=\(policyChanged)")
        panel.miniaturize(nil)
    }

    private func restoreFloatingPanel() {
        guard !settings.phoneOnlyDisplay else { return }
        guard let panel = floatingPanel else { return }
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        panel.level = .floating
        panel.orderFrontRegardless()
    }

    private func floatingPanelDidRestore() {
        guard !settings.phoneOnlyDisplay else { floatingPanel?.orderOut(nil); return }
        AppLogger.log("Floating panel restored from Dock")
        restoreFloatingPanel()
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        restoreFloatingPanel()
        return true
    }

    /// Show / hide the download progress window whenever `downloadProgress` or
    /// `downloadError` transitions between nil and non-nil. Keeping the window
    /// up while `downloadError != nil` is what prevents a failed download from
    /// silently dismissing its own UI — the old bug dressed in new clothes.
    private func observeDownloadProgress() {
        withObservationTracking {
            _ = viewModel.downloadProgress
            _ = viewModel.downloadError
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateDownloadProgressWindow()
                self?.observeDownloadProgress()
            }
        }
    }

    private func updateDownloadProgressWindow() {
        guard !settings.phoneOnlyDisplay else {
            downloadProgressWindow?.close()
            downloadProgressWindow = nil
            return
        }
        let isActive = viewModel.downloadProgress != nil
            || viewModel.downloadError != nil
        if isActive, downloadProgressWindow == nil {
            let modelName = ASRModel.available
                .first { $0.id == settings.selectedModelId }?.name ?? "speech model"
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.title = "StreamTranslate — First-time Setup"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.contentView = NSHostingView(
                rootView: ModelDownloadProgressView(modelName: modelName)
                    .environment(viewModel)
                    .environment(settings)
            )
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            downloadProgressWindow = window
        } else if !isActive, let window = downloadProgressWindow {
            window.close()
            downloadProgressWindow = nil
        }
    }

    private func observePanelSize() {
        withObservationTracking {
            let _ = settings.panelWidth
            let _ = settings.panelHeight
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updatePanelSize()
                self?.observePanelSize()
            }
        }
    }

    /// Recreate window-independent sessions when the language target changes.
    private func observeTranslationTarget() {
        withObservationTracking {
            let _ = settings.translationTarget
        } onChange: {
            Task { @MainActor [weak self] in
                self?.translationWindow?.close()
                self?.translationWindow = nil
                self?.prepareIndependentTranslation()
                self?.observeTranslationTarget()
            }
        }
    }

    private func updatePanelSize() {
        guard let panel = floatingPanel else { return }
        let width = settings.panelWidth
        let height = max(viewModel.conversationSummary.isExpanded ? FloatingPanel.minimumSummaryHeight : FloatingPanel.minimumCaptionHeight, settings.panelHeight)
        guard abs(panel.frame.width - width) > 0.5
                || abs(panel.frame.height - height) > 0.5 else { return }

        let currentFrame = panel.frame
        let x = currentFrame.midX - width / 2
        let y = currentFrame.midY - height / 2
        panel.setFrame(
            NSRect(x: x, y: y, width: width, height: height),
            display: true,
            animate: true
        )
    }

    private func updateSummaryPanelPresentation(_ expanded: Bool) {
        guard let panel = floatingPanel else { return }
        panel.minSize.height = expanded ? FloatingPanel.minimumSummaryHeight : FloatingPanel.minimumCaptionHeight
        if expanded, panel.frame.height < FloatingPanel.minimumSummaryHeight {
            var frame = panel.frame
            frame.size.height = FloatingPanel.minimumSummaryHeight
            if let screen = panel.screen { frame.origin.y = min(frame.minY, screen.visibleFrame.maxY - FloatingPanel.minimumSummaryHeight) }
            panel.setFrame(frame, display: true)
        } else if !expanded {
            // Keep the reading window's bottom edge in place; centering the
            // restored height would make every open/close cycle move it up.
            var frame = panel.frame
            frame.size.height = max(FloatingPanel.minimumCaptionHeight, settings.panelHeight)
            if abs(frame.height - panel.frame.height) > 0.5 { panel.setFrame(frame, display: true) }
        }
    }

    private func setupHotkey() {
        let manager = HotkeyManager {
            Task { @MainActor in
                self.viewModel.toggleCapture(
                    source: self.settings.audioInputSource,
                    sensitivity: self.settings.speechDetectionSensitivity,
                    recognitionMode: self.settings.recognitionLanguageMode,
                    recognitionVocabulary: self.settings.recognitionVocabulary,
                    captureDiagnosticsEnabled: self.settings.captureDiagnosticsEnabled
                )
            }
        }
        manager.register()
        hotkeyManager = manager
    }

    func openSettingsWindow() {
        guard !settings.phoneOnlyDisplay else { return }
        popover.performClose(nil)

        settingsWindowSlot.show { [viewModel, settings] in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "设置"
            window.contentMinSize = NSSize(width: 720, height: 540)
            window.contentView = NSHostingView(
                rootView: SettingsView()
                    .environment(viewModel)
                    .environment(settings)
            )
            window.center()
            return window
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openTranscriptWindow() {
        guard !settings.phoneOnlyDisplay else { return }
        popover.performClose(nil)
        transcriptWindowSlot.show { [viewModel, historyStore] in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "StreamTranslate — 历史记录"
            window.minSize = NSSize(width: 640, height: 400)
            window.level = .floating + 1
            window.contentView = NSHostingView(
                rootView: CaptionHistoryView(store: historyStore)
                    .environment(viewModel)
            )
            window.center()
            return window
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openCompanionWindow() {
        guard !settings.phoneOnlyDisplay else { return }
        popover.performClose(nil)
        companionWindowSlot.show { [companionServer, webCompanionServer, remoteCompanion, settings, viewModel] in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 650),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "StreamTranslate — 手机字幕"
            // An explicit control window must remain above the caption panel,
            // including when the user has expanded captions across the screen.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: CompanionSettingsView(server: companionServer, webServer: webCompanionServer, remote: remoteCompanion)
                .environment(settings).environment(viewModel))
            window.center()
            return window
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func observeCompanionSettings() {
        withObservationTracking {
            _ = settings.phoneOnlyDisplay
            _ = settings.companionEnabled
            _ = settings.companionPeerToPeer
            _ = settings.webCompanionEnabled
            _ = settings.remoteCompanionEnabled
            _ = settings.webQuickConnection
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateCompanionConfiguration()
                self?.observeCompanionSettings()
            }
        }
    }

    private func updateCompanionConfiguration() {
        applyVisibilityPolicy()
        if settings.companionEnabled {
            if companionServer.isRunning, companionServer.peerToPeer != settings.companionPeerToPeer {
                companionServer.stop()
            }
            companionServer.start(peerToPeer: settings.companionPeerToPeer)
        } else {
            companionServer.stop()
        }
        if settings.webCompanionEnabled { webCompanionServer.start(transport: settings.webQuickConnection ? .trustedLAN : .secure) }
        else { webCompanionServer.stop() }
        if settings.remoteCompanionEnabled { remoteCompanion.start() }
        else { remoteCompanion.stop() }
        if settings.companionEnabled || settings.webCompanionEnabled || settings.remoteCompanionEnabled {
            companionPublisher.start(viewModel: viewModel, server: companionServer, webServer: webCompanionServer, remote: remoteCompanion)
        } else { companionPublisher.stop() }
    }

    private func applyVisibilityPolicy() {
        let policy = CaptionVisibilityPolicy(phoneOnly: settings.phoneOnlyDisplay)
        if !policy.permitsCaptionWindows {
            viewModel.conversationSummary.collapse()
            popover.performClose(nil)
            companionServer.cancelInvitation()
            webCompanionServer.cancelInvitation()
            remoteCompanion.cancelInvitation()
            for window in NSApp.windows { window.orderOut(nil) }
            // Tear down the setup host so it cannot request language dialogs.
            translationWindow?.close()
            translationWindow = nil
        } else if floatingPanel?.isVisible == false, floatingPanel?.isMiniaturized == false {
            restoreFloatingPanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.conversationSummary.cancel()
        historyStore.finishPendingWrites()
        if let suite = windowFixturePreferenceSuite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        translationPreparationTask?.cancel()
        companionPublisher.stop()
        companionServer.stop()
        webCompanionServer.stop()
        remoteCompanion.stop()
    }

    /// Process-level acceptance with isolated preferences and synthetic text.
    /// Never starts capture, discovery, hotkeys or file-based control, and
    /// never clears the existing application's shared log.
    private func runCompanionPrivacyCheck() {
        viewModel = CaptionViewModel()
        let suite = "StreamTranslate.privacy-check.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { exit(1) }
        settings = CaptionSettings(defaults: defaults)
        settings.phoneOnlyDisplay = true
        setupFloatingPanel()
        updateFloatingPanelContent()
        viewModel.addCaption(english: "Synthetic private caption", chinese: "测试私密字幕")
        applyVisibilityPolicy()
        openTranscriptWindow()
        openSettingsWindow()
        openCompanionWindow()
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        floatingPanelDidRestore()
        viewModel.downloadProgress = 0.5
        updateDownloadProgressWindow()
        prepareIndependentTranslation()
        Task { @MainActor [weak self] in
            guard let self else { exit(1) }
            for _ in 0..<100 {
                if self.viewModel.isTranslationReady { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let visible = NSApp.windows.filter(\.isVisible).count
            let passed = visible == 0 && self.viewModel.isTranslationReady
                && self.downloadProgressWindow == nil && self.translationWindow == nil
                && CaptionSettings(defaults: defaults).phoneOnlyDisplay
            print("PRIVATE WINDOW CHECK: visible=\(visible), independentTranslationReady=\(self.viewModel.isTranslationReady), pass=\(passed)")
            self.translationPreparationTask?.cancel()
            self.viewModel.translationService.cancelSessions()
            defaults.removePersistentDomain(forName: suite)
            exit(passed ? 0 : 1)
        }
    }
}
