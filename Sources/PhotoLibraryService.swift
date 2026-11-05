import Foundation
import Photos
import Synchronization

@MainActor
protocol PhotoLibraryWriting {
    func saveOriginal(_ data: Data, capturedAt: Date, requestPermission: Bool) async throws -> String
    func authorizeAdding() async -> Bool
}

extension PhotoLibraryWriting {
    func authorizeAdding() async -> Bool {
        false
    }
}

enum PhotoFailure: LocalizedError, Equatable {
    case permission, invalidImage, unknownWrite, missingAuthor, storageFull, missingDate
    var errorDescription: String? {
        switch self {
        case .permission: "Разрешите добавление фотографий в настройках iPhone."
        case .invalidImage: "Не удалось прочитать фотографию."
        case .unknownWrite: "Сохранение в Фото было прервано. Проверьте медиатеку: повторное сохранение остановлено, чтобы избежать дубликата."
        case .missingDate: "У фотографии нет доступной даты съёмки. Выберите дату перед добавлением."
        case .storageFull: "Недостаточно места для новых снимков. Завершите сохранение ожидающих фотографий и повторите."
        case .missingAuthor: "Не удалось определить автора фотографии. Повторите после загрузки дневника."
        }
    }
}

@MainActor
final class PhotoLibraryService: PhotoLibraryWriting {
    func authorizeAdding() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    func saveOriginal(_ data: Data, capturedAt: Date, requestPermission: Bool) async throws -> String {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined, requestPermission {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else { throw PhotoFailure.permission }
        // The resource is passed unchanged; Photos receives the camera original.
        let identifier = PhotoAssetIdentifier()
        try await PHPhotoLibrary.shared().performChanges(Self.creationChanges(
            data: data,
            capturedAt: capturedAt,
            identifier: identifier
        ))
        guard let value = identifier.value else { throw PhotoFailure.unknownWrite }
        return value
    }

    /// PhotoKit executes changes on its transaction queue. Build this closure outside
    /// MainActor isolation so the runtime never expects the main executor here.
    private nonisolated static func creationChanges(
        data: Data,
        capturedAt: Date,
        identifier: PhotoAssetIdentifier
    ) -> @Sendable () -> Void {
        {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = capturedAt
            request.addResource(with: .photo, data: data, options: nil)
            identifier.set(request.placeholderForCreatedAsset?.localIdentifier)
        }
    }
}

private final class PhotoAssetIdentifier: Sendable {
    private let storage = Mutex<String?>(nil)
    var value: String? {
        storage.withLock { $0 }
    }

    func set(_ value: String?) {
        storage.withLock { $0 = value }
    }
}
