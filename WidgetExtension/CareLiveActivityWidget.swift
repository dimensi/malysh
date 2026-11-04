import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct MalyshWidgetBundle: WidgetBundle {
    var body: some Widget {
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
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.symbol)
                        .font(.title2)
                        .foregroundStyle(context.state.islandAccent)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.title).font(.headline)
                        .foregroundStyle(context.state.islandAccent)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            CareActivityTimer(start: context.state.start)
                                .font(.largeTitle.weight(.semibold))
                            if let side = context.state.side, context.state.kind == .breast {
                                Text("\(side.label) грудь").font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .foregroundStyle(.white)
                        CareActivityControls(attributes: context.attributes, state: context.state)
                    }
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
        }
    }
}

struct CareActivityLockScreen: View {
    let attributes: CareActivityAttributes
    let state: CareActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(state.title, systemImage: state.symbol).font(.headline)
                Spacer(minLength: 12)
                Text(state.babyName).font(.subheadline).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline) {
                CareActivityTimer(start: state.start)
                    .font(.largeTitle.weight(.semibold))
                if state.kind == .breast, let side = state.side {
                    Text("\(side.label) грудь").font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            CareActivityControls(attributes: attributes, state: state, island: false)
        }
        .foregroundStyle(.primary)
        .padding(16)
        .background(state.surfaceColor)
    }
}

private struct CareActivityTimer: View {
    let start: Date

    var body: some View {
        // WidgetKit advances this text from the persisted start while the app is suspended.
        Text(timerInterval: start ... Date.distantFuture, countsDown: false, showsHours: true)
            .monospacedDigit()
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .accessibilityLabel("Продолжительность")
            .accessibilityValue(Text(timerInterval: start ... Date.distantFuture, countsDown: false, showsHours: true))
    }
}

private struct CareActivityControls: View {
    let attributes: CareActivityAttributes
    let state: CareActivityAttributes.ContentState
    var island = true

    private var controlTint: Color {
        island ? state.islandAccent : Color("AccentColor")
    }

    var body: some View {
        HStack(spacing: 12) {
            if state.kind == .breast, let side = state.side {
                Button(intent: SwitchCareSideIntent(
                    eventID: attributes.eventID.uuidString, babyID: attributes.babyID.uuidString,
                    side: side == .left ? "right" : "left"
                )) {
                    Label(side == .left ? "На правую" : "На левую", systemImage: "arrow.left.arrow.right")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(controlTint)
                .accessibilityLabel(side == .left ? "Переключить на правую грудь" : "Переключить на левую грудь")
            }
            Button(intent: FinishCareActivityIntent(
                eventID: attributes.eventID.uuidString, babyID: attributes.babyID.uuidString
            )) {
                Label("Завершить", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(controlTint)
            .foregroundStyle(island ? Color.black : Color(uiColor: .systemBackground))
            .accessibilityLabel(state.kind == .breast ? "Завершить кормление" : "Завершить сон")
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

private extension CareActivityAttributes.ContentState {
    var title: String {
        kind == .breast ? "Кормление" : "Сон"
    }

    var symbol: String {
        kind == .breast ? "heart.fill" : "moon.zzz.fill"
    }

    var surfaceColor: Color {
        Color(kind == .breast ? "Feeding" : "Sleep")
    }

    var islandAccent: Color {
        // The Island is always black. Reuse the light asset variant for legible contrast.
        let color = UIColor(named: kind == .breast ? "Feeding" : "Sleep") ?? .label
        return Color(uiColor: color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
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
