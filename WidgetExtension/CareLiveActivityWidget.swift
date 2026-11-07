import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct MalyshWidgetBundle: WidgetBundle {
    var body: some Widget {
        DiaryWidget()
        CareDiaryWidget(surface: .feeding)
        CareDiaryWidget(surface: .diaper)
        CareDiaryWidget(surface: .sleep)
        CareDiaryWidget(surface: .quickActions)
        CareDiaryWidget(surface: .summary)
        CareDiaryWidget(surface: .dashboard)
        CareDiaryWidget(surface: .lastFeeding)
        CareDiaryWidget(surface: .wetDiapers)
        CareDiaryWidget(surface: .sleepStatus)
        CareDiaryWidget(surface: .age)
        WetDiaperControl()
        SleepCareControl()
        CareLiveActivityWidget()
        FeedingReminderLiveActivityWidget()
    }
}

struct CareLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CareActivityAttributes.self) { context in
            CareActivityContent(attributes: context.attributes, state: context.state)
                .widgetURL(WidgetRoute(.activity, babyID: context.attributes.babyID,
                                       eventID: context.attributes.eventID).url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CareActivityIslandTimerRow(region: .controls, attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CareActivityIslandTimerRow(region: .timer, attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CareActivityIslandTimerRow(
                        region: .accessibility, attributes: context.attributes, state: context.state
                    )
                }
            } compactLeading: {
                CareActivityIslandIcon(title: context.state.title, appearance: context.state.appearance)
            } compactTrailing: {
                CompactCareActivityTimer(state: context.state)
            } minimal: {
                CareActivityIslandIcon(title: context.state.title, appearance: context.state.appearance)
            }
            .widgetURL(WidgetRoute(.activity, babyID: context.attributes.babyID,
                                   eventID: context.attributes.eventID).url)
            .contentMargins(.horizontal, AppDesign.Spacing.row, for: .expanded)
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct CareActivityContent: View {
    let attributes: CareActivityAttributes
    let state: CareActivityAttributes.ContentState

    @Environment(\.activityFamily) private var family
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @ScaledMetric(relativeTo: .headline) private var sleepArtworkSize = 24.0

    var body: some View {
        if family == .small {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text(state.title)
                    } icon: {
                        if state.kind == .sleep {
                            Image("WidgetSleepArt")
                                .renderingMode(.original)
                                .resizable()
                                .scaledToFit()
                                .frame(width: sleepArtworkSize, height: sleepArtworkSize)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: state.appearance.symbol)
                        }
                    }
                    .font(.headline)
                    .lineLimit(1)
                    Text(state.babyName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isLuminanceReduced, state.end == nil {
                    Text(state.start, style: .relative)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                } else {
                    CareActivityTimer(start: state.start, end: state.end, alignment: .trailing)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 12)
            .privacySensitive()
        } else {
            let isFeeding = state.kind == .breast
            CareActivityLockScreen(attributes: attributes, state: state)
                .activityBackgroundTint(
                    isFeeding ? CareActivityAppearance.feedingLockScreenSurface : state.appearance.surfaceColor
                )
                .activitySystemActionForegroundColor(isFeeding ? .white : .primary)
        }
    }
}

private struct CompactCareActivityTimer: View {
    let state: CareActivityAttributes.ContentState
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth

    var body: some View {
        if !isLimitedInWidth {
            CareActivityTimer(start: state.start, alignment: .trailing)
                .font(.caption2.weight(.medium))
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(.white)
        }
    }
}

#Preview("Кормление · блокировка", as: .content, using: CareActivityAttributes(
    eventID: UUID(), babyID: UUID()
)) {
    CareLiveActivityWidget()
} contentStates: {
    CareActivityAttributes.ContentState(kind: .breast, start: .now.addingTimeInterval(-263),
                                        side: .left, babyName: "Андрей")
}

#Preview("Сон · остров", as: .dynamicIsland(.expanded), using: CareActivityAttributes(
    eventID: UUID(), babyID: UUID()
)) {
    CareLiveActivityWidget()
} contentStates: {
    CareActivityAttributes.ContentState(kind: .sleep, start: .now.addingTimeInterval(-4542),
                                        side: nil, babyName: "Малыш")
}
