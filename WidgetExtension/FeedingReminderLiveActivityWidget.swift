import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct FeedingReminderLiveActivityWidget: Widget {
    private let title = "Пора кормить"
    private let appearance = CareActivityAppearance.feeding

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FeedingReminderActivityAttributes.self) { context in
            FeedingReminderLockScreen(title: title, state: context.state, attributes: context.attributes)
                .activityBackgroundTint(CareActivityAppearance.feedingLockScreenSurface)
                .activitySystemActionForegroundColor(.white)
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
                        FeedingReminderActivityControls(attributes: context.attributes)
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

private struct FeedingReminderLockScreen: View {
    let title: String
    let state: FeedingReminderActivityAttributes.ContentState
    let attributes: FeedingReminderActivityAttributes
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    information
                    HStack {
                        CareActivityBrandMark()
                        Spacer(minLength: 0)
                        FeedingReminderSnoozeButton(attributes: attributes, diameter: 52)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    CareActivityBrandMark()
                    information
                    Spacer(minLength: 0)
                    FeedingReminderSnoozeButton(attributes: attributes, diameter: 52)
                }
            }
            HStack(spacing: 8) {
                FeedingReminderStartButton(attributes: attributes, side: .left, island: false)
                FeedingReminderStartButton(attributes: attributes, side: .right, island: false)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(state.babyName) · \(title)")
                .font(.subheadline.weight(.semibold))
            Text(compactElapsedLabel)
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .accessibilityLabel("С последнего кормления прошло")
                .accessibilityValue(state.elapsedLabel)
            Text("С последнего кормления")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var compactElapsedLabel: String {
        // The persisted label uses Russian plural forms and also serves as the spoken value.
        state.elapsedLabel.split(separator: " ").map { component in
            switch component {
            case "час", "часа", "часов": "ч"
            case "минута", "минуты", "минут": "мин"
            default: String(component)
            }
        }
        .joined(separator: " ")
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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                startButtons
                snooze
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 0) {
                HStack(spacing: 8) { startButtons }
                snooze
            }
        }
    }

    @ViewBuilder private var startButtons: some View {
        FeedingReminderStartButton(attributes: attributes, side: .left, island: true)
        FeedingReminderStartButton(attributes: attributes, side: .right, island: true)
    }

    private var snooze: some View {
        FeedingReminderSnoozeButton(attributes: attributes, diameter: 44)
    }
}

private struct FeedingReminderStartButton: View {
    let attributes: FeedingReminderActivityAttributes
    let side: BreastSide
    let island: Bool

    var body: some View {
        Group {
            if island {
                CareActivityIntentButton(
                    intent: intent, title: title, appearance: .feeding, island: true, prominent: true
                )
            } else {
                Button(intent: intent) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CareActivityAppearance.feeding.islandAccent)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
                        .background(Color(red: 0.29, green: 0.22, blue: 0.19), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(side == .left ? "Начать кормление левой грудью" : "Начать кормление правой грудью")
    }

    private var title: LocalizedStringKey {
        side == .left ? "Левая" : "Правая"
    }

    private var intent: StartFeedingFromReminderIntent {
        StartFeedingFromReminderIntent(token: attributes.token, babyID: attributes.babyID, side: side)
    }
}

private struct FeedingReminderSnoozeButton: View {
    let attributes: FeedingReminderActivityAttributes
    let diameter: CGFloat

    var body: some View {
        CareActivityCircleButton(
            intent: SnoozeFeedingReminderIntent(token: attributes.token, babyID: attributes.babyID),
            prominent: false, diameter: diameter
        ) {
            Image("FeedingReminderSnooze")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .foregroundStyle(CareActivityAppearance.feeding.islandAccent)
        }
        .accessibilityLabel("Напомнить через 15 минут")
    }
}
