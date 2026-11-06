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
                .widgetURL(WidgetRoute(.activity, babyID: context.attributes.babyID,
                                       eventID: context.attributes.eventID).url)
                .activityBackgroundTint(context.state.surfaceColor)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CareActivityIslandHeaderCell {
                        CareActivityIslandHeading(state: context.state)
                    }
                }
                .contentMargins(.leading, 26)
                DynamicIslandExpandedRegion(.trailing) {
                    CareActivityIslandHeaderCell {
                        CareActivityTimer(start: context.state.start, end: context.state.end, alignment: .trailing)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 11)
                    }
                }
                .contentMargins(.trailing, 26)
                DynamicIslandExpandedRegion(.bottom) {
                    CareActivityIslandActions(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(context.state.islandAccent)
                    .accessibilityLabel(context.state.title)
            } compactTrailing: {
                CompactCareActivityTimer(state: context.state)
            } minimal: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(context.state.islandAccent)
                    .accessibilityLabel(context.state.title)
            }
            .widgetURL(WidgetRoute(.activity, babyID: context.attributes.babyID,
                                   eventID: context.attributes.eventID).url)
            .contentMargins(.horizontal, 16, for: .expanded)
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
