import SwiftUI
import Translation

@main
struct StreamTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
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
    private var viewModel = CaptionViewModel()
    private var settings = CaptionSettings()
    private var floatingPanel: FloatingPanel?
    private var hotkeyManager: HotkeyManager?
    private var popover = NSPopover()
    private var translationWindow: NSWindow?
    private let settingsWindowSlot = AppWindowSlot()
    private let transcriptWindowSlot = AppWindowSlot()
    private var downloadProgressWindow: NSWindow?
    private var notificationObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.clear()
        AppLogger.log("App launched. Log file: \(AppLogger.path)")

        setupStatusItem()
        setupFloatingPanel()
        setupHotkey()
        setupRemoteControl()
        updateFloatingPanelWithTranslation()
        observePanelSize()
        observeTranslationTarget()
        observeDownloadProgress()

        viewModel.preloadModel(modelId: settings.selectedModelId)
    }

    /// Listen for distributed notification to toggle recording (for testing/automation)
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
        let height = settings.panelHeight
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height)
        )
        panel.onResize = { [weak self] size in
            guard let self else { return }
            if abs(self.settings.panelWidth - size.width) > 0.5 {
                self.settings.panelWidth = size.width
            }
            if abs(self.settings.panelHeight - size.height) > 0.5 {
                self.settings.panelHeight = size.height
            }
        }
        panel.onRestore = { [weak self] in
            self?.floatingPanelDidRestore()
        }

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - width / 2
            let y = screenFrame.minY + 60
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        floatingPanel = panel
    }

    private func updateFloatingPanelWithTranslation() {
        let englishToChinese = viewModel.translationService.configuration(
            direction: .englishToChinese,
            chineseTarget: settings.translationTarget
        )
        let chineseToEnglish = viewModel.translationService.configuration(
            direction: .chineseToEnglish,
            chineseTarget: settings.translationTarget
        )
        let translationService = viewModel.translationService
        let translationState = viewModel
        let content = FloatingCaptionView { [weak self] in
            self?.minimizeFloatingPanel()
        }
            .environment(viewModel)
            .environment(settings)
            .translationTask(englishToChinese) { session in
                let direction = TranslationDirection.englishToChinese
                translationService.setSession(session, for: direction)
                translationState.translationPreparationStarted(direction)
                do {
                    try await translationService.prepare(direction)
                    translationState.translationPreparationSucceeded(direction)
                } catch {
                    let nsError = error as NSError
                    translationState.translationPreparationFailed(
                        direction,
                        message: error.localizedDescription,
                        details: "\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)"
                    )
                }
            }
            .translationTask(chineseToEnglish) { session in
                let direction = TranslationDirection.chineseToEnglish
                translationService.setSession(session, for: direction)
                translationState.translationPreparationStarted(direction)
                do {
                    try await translationService.prepare(direction)
                    translationState.translationPreparationSucceeded(direction)
                } catch {
                    let nsError = error as NSError
                    translationState.translationPreparationFailed(
                        direction,
                        message: error.localizedDescription,
                        details: "\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)"
                    )
                }
            }

        floatingPanel?.contentView = FloatingPanelHostingView(rootView: content)
    }

    private func minimizeFloatingPanel() {
        guard let panel = floatingPanel, !panel.isMiniaturized else { return }
        panel.prepareForMinimization()
        let policyChanged = NSApp.setActivationPolicy(.regular)
        AppLogger.log("Minimizing floating panel. Dock policy changed=\(policyChanged)")
        panel.miniaturize(nil)
    }

    private func restoreFloatingPanel() {
        guard let panel = floatingPanel else { return }
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        panel.level = .floating
        panel.orderFrontRegardless()
    }

    private func floatingPanelDidRestore() {
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

    /// Rebuild the floating panel's hosting view when the user picks a new
    /// Chinese variant. `.translationTask(config)` is pinned to the view at
    /// mount time; replacing the NSHostingView is the cleanest way to force
    /// SwiftUI to request a new TranslationSession for the new BCP-47 target.
    private func observeTranslationTarget() {
        withObservationTracking {
            let _ = settings.translationTarget
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateFloatingPanelWithTranslation()
                self?.observeTranslationTarget()
            }
        }
    }

    private func updatePanelSize() {
        guard let panel = floatingPanel else { return }
        let width = settings.panelWidth
        let height = settings.panelHeight
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

    private func openSettingsWindow() {
        popover.performClose(nil)

        settingsWindowSlot.show { [viewModel, settings] in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
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
        transcriptWindowSlot.show { [viewModel, settings] in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "StreamTranslate"
            window.contentView = NSHostingView(
                rootView: MainWindowView()
                    .environment(viewModel)
                    .environment(settings)
            )
            window.center()
            return window
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
