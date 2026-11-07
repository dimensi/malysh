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
            let isFeeding = context.state.kind == .breast
            CareActivityLockScreen(attributes: context.attributes, state: context.state)
                .widgetURL(WidgetRoute(.activity, babyID: context.attributes.babyID,
                                       eventID: context.attributes.eventID).url)
                .activityBackgroundTint(
                    isFeeding ? CareActivityAppearance.feedingLockScreenSurface : context.state.appearance.surfaceColor
                )
                .activitySystemActionForegroundColor(isFeeding ? .white : .primary)
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
