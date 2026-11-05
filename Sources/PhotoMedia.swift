import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PhotoMedia: Sendable {
    let image: Data
    let thumbnail: Data
    let width: Int
    let height: Int
    let capturedAt: Date

    static func prepare(_ data: Data, fallbackDate: Date? = nil) throws -> PhotoMedia {
        guard data.count <= 100_000_000, let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw PhotoFailure.invalidImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let rawDate = exif?[kCGImagePropertyExifDateTimeOriginal] as? String ??
            tiff?[kCGImagePropertyTIFFDateTime] as? String
        var date = rawDate.flatMap(formatter.date(from:)) ?? fallbackDate ?? Date()
        if let rawDate, let offset = exif?["OffsetTimeOriginal" as CFString] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
            date = formatter.date(from: rawDate + offset) ?? date
        }
        if let fraction = exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String,
           let subseconds = Double("0." + fraction)
        {
            date.addTimeInterval(subseconds)
        }
        struct Rendered {
            let data: Data
            let size: CGSize
        }
        func render(edge: Int, quality: Double) throws -> Rendered {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: edge,
                                            kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { throw PhotoFailure.invalidImage }
            let result = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1,
                                                                     nil) else { throw PhotoFailure.invalidImage }
            // Only pixels and compression are copied: GPS and source EXIF never enter the family copy.
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { throw PhotoFailure.invalidImage }
            return Rendered(data: result as Data, size: CGSize(width: image.width, height: image.height))
        }
        var full = try render(edge: 2048, quality: 0.82)
        if full.data.count > 3_000_000 {
            full = try render(edge: 1600, quality: 0.65)
        }
        guard full.data.count <= 3_000_000 else { throw PhotoFailure.invalidImage }
        let thumb = try render(edge: 400, quality: 0.7)
        return PhotoMedia(
            image: full.data,
            thumbnail: thumb.data,
            width: properties?[kCGImagePropertyPixelWidth] as? Int ?? Int(full.size.width),
            height: properties?[kCGImagePropertyPixelHeight] as? Int ?? Int(full.size.height),
            capturedAt: date
        )
    }
}
