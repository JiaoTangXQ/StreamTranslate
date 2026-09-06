import Foundation

/// All UI entry points consult the same policy, including launch and reopen.
struct CaptionVisibilityPolicy: Equatable {
    var phoneOnly: Bool
    var permitsCaptionWindows: Bool { !phoneOnly }
    var permitsSetupWindows: Bool { !phoneOnly }
    func shouldRestoreAfterDisconnect() -> Bool { false }
}
