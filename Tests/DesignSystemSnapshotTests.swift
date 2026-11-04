@testable import Malysh
import SwiftUI
import UIKit
import XCTest

@MainActor
final class DesignSystemSnapshotTests: XCTestCase {
    private struct Variant {
        let appearance: String
        let colorScheme: ColorScheme
        let text: String
        let dynamicType: DynamicTypeSize
        var name: String {
            "gallery-\(appearance)-\(text)"
        }

        var height: CGFloat {
            dynamicType.isAccessibilitySize ? 2800 : 1700
        }
    }

    func testPixelComparatorDetectsDriftAndIgnoresRounding() throws {
        let red = try pixels(image([255, 0, 0, 255], width: 1, height: 1))
        let blue = try pixels(image([0, 0, 255, 255], width: 1, height: 1))
        let rounding = try pixels(image([250, 2, 2, 255], width: 1, height: 1))
        XCTAssertEqual(difference(red, blue).changed, 1, "A real color change must fail the comparison")
        XCTAssertEqual(difference(red, rounding).changed, 0, "Small channel rounding must be tolerated")
        XCTAssertEqual(difference(red, red).changed, 0)
    }

    func testGallerySnapshots() throws {
        let variants = [
            Variant(appearance: "light", colorScheme: .light, text: "large", dynamicType: .large),
            Variant(appearance: "dark", colorScheme: .dark, text: "large", dynamicType: .large),
            Variant(appearance: "light", colorScheme: .light, text: "accessibility3", dynamicType: .accessibility3),
            Variant(appearance: "dark", colorScheme: .dark, text: "accessibility3", dynamicType: .accessibility3),
        ]
        let system = "iOS-\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        let recording = ProcessInfo.processInfo.environment["RECORD_DESIGN_BASELINES"] == "1"
        for variant in variants {
            let actual = try render(variant)
            if recording {
                attach(actual, name: "design-baseline-\(system)-\(variant.name).png")
                continue
            }
            try compare(actual, variant: variant, system: system)
        }
        if recording {
            let metadata: [String: Any] = [
                "system": system,
                "osVersion": UIDevice.current.systemVersion,
                "scale": 1,
                "width": 402,
                "locale": "ru_RU",
                "timeZone": "GMT",
                "variants": variants.map(\.name),
                "requiresVisualApproval": true,
            ]
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "design-baseline-manifest.json"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw XCTSkip("Recorded four candidates for visual review; this is not a baseline comparison pass.")
        }
    }

    private func render(_ variant: Variant) throws -> UIImage {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let content = DesignSystemGallery()
            .frame(width: 402, height: variant.height, alignment: .topLeading)
            .background(AppDesign.Palette.groupedBackground)
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .environment(\.calendar, calendar)
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .environment(\.colorScheme, variant.colorScheme)
            .environment(\.dynamicTypeSize, variant.dynamicType)
            .transaction { $0.animation = nil }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 402, height: variant.height)
        return try XCTUnwrap(renderer.uiImage, "ImageRenderer did not produce the real component gallery")
    }

    private func compare(_ actual: UIImage, variant: Variant, system: String) throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: variant.name, withExtension: "png",
                                   subdirectory: "DesignBaselines/\(system)"),
            let expected = UIImage(contentsOfFile: url.path)
        else {
            attach(actual, name: "actual-\(system)-\(variant.name).png")
            XCTFail(
                "Missing approved DesignBaselines/\(system)/\(variant.name).png. Record explicitly, review, then commit."
            )
            return
        }
        let observed = try pixels(actual)
        let reference = try pixels(expected)
        guard observed.width == reference.width, observed.height == reference.height else {
            attach(actual, name: "actual-\(variant.name).png")
            attach(expected, name: "expected-\(variant.name).png")
            XCTFail("Snapshot dimensions changed for \(variant.name): \(observed.width)x\(observed.height) " +
                "vs \(reference.width)x\(reference.height)")
            return
        }
        let result = difference(observed, reference)
        // Ignore tiny channel rounding; more than 0.01% changed pixels is a visual regression.
        if result.ratio > 0.0001 {
            attach(actual, name: "actual-\(variant.name).png")
            attach(expected, name: "expected-\(variant.name).png")
            try attach(image(result.pixels, width: observed.width, height: observed.height),
                       name: "diff-\(variant.name).png")
            XCTFail("\(variant.name): \(result.changed) changed pixels (\(result.ratio * 100)%); " +
                "channel tolerance 8/255, maximum changed ratio 0.01%.")
        }
    }

    private struct Raster {
        let width: Int
        let height: Int
        var bytes: [UInt8]
    }

    private func pixels(_ image: UIImage) throws -> Raster {
        let cgImage = try XCTUnwrap(image.cgImage)
        var raster = Raster(width: cgImage.width, height: cgImage.height,
                            bytes: [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4))
        let width = raster.width
        let height = raster.height
        try raster.bytes.withUnsafeMutableBytes { buffer in
            let context = try bitmapContext(buffer.baseAddress, width: width, height: height)
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return raster
    }

    private func bitmapContext(_ data: UnsafeMutableRawPointer?, width: Int, height: Int) throws -> CGContext {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGContext(data: data, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                           CGBitmapInfo.byteOrder32Big.rawValue))
    }

    private struct Difference {
        let changed: Int
        let ratio: Double
        let pixels: [UInt8]
    }

    private func difference(_ actual: Raster, _ expected: Raster) -> Difference {
        var changed = 0
        var output = expected.bytes
        for offset in stride(from: 0, to: actual.bytes.count, by: 4) {
            let mismatch = (0 ..< 4)
                .contains { abs(Int(actual.bytes[offset + $0]) - Int(expected.bytes[offset + $0])) > 8 }
            if mismatch {
                changed += 1
                output[offset] = 255
                output[offset + 1] = 0
                output[offset + 2] = 80
            }
            output[offset + 3] = 255
        }
        return Difference(
            changed: changed,
            ratio: Double(changed) / Double(actual.width * actual.height),
            pixels: output
        )
    }

    private func image(_ bytes: [UInt8], width: Int, height: Int) throws -> UIImage {
        var copy = bytes
        return try copy.withUnsafeMutableBytes { buffer in
            let context = try bitmapContext(buffer.baseAddress, width: width, height: height)
            return try UIImage(cgImage: XCTUnwrap(context.makeImage()))
        }
    }

    private func attach(_ image: UIImage, name: String) {
        guard let data = image.pngData() else { XCTFail("Could not encode \(name)"); return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
