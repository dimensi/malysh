import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct CareActivityIslandHeading: View {
    let title: String
    let appearance: CareActivityAppearance

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: appearance.symbol)
                .foregroundStyle(appearance.islandAccent)
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
    var body: some View {
        Group {
            if state.end != nil {
                finishedContent
            } else {
                CareActivityLockScreenRow {
                    activityInformation
                } actions: {
                    CareActivityControls(attributes: attributes, state: state, island: false)
                }
            }
        }
        .modifier(CareActivityLockScreenInsets())
    }

    private var activityInformation: some View {
        CareActivityInformation(title: state.title, appearance: state.appearance) {
            CareActivityTimer(start: state.start)
        } subtitle: {
            if state.kind == .breast {
                Text(state.side.map { "\(state.babyName) · \($0.label) грудь" } ?? state.babyName)
                    .font(.caption.weight(.medium))
            } else {
                Text("\(state.babyName) · Идёт сон")
                    .font(.caption)
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

struct CareActivityLockScreenInsets: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(.primary).padding(16)
    }
}

struct CareActivityLockScreenRow<Information: View, Actions: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var allowsStackingForWidth = false
    @ViewBuilder let information: () -> Information
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else if allowsStackingForWidth {
            ViewThatFits(in: .horizontal) {
                horizontal.fixedSize(horizontal: true, vertical: false)
                stacked
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            horizontal
        }
    }

    private var horizontal: some View {
        HStack(alignment: .center, spacing: 12) {
            information()
            Spacer(minLength: 0)
            actions()
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 8) {
            information()
            actions()
        }
    }
}

struct CareActivityInformation<Metric: View, Subtitle: View>: View {
    let title: String
    let appearance: CareActivityAppearance
    @ViewBuilder let metric: () -> Metric
    @ViewBuilder let subtitle: () -> Subtitle

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: appearance.symbol)
                .font(.headline)
            metric().font(.title.weight(.semibold))
            subtitle().fixedSize(horizontal: false, vertical: true)
        }
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
                VStack(spacing: 0) { buttons }
            } else if island {
                HStack(spacing: 8) { buttons }
            } else {
                VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 6) { buttons }
            }
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder private var buttons: some View {
        if state.kind == .breast, let side = state.side {
            CareActivityIntentButton(
                intent: SwitchCareSideIntent(
                    eventID: attributes.eventID.uuidString, babyID: attributes.babyID.uuidString,
                    side: side == .left ? "right" : "left"
                ),
                title: "Сменить", symbol: "arrow.left.arrow.right", appearance: state.appearance,
                island: island, prominent: false
            )
            .accessibilityLabel(side == .left ? "Переключить на правую грудь" : "Переключить на левую грудь")
        }
        CareActivityIntentButton(
            intent: FinishCareActivityIntent(
                eventID: attributes.eventID.uuidString,
                babyID: attributes.babyID.uuidString
            ),
            title: "Завершить", symbol: "stop.fill", appearance: state.appearance,
            island: island, prominent: true
        )
        .accessibilityLabel(state.kind == .breast ? "Завершить кормление" : "Завершить сон")
    }
}

struct CareActivityIntentButton<Action: AppIntent>: View {
    let intent: Action
    let title: LocalizedStringKey
    var symbol: String?
    let appearance: CareActivityAppearance
    let island: Bool
    let prominent: Bool

    var body: some View {
        if island {
            Button(intent: intent) {
                label
                    .font(appearance == .sleep ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(prominent ? Color.black : Color.white)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: appearance == .sleep ? .infinity : nil, minHeight: 38)
                    .background(prominent ? appearance.islandAccent : Color.white.opacity(0.18), in: Capsule())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if prominent {
            Button(intent: intent) { lockScreenLabel }
                .buttonStyle(.borderedProminent)
                .tint(appearance.islandAccent)
                .foregroundStyle(.black)
        } else {
            Button(intent: intent) { lockScreenLabel }
                .buttonStyle(.bordered)
                .tint(.primary)
        }
    }

    private var lockScreenLabel: some View {
        label.frame(minWidth: 44, minHeight: 44)
    }

    @ViewBuilder private var label: some View {
        if let symbol {
            Label(title, systemImage: symbol)
        } else {
            Text(title)
        }
    }
}

enum CareActivityAppearance {
    case feeding, sleep

    static let islandHeaderInset: CGFloat = 26
    static let islandExpandedInset: CGFloat = 16

    var symbol: String {
        self == .feeding ? "drop.fill" : "moon.zzz.fill"
    }

    var surfaceColor: Color {
        Color(assetName)
    }

    var islandAccent: Color {
        // The Island is always black. Use the light asset variant for legible contrast.
        let color = UIColor(named: assetName) ?? .label
        return Color(uiColor: color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
    }

    private var assetName: String {
        self == .feeding ? "ActivityFeeding" : "Sleep"
    }
}

struct CareActivityIslandIcon: View {
    let title: String
    let appearance: CareActivityAppearance

    var body: some View {
        Image(systemName: appearance.symbol)
            .foregroundStyle(appearance.islandAccent)
            .accessibilityLabel(title)
    }
}

extension CareActivityAttributes.ContentState {
    var title: String {
        kind == .breast ? "Кормление" : "Сон"
    }

    var appearance: CareActivityAppearance {
        kind == .breast ? .feeding : .sleep
    }

    var symbol: String {
        appearance.symbol
    }
}
