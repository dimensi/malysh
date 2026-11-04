@preconcurrency import CloudKit
@preconcurrency import CoreData
import SwiftUI
import UIKit

/// Presentation-only identities; never persist this snapshot or display its internal IDs.
struct FamilyMember: Identifiable, Equatable {
    let id: String
    let name: String
    let role: String
    let status: String
    let isCurrentUser: Bool
    let isOwner: Bool
    let canEdit: Bool

    init(id: String, name: String, role: String, status: String, isCurrentUser: Bool,
         isOwner: Bool = false, canEdit: Bool = true)
    {
        self.id = id
        self.name = name
        self.role = role
        self.status = status
        self.isCurrentUser = isCurrentUser
        self.isOwner = isOwner
        self.canEdit = canEdit
    }

    static func make(
        id: String,
        nameComponents: PersonNameComponents?,
        isOwner: Bool,
        acceptanceStatus: CKShare.ParticipantAcceptanceStatus,
        isCurrentUser: Bool,
        profile: ParentProfile? = nil,
        canEdit: Bool = true
    ) -> FamilyMember {
        let formattedName = nameComponents.map {
            PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        let status = switch acceptanceStatus {
        case .accepted: "В семье"
        case .pending: "Приглашение отправлено"
        case .removed: "Доступ прекращён"
        case .unknown: "Статус пока неизвестен"
        @unknown default: "Статус пока неизвестен"
        }
        return FamilyMember(
            id: id,
            name: profile.flatMap { $0.name.isEmpty ? nil : $0.name } ?? formattedName,
            role: profile?.role.label ?? ParentRole.parent.label,
            status: status,
            isCurrentUser: isCurrentUser,
            isOwner: isOwner,
            canEdit: canEdit
        )
    }
}

struct FamilySnapshot {
    let isOwner: Bool
    let members: [FamilyMember]
}

extension Persistence {
    /// Reads Core Data's locally maintained share, including while offline.
    func familySnapshot(babyID: UUID) throws -> FamilySnapshot? {
        guard let baby = try babyObject(id: babyID) else { throw Failure.missingBaby }
        guard let share = try container.fetchShares(matching: [baby.objectID])[baby.objectID] else { return nil }
        let profiles = try babies().first { $0.id == babyID }?.parentProfiles ?? [:]
        let owner = share.owner
        let current = share.currentUserParticipant
        let isOwner: Bool = if let current {
            current.role == .owner || current.isEqual(owner)
        } else {
            // A share in this user's private store belongs to them. A shared store
            // proves they are a participant, but does not identify which participant.
            privateStore != nil && baby.objectID.persistentStore == privateStore
        }
        var participants = [owner]
        for participant in share.participants {
            guard participant.role != .owner,
                  !participants.contains(where: { $0.isEqual(participant) }) else { continue }
            participants.append(participant)
        }
        if let current, !isOwner, !participants.contains(where: { $0.isEqual(current) }) {
            participants.append(current)
        }
        let members = participants.enumerated().map { index, participant in
            let participantIsOwner = index == 0
            let isCurrent = (participantIsOwner && isOwner) || (current.map { participant.isEqual($0) } ?? false)
            // Owner is stable within this diary; other profiles use CloudKit's user identity,
            // never participant array order, email addresses or contact names.
            let recordName = participant.userIdentity.userRecordID?.recordName
            let stableIdentity = recordName.flatMap { $0.isEmpty || $0 == CKCurrentUserDefaultName ? nil : $0 }
            let identity = participantIsOwner ? "owner" : stableIdentity.map { "user-\($0)" } ?? "pending-\(index)"
            return FamilyMember.make(
                id: identity,
                nameComponents: participant.userIdentity.nameComponents,
                isOwner: participantIsOwner,
                acceptanceStatus: participant.acceptanceStatus,
                isCurrentUser: isCurrent,
                profile: profiles[identity],
                canEdit: participantIsOwner || stableIdentity != nil
            )
        }
        return FamilySnapshot(isOwner: isOwner, members: members)
    }

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
