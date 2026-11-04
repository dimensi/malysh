import SwiftUI

struct ActionTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.cardContent) {
                Image(systemName: symbol).font(.title2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                    Text(title).font(AppDesign.Typography.itemTitle)
                    Text(subtitle).font(AppDesign.Typography.note).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.actionMinimumHeight, alignment: .leading)
            .foregroundStyle(AppDesign.Palette.primaryText)
            .diaryCard(color: color, inset: AppDesign.Spacing.actionInset)
            .contentShape(RoundedRectangle(cornerRadius: AppDesign.Radius.card))
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

struct EventRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let event: CareEvent
    let authorLabel: String?
    let action: () -> Void

    init(event: CareEvent, authorLabel: String? = nil, action: @escaping () -> Void) {
        self.event = event
        self.authorLabel = authorLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
                        Label(event.kind.label, systemImage: event.kind.symbol).font(AppDesign.Typography.itemTitle)
                        Text(event.detail).font(AppDesign.Typography.detail).foregroundStyle(.secondary)
                        Text(event.start, format: .dateTime.hour().minute())
                            .font(AppDesign.Typography.detail).monospacedDigit()
                        if !event.note.isEmpty {
                            Text(event.note).font(AppDesign.Typography.note).foregroundStyle(.secondary)
                        }
                        if let authorLabel, !authorLabel.isEmpty {
                            Text(authorLabel).font(AppDesign.Typography.note).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .center, spacing: AppDesign.Spacing.row) {
                        Image(systemName: event.kind.symbol).font(.title3)
                            .frame(width: AppDesign.Metrics.minimumTouch, height: AppDesign.Metrics.minimumTouch)
                            .background(event.kind.tint, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                            Text(event.kind.label).font(AppDesign.Typography.itemTitle)
                            Text(event.detail).font(AppDesign.Typography.detail).foregroundStyle(.secondary)
                            if !event.note.isEmpty {
                                Text(event.note).font(AppDesign.Typography.note).foregroundStyle(.secondary)
                            }
                            if let authorLabel, !authorLabel.isEmpty {
                                Text(authorLabel).font(AppDesign.Typography.note).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: AppDesign.Spacing.related)
                        Text(event.start, format: .dateTime.hour().minute())
                            .font(AppDesign.Typography.detail).monospacedDigit()
                    }.frame(minHeight: 56).foregroundStyle(AppDesign.Palette.primaryText).contentShape(Rectangle())
                }
            }.foregroundStyle(AppDesign.Palette.primaryText).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("event.\(event.id.uuidString)")
        .accessibilityElement(children: .combine).accessibilityHint("Открыть запись")
    }
}
