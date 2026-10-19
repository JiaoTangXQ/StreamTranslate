import Testing
import AppKit
import SwiftUI
@testable import StreamTranslate

@Test @MainActor func floatingPanelIsTransparent() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    #expect(panel.isOpaque == false)
    #expect(panel.backgroundColor == .clear)
}

@Test @MainActor func floatingPanelIsFloatingLevel() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    #expect(panel.level == .floating)
}

@Test @MainActor func floatingPanelIsMovableByBackground() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    #expect(panel.isMovableByWindowBackground)
}

@Test @MainActor func floatingPanelSupportsNativeEdgeResizing() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    #expect(panel.styleMask.contains(.resizable))
    #expect(panel.minSize == NSSize(width: 300, height: 184))
}

@Test @MainActor func floatingPanelHasExplicitResizeTargetsOnEveryEdgeAndCorner() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))

    #expect(panel.resizeEdges(at: NSPoint(x: 0, y: 100)) == [.left])
    #expect(panel.resizeEdges(at: NSPoint(x: 400, y: 100)) == [.right])
    #expect(panel.resizeEdges(at: NSPoint(x: 200, y: 0)) == [.bottom])
    #expect(panel.resizeEdges(at: NSPoint(x: 200, y: 200)) == [.top])
    #expect(panel.resizeEdges(at: NSPoint(x: 0, y: 0)) == [.left, .bottom])
    #expect(panel.resizeEdges(at: NSPoint(x: 400, y: 0)) == [.right, .bottom])
    #expect(panel.resizeEdges(at: NSPoint(x: 0, y: 200)) == [.left, .top])
    #expect(panel.resizeEdges(at: NSPoint(x: 400, y: 200)) == [.right, .top])
    #expect(panel.resizeEdges(at: NSPoint(x: 200, y: 100)).isEmpty)
}

@Test @MainActor func floatingPanelVisibleEdgeRemainsInsideManualResizeTarget() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    let inset = FloatingPanel.resizeInteractionInset

    #expect(panel.resizeEdges(at: NSPoint(x: inset, y: 100)) == [.left])
    #expect(panel.resizeEdges(at: NSPoint(x: 400 - inset, y: 100)) == [.right])
    #expect(panel.resizeEdges(at: NSPoint(x: 385, y: 100)) == [.right])
    #expect(panel.resizeEdges(at: NSPoint(x: 200, y: inset)) == [.bottom])
    #expect(panel.resizeEdges(at: NSPoint(x: 200, y: 200 - inset)) == [.top])
}

@Test @MainActor func floatingPanelDisablesBackgroundMovementWhileHoveringResizeTarget() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))

    panel.updateResizeHover(at: NSPoint(x: 395, y: 100))
    #expect(!panel.isMovableByWindowBackground)

    panel.updateResizeHover(at: NSPoint(x: 200, y: 100))
    #expect(panel.isMovableByWindowBackground)
}

@Test @MainActor func floatingPanelManualResizeKeepsOppositeEdgesFixed() {
    let panel = FloatingPanel(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200))
    let initialFrame = panel.frame

    let resized = panel.resizedFrame(
        from: initialFrame,
        initialMouse: NSPoint(x: initialFrame.minX, y: initialFrame.maxY),
        currentMouse: NSPoint(x: initialFrame.minX - 40, y: initialFrame.maxY + 30),
        edges: [.left, .top]
    )

    #expect(resized == NSRect(x: 60, y: 100, width: 440, height: 230))
    #expect(resized.maxX == initialFrame.maxX)
    #expect(resized.minY == initialFrame.minY)
}

@Test @MainActor func floatingPanelManualResizeHonorsMinimumSize() {
    let panel = FloatingPanel(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200))
    let initialFrame = panel.frame

    let resized = panel.resizedFrame(
        from: initialFrame,
        initialMouse: NSPoint(x: initialFrame.minX, y: initialFrame.minY),
        currentMouse: NSPoint(x: initialFrame.maxX, y: initialFrame.maxY),
        edges: [.left, .bottom]
    )

    #expect(resized.size == panel.minSize)
    #expect(resized.maxX == initialFrame.maxX)
    #expect(resized.maxY == initialFrame.maxY)
}

