import SwiftUI

struct AchievementTile: View {
    let status: AchievementStatus
    @State private var showDetails = false

    private let earnedColor = Color.yellow

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(status.earnedTier > 0 ? earnedColor.opacity(0.12) : Color.secondary.opacity(0.04))
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: status.progress)
                    .stroke(status.complete ? earnedColor : Color.accentColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: status.badge.symbol)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(status.earnedTier > 0 ? earnedColor : Color.secondary.opacity(0.55))
            }
            .frame(width: 58, height: 58)
            .overlay(alignment: .bottom) {
                if status.earnedTier > 0 {
                    Text(status.badge.targets.count > 1 ? Achievement.numeral(status.earnedTier) : "✓")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.background, in: Capsule())
                        .foregroundStyle(earnedColor)
                        .offset(y: 4)
                }
            }

            HStack(alignment: .top, spacing: 2) {
                Text(status.title)
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showDetails.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About \(status.badge.title)")
                .popover(isPresented: $showDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(status.badge.title).font(.headline)
                        Text(status.tooltip).font(.callout)
                    }
                    .padding(14)
                    .frame(width: 250)
                }
            }
            .foregroundStyle(status.earnedTier > 0 ? Color.primary : Color.secondary)
            .frame(height: 42, alignment: .top)

            Text(progressCaption)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.title). \(status.tooltip) \(progressCaption)")
    }

    private var progressCaption: String {
        if status.complete { return "Complete" }
        let prefix = status.badge.targets.count > 1 ? "Next \(Achievement.numeral(status.targetTier)) · " : ""
        return "\(prefix)\(Int(status.progress * 100))%"
    }
}
