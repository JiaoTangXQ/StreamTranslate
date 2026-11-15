import SwiftUI

struct SummaryIntervalPicker: View {
    @Binding var selection: SummaryUpdateInterval
    var compact = false
    @State private var visibleID: Int?

    private let rowHeight: CGFloat = 24

    var body: some View {
        ZStack {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(SummaryUpdateInterval.allCases) { interval in
                        Button {
                            selection = interval
                            visibleID = interval.id
                        } label: {
                            Text(interval.displayName)
                                .font(.system(size: compact ? 11 : 12,
                                              weight: interval == selection ? .semibold : .regular,
                                              design: .rounded))
                                .foregroundStyle(interval == selection
                                    ? CaptionWorkspaceStyle.foreground
                                    : CaptionWorkspaceStyle.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: rowHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(interval.id)
                        .accessibilityLabel(interval.displayName)
                        .accessibilityAddTraits(interval == selection ? [.isSelected] : [])
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.vertical, compact ? 19 : 54, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $visibleID, anchor: .center)
            .onAppear { visibleID = selection.id }
            .onChange(of: visibleID) { _, id in
                guard let id, let interval = SummaryUpdateInterval(rawValue: id), interval != selection else { return }
                selection = interval
            }
            .onChange(of: selection) { _, interval in
                guard visibleID != interval.id else { return }
                withAnimation(.easeOut(duration: 0.16)) { visibleID = interval.id }
            }

            RoundedRectangle(cornerRadius: 7)
                .stroke(CaptionWorkspaceStyle.accent.opacity(0.65), lineWidth: 1)
                .frame(height: rowHeight + 4)
                .allowsHitTesting(false)
        }
        .frame(width: compact ? 112 : 150, height: compact ? 62 : 132)
        .clipped()
        .background(CaptionWorkspaceStyle.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CaptionWorkspaceStyle.line))
        .accessibilityLabel("脑图自动整理间隔")
    }
}