@Test @MainActor func floatingPanelEdgeMouseDragResizesTheWindow() throws {
    let panel = FloatingPanel(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200))
    let initialFrame = panel.frame
    let mouseDown = try #require(NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: NSPoint(x: 0, y: 100),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ))
    let mouseDrag = try #require(NSEvent.mouseEvent(
        with: .leftMouseDragged,
        location: NSPoint(x: -40, y: 100),
        modifierFlags: [],
        timestamp: 0.1,
        windowNumber: panel.windowNumber,
        context: nil,
        eventNumber: 2,
        clickCount: 1,
        pressure: 1
    ))

    panel.sendEvent(mouseDown)
    panel.sendEvent(mouseDrag)

    #expect(panel.frame == NSRect(x: 60, y: 100, width: 440, height: 200))
    #expect(panel.frame.maxX == initialFrame.maxX)
}

@Test @MainActor func floatingPanelSupportsNativeMinimization() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    #expect(panel.styleMask.contains(.miniaturizable))
    #expect(panel.isReleasedWhenClosed == false)
}

@Test @MainActor func floatingPanelCanBecomeKeyForInteractiveControls() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    #expect(panel.canBecomeKey)
}

@Test @MainActor func floatingPanelContentRequestsKeyWindowForControls() {
    let contentView = FloatingPanelHostingView(rootView: Text("Caption"))
    #expect(contentView.needsPanelToBecomeKey)
}

@Test @MainActor func floatingPanelRoutesCommandCToSelectedTextEditor() throws {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    let textView = CopySpyTextView(frame: panel.contentView?.bounds ?? .zero)
    textView.string = "Copy this sentence"
    textView.setSelectedRange(NSRange(location: 0, length: 4))
    panel.contentView = textView
    #expect(panel.makeFirstResponder(textView))

    let commandC = try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: "c",
        charactersIgnoringModifiers: "c",
        isARepeat: false,
        keyCode: 8
    ))

    panel.sendEvent(commandC)

    #expect(textView.copyCount == 1)
}

@Test @MainActor func appWindowSlotReusesAnOpenWindowAndRecreatesItAfterClose() throws {
    let slot = AppWindowSlot()
    var creationCount = 0
    let makeWindow = {
        creationCount += 1
        return NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    slot.show(makeWindow: makeWindow)
    let firstWindow = try #require(slot.window)
    #expect(creationCount == 1)
    #expect(!firstWindow.isReleasedWhenClosed)

    slot.show(makeWindow: makeWindow)
    #expect(slot.window === firstWindow)
    #expect(creationCount == 1)

    firstWindow.close()
    #expect(slot.window == nil)

    slot.show(makeWindow: makeWindow)
    #expect(slot.window !== firstWindow)
    #expect(creationCount == 2)
    slot.window?.close()
}

@Test @MainActor func floatingPanelReportsResizedDimensions() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    var reportedSize: NSSize?
    panel.onResize = { reportedSize = $0 }

    panel.setFrame(
        NSRect(x: 0, y: 0, width: 720, height: 320),
        display: false
    )
    panel.windowDidResize(
        Notification(name: NSWindow.didResizeNotification, object: panel)
    )

    #expect(reportedSize == NSSize(width: 720, height: 320))
}

@Test @MainActor func floatingPanelReportsDockRestoration() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    var didRestore = false
    panel.onRestore = { didRestore = true }

    panel.windowDidDeminiaturize(
        Notification(name: NSWindow.didDeminiaturizeNotification, object: panel)
    )

    #expect(didRestore)
}

@Test @MainActor func floatingPanelConsumesSavedFrameAfterDockRestoration() {
    let originalFrame = NSRect(x: 80, y: 120, width: 620, height: 200)
    let panel = FloatingPanel(contentRect: originalFrame)
    panel.prepareForMinimization()
    panel.setFrame(NSRect(x: 10, y: 20, width: 400, height: 140), display: false)

    panel.restoreFrameAfterMinimization()
    #expect(panel.frame == originalFrame)

    let movedAfterRestore = NSRect(x: 220, y: 260, width: 700, height: 240)
    panel.setFrame(movedAfterRestore, display: false)
    panel.restoreFrameAfterMinimization()
    #expect(panel.frame == movedAfterRestore)
}

@Test @MainActor func floatingPanelDoesNotHideOnDeactivate() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    #expect(panel.hidesOnDeactivate == false)
}

@Test @MainActor func floatingPanelHasShadow() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    #expect(panel.hasShadow)
}

@Test @MainActor func floatingPanelCanJoinAllSpaces() {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
}

@MainActor
private final class CopySpyTextView: NSTextView {
    private(set) var copyCount = 0

    override func copy(_ sender: Any?) {
        copyCount += 1
    }
}
