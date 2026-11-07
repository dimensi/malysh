import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct CareActivityIslandTimerRow: View {
    enum Region {
        case controls, timer, accessibility
    }

    let region: Region
    let attributes: CareActivityAttributes
    let state: CareActivityAttributes.ContentState
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        switch region {
        case .controls:
            if !typeSize.isAccessibilitySize, state.end == nil {
                controls
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 5)
                    .frame(minHeight: 52)
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
            }
        case .timer:
            if !typeSize.isAccessibilitySize {
                timer(alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, AppDesign.Spacing.row)
                    .frame(minHeight: 52)
            }
        case .accessibility:
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
                    timer(alignment: .leading)
                    controls
                }
                .padding(.horizontal, AppDesign.Spacing.group)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if state.end == nil {
            CareActivityControls(attributes: attributes, state: state)
        }
    }

    private func timer(alignment: TextAlignment) -> some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 2) {
            CareActivityTimer(start: state.start, end: state.end, alignment: alignment)
                .font(.title.weight(.semibold))
                .foregroundStyle(state.appearance.islandAccent)
            if let subtitle = state.subtitle {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(alignment)
                    .contentTransition(.opacity)
                    .animation(reduceMotion || isLuminanceReduced ? nil : .easeInOut(duration: 0.2), value: state.side)
            }
        }
    }
}

struct CareActivityLockScreen: View {
    let attributes: CareActivityAttributes
    let state: CareActivityAttributes.ContentState

    var body: some View {
        CareActivityLockScreenRow(stacksAtAccessibilitySize: state.kind == .breast) {
            HStack(spacing: AppDesign.Spacing.row) {
                CareActivityBrandMark()
                information
            }
        } actions: {
            if state.end == nil {
                CareActivityControls(attributes: attributes, state: state)
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
            if let subtitle = state.subtitle {
                Text(subtitle)
                    .font(AppDesign.Typography.note.weight(.medium))
                    .foregroundStyle(state.kind == .breast ? Color.white.opacity(0.72) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct CareActivityLockScreenRow<Information: View, Actions: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let stacksAtAccessibilitySize: Bool
    @ViewBuilder let information: () -> Information
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        if typeSize >= .accessibility4 || (stacksAtAccessibilitySize && typeSize.isAccessibilitySize) {
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
    var body: some View {
        HStack(spacing: AppDesign.Spacing.group) {
            if state.kind == .breast, let side = state.side {
                CareActivityCircleButton(
                    intent: SwitchCareSideIntent(
                        eventID: attributes.eventID.uuidString, babyID: attributes.babyID.uuidString,
                        side: side == .left ? "right" : "left"
                    ),
                    prominent: false
                ) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .accessibilityLabel(side == .left ? "Переключить на правую грудь" : "Переключить на левую грудь")
            }
            CareActivityCircleButton(
                intent: FinishCareActivityIntent(
                    eventID: attributes.eventID.uuidString,
                    babyID: attributes.babyID.uuidString
                ),
                prominent: true, accent: state.appearance.islandAccent
            ) {
                Image(systemName: "stop.fill")
            }
            .accessibilityLabel(state.kind == .breast ? "Завершить кормление" : "Завершить сон")
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
    var subtitle: String? {
        if kind == .sleep {
            return end == nil ? "Идёт сон" : "Сон завершён"
        }
        if end != nil {
            return "Кормление завершено"
        }
        return side.map { "\($0.label) грудь" }
    }

    var title: String {
        kind == .breast ? "Кормление" : "Сон"
    }

    var appearance: CareActivityAppearance {
        kind == .breast ? .feeding : .sleep
    }
}
