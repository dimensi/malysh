import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct FeedingReminderLiveActivityWidget: Widget {
    private let title = "Пора кормить"
    private let appearance = CareActivityAppearance.feeding

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FeedingReminderActivityAttributes.self) { context in
            CareActivityLockScreenRow(allowsStackingForWidth: true) {
                CareActivityInformation(title: title, appearance: appearance) {
                    elapsed(context.state)
                } subtitle: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("С последнего кормления")
                        Text(context.state.babyName).fontWeight(.medium)
                    }
                    .font(.caption)
                }
            } actions: {
                FeedingReminderActivityControls(attributes: context.attributes, island: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CareActivityLockScreenInsets())
            .activityBackgroundTint(appearance.surfaceColor)
            .activitySystemActionForegroundColor(.primary)
            .widgetURL(WidgetRoute(.today, babyID: context.attributes.babyID).url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CareActivityIslandHeaderCell {
                        CareActivityIslandHeading(title: title, appearance: appearance)
                    }
                }
                .contentMargins(.leading, CareActivityAppearance.islandHeaderInset)
                DynamicIslandExpandedRegion(.trailing) {
                    CareActivityIslandHeaderCell {
                        elapsed(context.state)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.trailing)
                            .padding(.trailing, 11)
                    }
                }
                .contentMargins(.trailing, CareActivityAppearance.islandHeaderInset)
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        Text(context.state.babyName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                        FeedingReminderActivityControls(attributes: context.attributes, island: true)
                    }
                }
            } compactLeading: {
                CareActivityIslandIcon(title: title, appearance: appearance)
            } compactTrailing: {
                FeedingReminderCompactElapsed(state: context.state)
            } minimal: {
                CareActivityIslandIcon(title: title, appearance: appearance)
            }
            .widgetURL(WidgetRoute(.today, babyID: context.attributes.babyID).url)
            .contentMargins(.horizontal, CareActivityAppearance.islandExpandedInset, for: .expanded)
        }
    }

    private func elapsed(_ state: FeedingReminderActivityAttributes.ContentState) -> some View {
        Text(state.elapsedLabel)
            .monospacedDigit()
            .accessibilityLabel("С последнего кормления прошло")
            .accessibilityValue(state.elapsedLabel)
    }
}

private struct FeedingReminderCompactElapsed: View {
    let state: FeedingReminderActivityAttributes.ContentState
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth

    var body: some View {
        if !isLimitedInWidth {
            ViewThatFits(in: .horizontal) {
                Text(state.elapsedLabel).fixedSize()
                Text("Пора")
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .frame(width: 64, alignment: .trailing)
            .foregroundStyle(.white)
            .accessibilityLabel("С последнего кормления прошло")
            .accessibilityValue(state.elapsedLabel)
        }
    }
}

private struct FeedingReminderActivityControls: View {
    let attributes: FeedingReminderActivityAttributes
    let island: Bool

    var body: some View {
        Group {
            if island {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        start(.left)
                        start(.right)
                        snooze
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    stacked
                }
            } else {
                stacked
            }
        }
        .font(.caption.weight(.semibold))
    }

    private var stacked: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                start(.left)
                start(.right)
            }
            snooze
        }
    }

    private func start(_ side: BreastSide) -> some View {
        CareActivityIntentButton(
            intent: StartFeedingFromReminderIntent(token: attributes.token, babyID: attributes.babyID, side: side),
            title: side == .left ? "Левая" : "Правая", appearance: .feeding, island: island, prominent: true
        )
        .accessibilityLabel(side == .left ? "Начать кормление левой грудью" : "Начать кормление правой грудью")
    }

    private var snooze: some View {
        CareActivityIntentButton(
            intent: SnoozeFeedingReminderIntent(token: attributes.token, babyID: attributes.babyID),
            title: "Через 15 минут", appearance: .feeding, island: island, prominent: false
        )
        .accessibilityLabel("Напомнить через 15 минут")
    }
}
