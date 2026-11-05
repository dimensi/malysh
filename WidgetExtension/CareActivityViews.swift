import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The system's center region starts below the TrueDepth camera, so information
/// never sits beside the camera or the physical display's rounded top corners.
struct CareActivityIslandInfo: View {
    let state: CareActivityAttributes.ContentState
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.symbol).resizable().scaledToFit().frame(width: 18, height: 18)
                .foregroundStyle(state.islandAccent).accessibilityHidden(true)
            Text(state.kind == .breast ? (state.side?.label ?? "Кормление") : "Сон")
                .font(typeSize.isAccessibilitySize ? .caption2 : .caption)
                .accessibilityLabel(state.kind == .breast ? "\(state.side?.label ?? "") грудь" : "Малыш спит")
            Spacer(minLength: 4)
            CareActivityTimer(start: state.start)
                .font(typeSize.isAccessibilitySize ? .caption2.bold() : .title2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct CareActivityTimer: View {
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

struct CareActivityControls: View {
    let attributes: CareActivityAttributes
    let state: CareActivityAttributes.ContentState
    var island = true
    @Environment(\.dynamicTypeSize) private var typeSize

    private var controlTint: Color {
        island ? state.islandAccent : Color("AccentColor")
    }

    var body: some View {
        HStack(spacing: 8) {
            if state.kind == .breast, let side = state.side {
                Button(intent: SwitchCareSideIntent(
                    eventID: attributes.eventID.uuidString, babyID: attributes.babyID.uuidString,
                    side: side == .left ? "right" : "left"
                )) {
                    controlLabel(island ? "Сменить" : (side == .left ? "На правую" : "На левую"),
                                 symbol: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .tint(controlTint)
                .accessibilityLabel(side == .left ? "Переключить на правую грудь" : "Переключить на левую грудь")
            }
            Button(intent: FinishCareActivityIntent(
                eventID: attributes.eventID.uuidString, babyID: attributes.babyID.uuidString
            )) {
                controlLabel(island ? "Стоп" : "Завершить", symbol: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .tint(controlTint)
            .foregroundStyle(island ? Color.black : Color(uiColor: .systemBackground))
            .accessibilityLabel(state.kind == .breast ? "Завершить кормление" : "Завершить сон")
        }
        .font(island ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
    }

    private func controlLabel(_ title: String, symbol: String) -> some View {
        Group {
            if island, typeSize.isAccessibilitySize {
                Image(systemName: symbol).resizable().scaledToFit().frame(width: 20, height: 20)
            } else {
                Label(title, systemImage: symbol)
            }
        }.frame(maxWidth: .infinity, minHeight: island ? 28 : 44)
    }
}

extension CareActivityAttributes.ContentState {
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
