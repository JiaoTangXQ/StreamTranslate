import AppKit
import SwiftUI

@main
struct LiveCaptionPreviewRenderer {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw PreviewError.missingOutputPath
        }

        let content = VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                Spacer()
                Image(systemName: "minus")
                    .foregroundStyle(.white.opacity(0.9))
            }

            LiveCaptionTextView(
                original: "We are improving the caption stability while the speaker continues.",
                stableOriginal: "We are improving the caption stability ",
                draftOriginal: "while the speaker continues.",
                translation: "我们正在提升字幕的稳定性，同时说话者仍在继续。",
                originalFontSize: 18,
                translationFontSize: 17,
                translationColor: Color(red: 0.47, green: 0.78, blue: 1)
            )
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 620, height: 200)
        .background(Color.black.opacity(0.88))

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 200)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw PreviewError.renderFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.renderFailed
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}

private enum PreviewError: Error {
    case missingOutputPath
    case renderFailed
}
