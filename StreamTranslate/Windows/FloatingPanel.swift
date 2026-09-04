import SwiftUI

@MainActor
final class FloatingPanelHostingView<Content: View>: NSHostingView<Content> {
    override var needsPanelToBecomeKey: Bool { true }
}

struct FloatingPanelResizeEdges: OptionSet, Equatable {
    let rawValue: UInt8

    static let left = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let bottom = Self(rawValue: 1 << 2)
    static let top = Self(rawValue: 1 << 3)
}

final class FloatingPanel: NSPanel, NSWindowDelegate {
    /// Keeps the visible caption edge inside the window-server event region.
    /// A nonactivating panel can lose its native outer resize border after a
    /// Dock restore, while points inside the content region remain reliable.
    static let resizeInteractionInset: CGFloat = 6

    var onResize: ((NSSize) -> Void)?
    var onRestore: (() -> Void)?

    private struct ResizeSession {
        let edges: FloatingPanelResizeEdges
        let initialFrame: NSRect
        let initialMouse: NSPoint
    }

    private static let resizeHitWidth: CGFloat = 16
    private var frameBeforeMinimize: NSRect?
    private var resizeSession: ResizeSession?

    override var canBecomeKey: Bool { true }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        minSize = NSSize(width: 300, height: 104)
        delegate = self
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if copySelectedText(for: event) {
                return
            }
            super.sendEvent(event)

        case .leftMouseDown:
            let edges = resizeEdges(at: event.locationInWindow)
            guard !edges.isEmpty else {
                super.sendEvent(event)
                return
            }
            isMovableByWindowBackground = false
            resizeSession = ResizeSession(
                edges: edges,
                initialFrame: frame,
                initialMouse: screenPoint(for: event)
            )
            resizeCursor(for: edges).set()
            return

        case .leftMouseDragged:
            guard let resizeSession else {
                super.sendEvent(event)
                return
            }
            let nextFrame = resizedFrame(
                from: resizeSession.initialFrame,
                initialMouse: resizeSession.initialMouse,
                currentMouse: screenPoint(for: event),
                edges: resizeSession.edges
            )
            setFrame(nextFrame, display: true)
            return

        case .leftMouseUp:
            guard let resizeSession else {
                super.sendEvent(event)
                return
            }
            let nextFrame = resizedFrame(
                from: resizeSession.initialFrame,
                initialMouse: resizeSession.initialMouse,
                currentMouse: screenPoint(for: event),
                edges: resizeSession.edges
            )
            setFrame(nextFrame, display: true)
            self.resizeSession = nil
            updateResizeHover(at: event.locationInWindow)
            return

        case .mouseMoved, .cursorUpdate:
            super.sendEvent(event)
            updateResizeHover(at: event.locationInWindow)
            return

        case .mouseExited:
            super.sendEvent(event)
            isMovableByWindowBackground = true
            NSCursor.arrow.set()
            return

        default:
            super.sendEvent(event)
        }
    }

    private func copySelectedText(for event: NSEvent) -> Bool {
        let shortcutModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard shortcutModifiers == .command,
              event.charactersIgnoringModifiers?.lowercased() == "c",
              let textEditor = activeTextEditor,
              textEditor.selectedRange().length > 0 else {
            return false
        }

        textEditor.copy(nil)
        return true
    }

    private var activeTextEditor: NSTextView? {
        if let textEditor = firstResponder as? NSTextView {
            return textEditor
        }
        if let textField = firstResponder as? NSTextField {
            return textField.currentEditor() as? NSTextView
        }
        return nil
    }

    func resizeEdges(at point: NSPoint) -> FloatingPanelResizeEdges {
        let size = contentView?.bounds.size ?? frame.size
        let hitWidth = Self.resizeHitWidth
        var edges: FloatingPanelResizeEdges = []

        if point.x <= hitWidth {
            edges.insert(.left)
        } else if point.x >= size.width - hitWidth {
            edges.insert(.right)
        }

        if point.y <= hitWidth {
            edges.insert(.bottom)
        } else if point.y >= size.height - hitWidth {
            edges.insert(.top)
        }

        return edges
    }

    func updateResizeHover(at point: NSPoint) {
        let edges = resizeEdges(at: point)
        isMovableByWindowBackground = edges.isEmpty
        resizeCursor(for: edges).set()
    }

    func resizedFrame(
        from initialFrame: NSRect,
        initialMouse: NSPoint,
        currentMouse: NSPoint,
        edges: FloatingPanelResizeEdges
    ) -> NSRect {
        let deltaX = currentMouse.x - initialMouse.x
        let deltaY = currentMouse.y - initialMouse.y
        var result = initialFrame

        if edges.contains(.left) {
            result.origin.x += deltaX
            result.size.width -= deltaX
        } else if edges.contains(.right) {
            result.size.width += deltaX
        }

        if edges.contains(.bottom) {
            result.origin.y += deltaY
            result.size.height -= deltaY
        } else if edges.contains(.top) {
            result.size.height += deltaY
        }

        let minimum = minSize
        if result.width < minimum.width {
            if edges.contains(.left) {
                result.origin.x = initialFrame.maxX - minimum.width
            }
            result.size.width = minimum.width
        }
        if result.height < minimum.height {
            if edges.contains(.bottom) {
                result.origin.y = initialFrame.maxY - minimum.height
            }
            result.size.height = minimum.height
        }

        let maximum = maxSize
        if maximum.width > 0, result.width > maximum.width {
            if edges.contains(.left) {
                result.origin.x = initialFrame.maxX - maximum.width
            }
            result.size.width = maximum.width
        }
        if maximum.height > 0, result.height > maximum.height {
            if edges.contains(.bottom) {
                result.origin.y = initialFrame.maxY - maximum.height
            }
            result.size.height = maximum.height
        }

        return result
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        convertPoint(toScreen: event.locationInWindow)
    }

    private func resizeCursor(for edges: FloatingPanelResizeEdges) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch edges {
        case [.left, .top]: position = .topLeft
        case [.right, .top]: position = .topRight
        case [.left, .bottom]: position = .bottomLeft
        case [.right, .bottom]: position = .bottomRight
        case [.left]: position = .left
        case [.right]: position = .right
        case [.bottom]: position = .bottom
        case [.top]: position = .top
        default: return .arrow
        }
        return .frameResize(position: position, directions: .all)
    }

    func prepareForMinimization() {
        frameBeforeMinimize = frame
    }

    func restoreFrameAfterMinimization() {
        guard let savedFrame = frameBeforeMinimize else { return }
        frameBeforeMinimize = nil
        setFrame(savedFrame, display: true)
    }

    func windowDidResize(_ notification: Notification) {
        onResize?(frame.size)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        restoreFrameAfterMinimization()
        onRestore?()
    }
}
