import SwiftUI

struct LiveCaptionTextView: View {
    let original: String
    let stableOriginal: String
    let draftOriginal: String
    let translation: String
    let originalFontSize: CGFloat
    let translationFontSize: CGFloat
    let translationColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(styledOriginal)
                .font(.system(size: originalFontSize))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(original)

            Group {
                if translation.isEmpty {
                    Text("Translation pending")
                        .hidden()
                        .accessibilityHidden(true)
                } else {
                    Text(translation)
                        .foregroundStyle(translationColor)
                }
            }
            .font(.system(size: translationFontSize))
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                minHeight: max(translationFontSize * 1.25, 16),
                alignment: .topLeading
            )
        }
        .transaction { $0.animation = nil }
    }

    private var styledOriginal: AttributedString {
        if stableOriginal.isEmpty, draftOriginal.isEmpty {
            var fallback = AttributedString(original)
            fallback.foregroundColor = .white
            return fallback
        }

        var stable = AttributedString(stableOriginal)
        stable.foregroundColor = .white
        var draft = AttributedString(draftOriginal)
        draft.foregroundColor = .white.opacity(0.58)
        return stable + draft
    }
}
