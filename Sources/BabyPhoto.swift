import Foundation

/// Metadata only. Image resources live in separate Core Data binary attributes keyed by id.
public struct BabyPhoto: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var babyID: UUID
    public var capturedAt: Date
    public var addedAt: Date
    public var addedBy: String
    public var mediaType: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var caption: String?
    public var isFavorite: Bool

    public init(id: UUID = UUID(), babyID: UUID, capturedAt: Date, addedAt: Date = Date(),
                addedBy: String, mediaType: String = "image", pixelWidth: Int, pixelHeight: Int,
                caption: String? = nil, isFavorite: Bool = false)
    {
        self.id = id
        self.babyID = babyID
        self.capturedAt = capturedAt
        self.addedAt = addedAt
        self.addedBy = addedBy
        self.mediaType = mediaType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.caption = caption
        self.isFavorite = isFavorite
    }

    public static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.capturedAt != rhs.capturedAt {
            return lhs.capturedAt > rhs.capturedAt
        }
        if lhs.addedAt != rhs.addedAt {
            return lhs.addedAt > rhs.addedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    public static func avatar(in photos: [Self], pinnedID: UUID?) -> Self? {
        if let pinnedID, let pinned = photos.first(where: { $0.id == pinnedID }) {
            return pinned
        }
        return photos.sorted(by: newestFirst).first
    }
}
