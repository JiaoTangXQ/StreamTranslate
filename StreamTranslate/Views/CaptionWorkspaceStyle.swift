import SwiftUI

/// Shared reading-surface roles. Native system type, restrained blue, no effects
/// on live text: input and translation stay ahead of decorative rendering.
enum CaptionWorkspaceStyle {
    static let surface = Color(red: 0.055, green: 0.067, blue: 0.082)
    static let sidebar = Color(red: 0.080, green: 0.094, blue: 0.114)
    static let foreground = Color(white: 0.94)
    static let secondary = Color(white: 0.69)
    static let line = Color.white.opacity(0.09)
    static let accent = Color(red: 0.52, green: 0.77, blue: 0.96)
    static let splitMinimum: CGFloat = 760
    static let sidebarWidth: CGFloat = 344
}

struct CaptionToolbarButton: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? CaptionWorkspaceStyle.accent : CaptionWorkspaceStyle.secondary)
                .frame(width: 30, height: 30)
                .background((selected || hovered) ? Color.white.opacity(0.07) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title).accessibilityLabel(title)
        .onHover { hovered = $0 }
    }
}
