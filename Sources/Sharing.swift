@preconcurrency import CloudKit
@preconcurrency import CoreData
import SwiftUI
import UIKit

extension Persistence {
    func share(babyID: UUID) async throws -> CKShare {
        guard cloudEnabled else { throw Failure.cloudDisabled }
        guard let baby = try babyObject(id: babyID) else { throw Failure.missingBaby }
        if let existing = try container.fetchShares(matching: [baby.objectID])[baby.objectID] {
            return existing
        }
        let share: CKShare = try await withCheckedThrowingContinuation { continuation in
            container.share([baby], to: nil) { _, share, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let share {
                    continuation.resume(returning: share)
                } else {
                    continuation.resume(throwing: Failure.missingStore)
                }
            }
        }
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = "Малыш" as CKRecordValue
        guard let store = baby.objectID.persistentStore else { throw Failure.missingStore }
        try await persist(share: share, in: store)
        return share
    }

    /// Call from the app/scene delegate after loading this persistence instance.
    func accept(metadata: CKShare.Metadata) async throws {
        guard cloudEnabled else { throw Failure.cloudDisabled }
        guard let sharedStore else { throw Failure.missingStore }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func persist(share: CKShare, in store: NSPersistentStore) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.persistUpdatedShare(share, in: store) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

extension Notification.Name {
    static let malyshSharingChanged = Notification.Name("Malysh.sharingChanged")
}

@MainActor
struct ShareSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    var onError: @MainActor (Error) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onError: onError)
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_: UICloudSharingController, context _: Context) {}

    @MainActor
    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onError: @MainActor (Error) -> Void
        init(onError: @escaping @MainActor (Error) -> Void) {
            self.onError = onError
        }

        func itemTitle(for _: UICloudSharingController) -> String? {
            "Дневник малыша"
        }

        func cloudSharingController(_: UICloudSharingController, failedToSaveShareWithError error: Error) {
            onError(error)
        }

        func cloudSharingControllerDidStopSharing(_: UICloudSharingController) {
            // iOS 17 automatically observes system sharing changes. Never purge the
            // owner's zone here: that API also deletes their original object graph.
            // Participant removal is imported by Core Data into the shared store.
            NotificationCenter.default.post(name: .malyshSharingChanged, object: nil)
        }

        func cloudSharingControllerDidSaveShare(_: UICloudSharingController) {
            // iOS 16.4+ Core Data already observes and imports system sharing UI saves.
            // Do not schedule a second export of the system UI's share changes.
            NotificationCenter.default.post(name: .malyshSharingChanged, object: nil)
        }
    }
}
