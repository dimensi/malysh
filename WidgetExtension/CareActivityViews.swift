import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct CareActivityIslandHeading: View {
    let state: CareActivityAttributes.ContentState

    var body: some View {
        Label {
            Text(state.title)
        } icon: {
            Image(systemName: state.symbol)
                .foregroundStyle(state.islandAccent)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// Keeps independently laid out Island regions on a shared, Dynamic Type-scaled row.
struct CareActivityIslandHeaderCell<Content: View>: View {
    @ScaledMetric(relativeTo: .title2) private var minimumHeight = 32
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.frame(minHeight: minimumHeight, alignment: .center)
    }
}

struct CareActivityIslandActions: View {
    let attributes: CareActivityAttributes
    let state: CareActivityAttributes.ContentState
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 4) {
                sideLabel
                CareActivityControls(attributes: attributes, state: state, island: true)
            }
        } else if state.kind == .breast {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    sideLabel.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    CareActivityControls(attributes: attributes, state: state, island: true)
                        .fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 0) {
                    sideLabel.fixedSize(horizontal: true, vertical: false)
                    CareActivityControls(attributes: attributes, state: state, island: true)
                        .fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 0) {
                    sideLabel.fixedSize(horizontal: true, vertical: false)
                    CareActivityControls(attributes: attributes, state: state, island: true, stackIslandButtons: true)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        } else {
            CareActivityControls(attributes: attributes, state: state, island: true)
                .padding(.horizontal, 50)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var sideLabel: some View {
        if state.kind == .breast, let side = state.side {
            Text("\(side.label) грудь")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .contentTransition(.opacity)
                .animation(reduceMotion || isLuminanceReduced ? nil : .easeInOut(duration: 0.2), value: state.side)
        }
    }
}

struct CareActivityLockScreen: View {
    let attributes: CareActivityAttributes
    let state: CareActivityAttributes.ContentState
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if state.end != nil {
                finishedContent
            } else if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    activityInformation
                    CareActivityControls(attributes: attributes, state: state, island: false)
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    activityInformation
                    Spacer(minLength: 0)
                    CareActivityControls(attributes: attributes, state: state, island: false)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(16)
    }

    private var activityInformation: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(state.title, systemImage: state.symbol)
                .font(.headline)
            CareActivityTimer(start: state.start)
                .font(.title.weight(.semibold))
            if state.kind == .breast {
                Text(state.side.map { "\(state.babyName) · \($0.label) грудь" } ?? state.babyName)
                    .font(.caption.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(state.babyName) · Идёт сон")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var finishedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(state.kind == .breast ? "Кормление завершено" : "Сон завершён", systemImage: state.symbol)
                .font(.headline)
            Text(state.babyName)
                .font(.caption)
            if let end = state.end {
                CareActivityTimer(start: state.start, end: end)
                    .font(.title2.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CareActivityTimer: View {
    let start: Date
    var end: Date?
    var alignment: TextAlignment = .leading

    var body: some View {
        Group {
            if let end {
                Text(Self.finishedDuration(from: start, to: end))
            } else {
                // WidgetKit advances this text while the app is suspended.
                Text(timerInterval: start ... Date.distantFuture, countsDown: false, showsHours: true)
                    .multilineTextAlignment(alignment)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityLabel("Продолжительность")
        .accessibilityValue(accessibilityDuration)
    }

    private var accessibilityDuration: Text {
        if let end {
            Text(Self.finishedDuration(from: start, to: end))
        } else {
            Text(timerInterval: start ... Date.distantFuture, countsDown: false, showsHours: true)
        }
    }

    private static func finishedDuration(from start: Date, to end: Date) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(0, end.timeIntervalSince(start))) ?? "0 сек."
    }
}

struct CareActivityControls: View {
    let attributes: CareActivityAttributes
    let state: CareActivityAttributes.ContentState
    var island: Bool
    var stackIslandButtons = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if island, state.kind == .breast, typeSize.isAccessibilitySize || stackIslandButtons {
                VStack(spacing: 0) { islandButtons }
            } else if island {
                HStack(spacing: 8) { islandButtons }
            } else {
                VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 6) { lockScreenButtons }
            }
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder private var islandButtons: some View {
        if state.kind == .breast, let side = state.side {
            Button(intent: SwitchCareSideIntent(
                eventID: attributes.eventID.uuidString, babyID: attributes.babyID.uuidString,
                side: side == .left ? "right" : "left"
            )) {
                islandLabel("Сменить", symbol: "arrow.left.arrow.right", prominent: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(side == .left ? "Переключить на правую грудь" : "Переключить на левую грудь")
        }
        Button(intent: FinishCareActivityIntent(
            eventID: attributes.eventID.uuidString, babyID: attributes.babyID.uuidString
        )) {
            islandLabel("Завершить", symbol: "stop.fill", prominent: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.kind == .breast ? "Завершить кормление" : "Завершить сон")
    }

    private func islandLabel(_ title: String, symbol: String, prominent: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(state.kind == .sleep ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: state.kind == .sleep ? .infinity : nil, minHeight: 38)
            .background(prominent ? state.islandAccent : Color.white.opacity(0.18), in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder private var lockScreenButtons: some View {
        if state.kind == .breast, let side = state.side {
            Button(intent: SwitchCareSideIntent(
                eventID: attributes.eventID.uuidString, babyID: attributes.babyID.uuidString,
                side: side == .left ? "right" : "left"
            )) {
                Label("Сменить", systemImage: "arrow.left.arrow.right")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .accessibilityLabel(side == .left ? "Переключить на правую грудь" : "Переключить на левую грудь")
        }
        Button(intent: FinishCareActivityIntent(
            eventID: attributes.eventID.uuidString, babyID: attributes.babyID.uuidString
        )) {
            Label("Завершить", systemImage: "stop.fill")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(state.islandAccent)
        .foregroundStyle(.black)
        .accessibilityLabel(state.kind == .breast ? "Завершить кормление" : "Завершить сон")
    }
}

extension CareActivityAttributes.ContentState {
    var title: String {
        kind == .breast ? "Кормление" : "Сон"
    }

    var symbol: String {
        kind == .breast ? "drop.fill" : "moon.zzz.fill"
    }

    var surfaceColor: Color {
        Color(kind == .breast ? "ActivityFeeding" : "Sleep")
    }

    var islandAccent: Color {
        // The Island is always black. Use the light asset variant for legible contrast.
        let color = UIColor(named: kind == .breast ? "ActivityFeeding" : "Sleep") ?? .label
        return Color(uiColor: color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
    }
}
