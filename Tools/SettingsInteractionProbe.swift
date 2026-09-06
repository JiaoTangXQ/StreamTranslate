import AppKit
import ApplicationServices

// Installed settings window only. Never inspect captions or change audio/model/privacy settings.
func value(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(item, name as CFString, &result) == .success ? result : nil
}
func find(_ root: AXUIElement, depth: Int = 0, predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    guard depth < 18 else { return nil }
    if predicate(root) { return root }
    for child in value(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let result = find(child, depth: depth + 1, predicate: predicate) { return result }
    }
    return nil
}
func label(_ item: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { value(item, $0) as? String }.joined(separator: " ")
}
guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { print("UI permissions unavailable; no prompts requested"); exit(2) }
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.jiaotangxq.StreamTranslate")
    .first(where: { $0.bundleURL?.path == "/Applications/StreamTranslate.app" }) else { exit(2) }
app.activate(options: [.activateIgnoringOtherApps])
for _ in 0..<20 { if app.isActive { break }; RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
guard app.isActive else { print("Cannot safely target installed app"); exit(2) }
for down in [true, false] {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 43, keyDown: down)!
    event.flags = .maskCommand; event.post(tap: .cghidEventTap)
}
Thread.sleep(forTimeInterval: 0.7)
let root = AXUIElementCreateApplication(app.processIdentifier)
guard let window = (value(root, kAXWindowsAttribute) as? [AXUIElement])?.first(where: {
    (value($0, kAXTitleAttribute) as? String) == "设置"
}) else { print("Settings unavailable (private-only guard may be active)"); exit(2) }
for (page, heading) in [("appearance", "阅读预览"), ("intelligence", "语音识别模型"), ("privacy", "数据去向"), ("listening", "音频来源")] {
    guard let button = find(window, predicate: { (value($0, kAXIdentifierAttribute) as? String) == "settings-page-\(page)" }),
          AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
        print("FAIL: navigation \(page)"); exit(1)
    }
    Thread.sleep(forTimeInterval: 0.25)
    guard find(window, predicate: { label($0).contains(heading) }) != nil else {
        print("FAIL: missing page content \(page)"); exit(1)
    }
    print("PASS: native settings navigation \(page)")
    if page == "appearance" {
        guard let slider = find(window, predicate: {
            (value($0, kAXRoleAttribute) as? String) == kAXSliderRole && label($0).contains("文字大小")
        }), let old = value(slider, kAXValueAttribute) as? NSNumber,
            let minimum = value(slider, kAXMinValueAttribute) as? NSNumber,
            let maximum = value(slider, kAXMaxValueAttribute) as? NSNumber else {
            print("FAIL: font slider accessibility"); exit(1)
        }
        let increment = (maximum.doubleValue - minimum.doubleValue) / 14
        let changed = old.doubleValue + increment <= maximum.doubleValue ? old.doubleValue + increment : old.doubleValue - increment
        let set = AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, NSNumber(value: changed))
        Thread.sleep(forTimeInterval: 0.25)
        let actual = value(slider, kAXValueAttribute) as? NSNumber
        let restore = AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, old)
        Thread.sleep(forTimeInterval: 0.25)
        guard set == .success, restore == .success, actual != old,
              let restored = value(slider, kAXValueAttribute) as? NSNumber,
              abs(restored.doubleValue - old.doubleValue) < 0.001 else {
            print("FAIL: font slider round trip; restoration attempted"); exit(1)
        }
        print("PASS: font adjustment works and original value restored")
    }
}
print("PASS: installed Chinese settings window opens via Command-comma")
if let raw = value(window, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
    var original = CGSize.zero
    if AXValueGetValue(raw as! AXValue, .cgSize, &original) {
        var compact = CGSize(width: 720, height: 568)
        let sizeValue = AXValueCreate(.cgSize, &compact)!
        let changed = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        Thread.sleep(forTimeInterval: 0.25)
        var actual = CGSize.zero
        if let current = value(window, kAXSizeAttribute), CFGetTypeID(current) == AXValueGetTypeID() {
            _ = AXValueGetValue(current as! AXValue, .cgSize, &actual)
        }
        let restore = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &original)!)
        guard changed == .success, restore == .success, actual.width < original.width, actual.width >= 720 else {
            print("FAIL: window resize round trip; restoration attempted"); exit(1)
        }
        print("PASS: settings window resizes and original size restored")
    }
}
let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
if let ownWindow = windows.first(where: {
    ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowName as String] as? String) == "设置"
}), let identifier = ownWindow[kCGWindowNumber as String] as? Int {
    print("SETTINGS_WINDOW_ID=\(identifier)")
}
