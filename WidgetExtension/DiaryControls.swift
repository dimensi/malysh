import AppIntents
import SwiftUI
import WidgetKit

/// Values are captured when WidgetKit renders the control. They never resolve a
/// different selected diary at tap time; the app validates this identity again.
struct DiaryControlValueProvider: ControlValueProvider {
    var previewValue: WidgetSnapshot? {
        WidgetSnapshot(baby: Baby(name: "Малыш"), events: [], generatedAt: .now)
    }

    func currentValue() async throws -> WidgetSnapshot? {
        try WidgetSnapshotStore().read()
    }
}

struct WetDiaperControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "Malysh.control.wet", provider: DiaryControlValueProvider()) { snapshot in
            ControlWidgetButton(action: WidgetCareIntent(
                babyID: snapshot?.babyID ?? Self.unavailableID,
                commandID: snapshot?.commandID(for: .wetDiaper) ?? Self.unavailableID,
                action: .wetDiaper
            )) {
                Label(snapshot?.babyID == nil ? "Нет дневника" : "Мокрый подгузник", systemImage: "drop.fill")
            }
        }
        .displayName("Мокрый подгузник")
        .description("Записать мокрый подгузник в выбранный дневник.")
    }

    static let unavailableID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

struct SleepCareControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "Malysh.control.sleep", provider: DiaryControlValueProvider()) { snapshot in
            ControlWidgetButton(action: SleepCareControlIntent(
                babyID: snapshot?.babyID ?? WetDiaperControl.unavailableID,
                commandID: snapshot?.commandID(for: .startSleep) ?? WetDiaperControl.unavailableID,
                eventID: snapshot?.activeEvents.first(where: { $0.kind == .sleep })?.id
            )) {
                Label(snapshot?.babyID == nil ? "Нет дневника" :
                    snapshot?.activeEvents
                    .contains(where: { $0.kind == .sleep }) == true ? "Завершить сон" : "Начать сон",
                    systemImage: snapshot?.activeEvents
                        .contains(where: { $0.kind == .sleep }) == true ? "stop.fill" : "moon.zzz.fill")
            }
        }
        .displayName("Сон малыша")
        .description("Начать сон или завершить показанный таймер.")
    }
}
