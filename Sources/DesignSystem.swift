import SwiftUI

/// Shared presentation values from the existing iPhone interface.
/// Native forms, alerts, sheets and system typography keep their platform behavior.
enum AppDesign {
    enum Palette {
        static let accent = Color("AccentColor")
        static let onAccent = Color("OnAccent")
        static let feeding = Color("Feeding")
        static let diaper = Color("Diaper")
        static let sleep = Color("Sleep")
        static let groupedBackground = Color(uiColor: .systemGroupedBackground)
        static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
        static let primaryText = Color.primary
        static let secondaryText = Color.secondary
        static let error = Color.red
        static let success = Color.green
        static let chartFeeding = Color.orange
        static let chartDiaper = Color.blue
        static let chartSleep = Color.purple
    }

    enum Spacing {
        static let related: CGFloat = 4
        static let group: CGFloat = 8
        static let cardContent: CGFloat = 10
        static let row: CGFloat = 12
        static let actionInset: CGFloat = 16
        static let contentInset: CGFloat = 20
        static let section: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 20
    }

    enum Metrics {
        static let brandMarkSize: CGFloat = 48
        static let brandMarkCornerRadius: CGFloat = 14
        static let minimumTouch: CGFloat = 44
        static let actionMinimumHeight: CGFloat = 112
    }

    enum Typography {
        static let itemTitle = Font.headline
        static let detail = Font.subheadline
        static let note = Font.caption
    }
}

private struct DiaryCardStyle: ViewModifier {
    let color: Color
    let inset: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(inset)
            .background(color, in: RoundedRectangle(cornerRadius: AppDesign.Radius.card))
    }
}

extension View {
    /// Existing care-card surface; action tiles retain their smaller content inset.
    func diaryCard(color: Color, inset: CGFloat = AppDesign.Spacing.contentInset) -> some View {
        modifier(DiaryCardStyle(color: color, inset: inset))
    }
}
