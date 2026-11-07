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
        CareActivityLockScreenRow {
            HStack(spacing: AppDesign.Spacing.row) {
                CareActivityBrandMark()
                information
            }
        } actions: {
            if state.end == nil {
                CareActivityControls(attributes: attributes, state: state, island: false)
            }
        }
        .foregroundStyle(state.kind == .breast ? Color.white : .primary)
        .padding(14)
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
            Text("\(state.babyName) · \(state.title)")
                .font(AppDesign.Typography.detail.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            CareActivityTimer(start: state.start, end: state.end)
                .font(.largeTitle.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(AppDesign.Typography.note.weight(.medium))
                    .foregroundStyle(state.kind == .breast ? Color.white.opacity(0.72) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subtitle: String? {
        if state.kind == .sleep {
            return state.end == nil ? "Идёт сон" : "Сон завершён"
        }
        if state.end != nil {
            return "Кормление завершено"
        }
        return state.side.map { "\($0.label) грудь" }
    }
}

struct CareActivityLockScreenRow<Information: View, Actions: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let information: () -> Information
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else {
            horizontal
        }
    }

    private var horizontal: some View {
        HStack(alignment: .center, spacing: 12) {
            information()
            Spacer(minLength: 0)
            actions()
                .layoutPriority(1)
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 8) {
            information()
            actions()
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
                VStack(spacing: 0) { buttons }
            } else {
                HStack(spacing: 8) { buttons }
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
        } else {
            CareActivityCircleButton(intent: intent, prominent: prominent, accent: appearance.islandAccent) {
                Image(systemName: symbol ?? "stop.fill")
            }
        }
    }

    @ViewBuilder private var label: some View {
        if let symbol {
            Label(title, systemImage: symbol)
        } else {
            Text(title)
        }
    }
}

struct CareActivityBrandMark: View {
    var body: some View {
        Image("ActivityBrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: AppDesign.Metrics.brandMarkSize, height: AppDesign.Metrics.brandMarkSize)
            .clipShape(.rect(cornerRadius: AppDesign.Metrics.brandMarkCornerRadius))
            .accessibilityHidden(true)
    }
}

struct CareActivityCircleButton<Action: AppIntent, Glyph: View>: View {
    let intent: Action
    let prominent: Bool
    var diameter = AppDesign.Metrics.minimumTouch
    var accent = CareActivityAppearance.feeding.islandAccent
    @ViewBuilder let label: () -> Glyph

    var body: some View {
        let size = max(diameter, AppDesign.Metrics.minimumTouch)
        Button(intent: intent) {
            label()
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .frame(width: size, height: size)
                .background(
                    prominent ? accent : .white.opacity(0.15),
                    in: Circle()
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum CareActivityAppearance {
    case feeding, sleep

    static let islandHeaderInset: CGFloat = 26
    static let islandExpandedInset: CGFloat = 16
    static let feedingLockScreenSurface = Color("ActivityFeedingLockScreen")

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
}
