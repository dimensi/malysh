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
    }
}

struct CareLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CareActivityAttributes.self) { context in
            CareActivityLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(context.state.surfaceColor)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    CareActivityIslandInfo(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CareActivityControls(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(context.state.islandAccent)
                    .accessibilityLabel(context.state.title)
            } compactTrailing: {
                CareActivityTimer(start: context.state.start)
                    .font(.caption2.weight(.medium))
                    .frame(width: 64)
                    .foregroundStyle(context.state.islandAccent)
            } minimal: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(context.state.islandAccent)
                    .accessibilityLabel(context.state.title)
            }
            .keylineTint(context.state.islandAccent)
            .contentMargins(.horizontal, 16, for: .expanded)
        }
    }
}

#Preview("Кормление · блокировка", as: .content, using: CareActivityAttributes(
    eventID: UUID(), babyID: UUID()
)) {
    CareLiveActivityWidget()
} contentStates: {
    CareActivityAttributes.ContentState(kind: .breast, start: .now.addingTimeInterval(-742),
                                        side: .left, babyName: "Малыш")
}

#Preview("Сон · остров", as: .dynamicIsland(.expanded), using: CareActivityAttributes(
    eventID: UUID(), babyID: UUID()
)) {
    CareLiveActivityWidget()
} contentStates: {
    CareActivityAttributes.ContentState(kind: .sleep, start: .now.addingTimeInterval(-4542),
                                        side: nil, babyName: "Малыш")
}
