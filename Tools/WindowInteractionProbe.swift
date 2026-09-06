import AppKit
import ApplicationServices

// Explicit UI diagnostic for the installed app. Logs window geometry and
// button names only, never caption text. Drag mode restores frame and pointer.
func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
}
func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var result = CGPoint.zero
    return AXValueGetValue(raw as! AXValue, .cgPoint, &result) ? result : nil
}
func size(_ element: AXUIElement) -> CGSize? {
    guard let raw = value(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var result = CGSize.zero
    return AXValueGetValue(raw as! AXValue, .cgSize, &result) ? result : nil
}
func send(_ type: CGEventType, _ position: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.08)
}
func phoneButton(_ root: AXUIElement, budget: inout Int) -> AXUIElement? {
    guard budget > 0 else { return nil }; budget -= 1
    if (value(root, kAXRoleAttribute) as? String) == kAXButtonRole {
        let label = (value(root, kAXDescriptionAttribute) as? String ?? "") + (value(root, kAXTitleAttribute) as? String ?? "")
        if label.contains("在手机看字幕") { return root }
    }
    for child in (value(root, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
        if let match = phoneButton(child, budget: &budget) { return match }
    }
    return nil
}
guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { print("UI permission unavailable; no prompts requested"); exit(2) }
let arguments = Array(CommandLine.arguments.dropFirst())
let requestedPID = arguments.firstIndex(of: "--pid").flatMap { $0 + 1 < arguments.count ? Int32(arguments[$0 + 1]) : nil }
let allowedPaths = ["/Applications/StreamTranslate.app", FileManager.default.currentDirectoryPath + "/build/StreamTranslate.app"]
let candidates = requestedPID.map { pid in NSRunningApplication(processIdentifier: pid).map { [$0] } ?? [] }
    ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.jiaotangxq.StreamTranslate")
guard let app = candidates.first(where: {
    requestedPID == nil ? $0.bundleURL?.path == "/Applications/StreamTranslate.app" : allowedPaths.contains($0.bundleURL?.path ?? "")
}) else { print("Scoped app not running"); exit(2) }
let element = AXUIElementCreateApplication(app.processIdentifier)
guard let windows = value(element, kAXWindowsAttribute) as? [AXUIElement],
      let window = windows.first(where: { (value($0, kAXTitleAttribute) as? String ?? "").isEmpty }),
      let origin = point(window, kAXPositionAttribute), let originalSize = size(window) else { print("Caption window unavailable"); exit(2) }
print("CAPTION FRAME", origin, originalSize)
for item in windows { print("WINDOW", value(item, kAXTitleAttribute) as? String ?? "", point(item, kAXPositionAttribute) ?? .zero, size(item) ?? .zero) }
let mode = arguments.first ?? "inspect"
if mode == "close-phone" {
    for item in windows where (value(item, kAXTitleAttribute) as? String) == "StreamTranslate — 手机字幕" {
        if let close = value(item, kAXCloseButtonAttribute) { _ = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString) }
    }
    print("Scoped phone window closed for caption-edge tests"); exit(0)
}
if mode == "phone-click" {
    let pointer = CGEvent(source: nil)?.location ?? .zero
    for item in windows where (value(item, kAXTitleAttribute) as? String) == "StreamTranslate — 手机字幕" {
        if let close = value(item, kAXCloseButtonAttribute) {
            _ = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
        }
    }
    send(.mouseMoved, CGPoint(x: origin.x + originalSize.width / 2, y: origin.y + originalSize.height - 36))
    Thread.sleep(forTimeInterval: 0.3)
    var budget = 1500
    guard let button = phoneButton(window, budget: &budget),
          let buttonOrigin = point(button, kAXPositionAttribute), let buttonSize = size(button) else {
        send(.mouseMoved, pointer); print("Phone button not accessible after hover"); exit(1)
    }
    let center = CGPoint(x: buttonOrigin.x + buttonSize.width / 2, y: buttonOrigin.y + buttonSize.height / 2)
    var hit: AXUIElement?, hitPID: pid_t = 0
    AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(center.x), Float(center.y), &hit)
    if let hit { AXUIElementGetPid(hit, &hitPID) }
    guard hitPID == app.processIdentifier else { send(.mouseMoved, pointer); print("Button covered by another process; no click"); exit(1) }
    send(.mouseMoved, center); send(.leftMouseDown, center); send(.leftMouseUp, center)
    Thread.sleep(forTimeInterval: 0.35)
    send(.mouseMoved, pointer)
    print("PHONE BUTTON clicked through real mouse events")
}
if mode == "phone-front" || mode == "phone-click" {
    let visible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier }
    guard let phoneIndex = visible.firstIndex(where: { ($0[kCGWindowName as String] as? String) == "StreamTranslate — 手机字幕" }),
          let captionIndex = visible.firstIndex(where: { ($0[kCGWindowLayer as String] as? Int) == 3 && ($0[kCGWindowName as String] as? String ?? "").isEmpty }) else {
        print("Both scoped windows must be visible"); exit(2)
    }
    print("PHONE IN FRONT", phoneIndex < captionIndex,
          "phone layer", visible[phoneIndex][kCGWindowLayer as String] ?? "",
          "caption layer", visible[captionIndex][kCGWindowLayer as String] ?? "")
    exit(phoneIndex < captionIndex ? 0 : 1)
}
if mode == "edge-scan" {
    let system = AXUIElementCreateSystemWide()
    for inset in [1.0, 3, 6, 8, 10, 14, 17] {
        let location = CGPoint(x: origin.x + originalSize.width - inset, y: origin.y + originalSize.height / 2)
        var target: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(location.x), Float(location.y), &target)
        var pid: pid_t = 0
        if let target { AXUIElementGetPid(target, &pid) }
        print("EDGE INSET", inset, "hit status", result.rawValue, "belongs to caption app", pid == app.processIdentifier)
    }
    exit(0)
}
if ["drag-right", "drag-right-edge", "drag-left-edge", "drag-top-edge", "drag-bottom-edge", "drag-corner"].contains(mode) {
    let originalPointer = CGEvent(source: nil)?.location ?? .zero
    var start = CGPoint(x: origin.x + originalSize.width - (mode == "drag-right-edge" ? 1 : 10), y: origin.y + originalSize.height / 2)
    var delta = CGPoint(x: -60, y: 0), expected = CGSize(width: originalSize.width - 60, height: originalSize.height)
    if mode == "drag-left-edge" { start.x = origin.x + 1; delta.x = 60 }
    if mode == "drag-top-edge" || mode == "drag-bottom-edge" {
        start.x = origin.x + originalSize.width / 2
        start.y = mode == "drag-top-edge" ? origin.y + 1 : origin.y + originalSize.height - 1
        delta = CGPoint(x: 0, y: mode == "drag-top-edge" ? 40 : -40)
        expected = CGSize(width: originalSize.width, height: originalSize.height - 40)
    }
    if mode == "drag-corner" {
        start = CGPoint(x: origin.x + originalSize.width - 13, y: origin.y + originalSize.height - 13)
        delta = CGPoint(x: -60, y: -40)
        expected = CGSize(width: originalSize.width - 60, height: originalSize.height - 40)
    }
    var target: AXUIElement?, targetPID: pid_t = 0
    AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(start.x), Float(start.y), &target)
    if let target { AXUIElementGetPid(target, &targetPID) }
    guard targetPID == app.processIdentifier, let target,
          CFEqual(value(target, kAXWindowAttribute) ?? target, window) else {
        print("EDGE MISSES CAPTION WINDOW; refusing to click another window"); exit(1)
    }
    send(.mouseMoved, start)
    send(.leftMouseDown, start)
    for step in 1...5 { send(.leftMouseDragged, CGPoint(x: start.x + delta.x * CGFloat(step) / 5, y: start.y + delta.y * CGFloat(step) / 5)) }
    send(.leftMouseUp, CGPoint(x: start.x + delta.x, y: start.y + delta.y))
    Thread.sleep(forTimeInterval: 0.5)
    let changed = size(window) ?? .zero
    print("AFTER DRAG", changed, "expected", expected)
    var restoreSize = originalSize, restoreOrigin = origin
    // Restore origin first: after a top-edge drag, setting the old height at
    // the lower origin can be clamped to the screen before position restores.
    let positionStatus = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &restoreOrigin)!)
    let sizeStatus = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &restoreSize)!)
    send(.mouseMoved, originalPointer)
    print("RESTORE", sizeStatus.rawValue, positionStatus.rawValue, size(window) ?? .zero)
    let restoredSize = size(window) ?? .zero
    let restoredOrigin = point(window, kAXPositionAttribute) ?? CGPoint(x: -10000, y: -10000)
    let restored = sizeStatus == .success && positionStatus == .success
        && abs(restoredSize.width - originalSize.width) < 3 && abs(restoredSize.height - originalSize.height) < 3
        && abs(restoredOrigin.x - origin.x) < 3 && abs(restoredOrigin.y - origin.y) < 3
    print("RESTORE VERIFIED", restored)
    exit(abs(changed.width - expected.width) < 3 && abs(changed.height - expected.height) < 3 && restored ? 0 : 1)
}
