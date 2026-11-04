import SwiftUI
import UIKit
import WidgetKit
import XCTest

/// Renders the production extension view. Attachments are visual review evidence,
/// not pixel goldens: system widget compositing is additionally checked in SpringBoard.
@MainActor
final class DiaryWidgetRenderingTests: XCTestCase {
    func testEveryFamilyWithDataAndEmptyStates() throws {
        let now = Date()
        let baby = Baby(name: "Малыш")
        let events = [
            CareEvent(babyID: baby.id, kind: .bottle, start: now.addingTimeInterval(-3600),
                      end: now.addingTimeInterval(-3600), volumeML: 90),
            CareEvent(babyID: baby.id, kind: .diaper, start: now.addingTimeInterval(-1800),
                      end: now.addingTimeInterval(-1800), diaperType: .mixed),
            CareEvent(babyID: baby.id, kind: .sleep, start: now.addingTimeInterval(-10800),
                      end: now.addingTimeInterval(-7200)),
        ]
        let states: [(String, WidgetSnapshot?)] = [
            ("populated", WidgetSnapshot(baby: baby, events: events, generatedAt: now)),
            ("empty", WidgetSnapshot(baby: baby, events: [], generatedAt: now)),
            ("unavailable", nil),
        ]
        for (name, snapshot) in states {
            for (family, size) in families {
                for theme in [ColorScheme.light, .dark] {
                    try render(entry: DiaryWidgetEntry(date: now, snapshot: snapshot), family: family,
                               size: size, appearance: Appearance(
                                   theme: theme,
                                   mode: family.isAccessory ? .vibrant : .fullColor
                               ),
                               name: "\(family)-\(name)-\(theme)")
                }
            }
        }
        for (family, size) in families where !family.isAccessory {
            for theme in [ColorScheme.light, .dark] {
                try render(entry: DiaryWidgetEntry(date: now, snapshot: states[0].1), family: family,
                           size: size, appearance: Appearance(theme: theme, mode: .accented),
                           name: "\(family)-accented-\(theme)")
            }
        }
    }

    func testAccessibilitySizesReachEveryFamilyWithoutClamping() throws {
        let now = Date()
        let baby = Baby(name: "Малыш")
        let events = [CareEvent(babyID: baby.id, kind: .bottle, start: now.addingTimeInterval(-3600),
                                end: now.addingTimeInterval(-3600), volumeML: 90)]
        let populated = WidgetSnapshot(baby: baby, events: events, generatedAt: now)
        let states: [(String, WidgetSnapshot?)] = [
            ("populated", populated), ("empty", WidgetSnapshot(baby: baby, events: [], generatedAt: now)),
            ("unavailable", nil),
        ]
        for (family, size) in families {
            for theme in [ColorScheme.light, .dark] {
                var firstSize: Data?
                var lastSize: Data?
                for typeSize in [DynamicTypeSize.xxxLarge, .accessibility1, .accessibility3, .accessibility5] {
                    for (name, snapshot) in states {
                        let image = try render(entry: DiaryWidgetEntry(date: now, snapshot: snapshot), family: family,
                                               size: size, appearance: Appearance(
                                                   theme: theme, mode: family.isAccessory ? .vibrant : .fullColor,
                                                   typeSize: typeSize
                                               ), name: "\(family)-\(name)-\(typeSize)-\(theme)")
                        if name == "unavailable", typeSize == .accessibility1 {
                            firstSize = image.pngData()
                        }
                        if name == "unavailable", typeSize == .accessibility5 {
                            lastSize = image.pngData()
                        }
                    }
                }
                // Unavailable content has no live relative dates: size alone changes this raster.
                XCTAssertNotEqual(try XCTUnwrap(firstSize), try XCTUnwrap(lastSize),
                                  "\(family) must render the user's actual accessibility text size")
            }
        }
    }

    private struct Appearance {
        let theme: ColorScheme
        let mode: WidgetRenderingMode
        var typeSize: DynamicTypeSize = .large
    }

    private var families: [(WidgetFamily, CGSize)] {
        [(.systemSmall, CGSize(width: 158, height: 158)),
         (.systemMedium, CGSize(width: 338, height: 158)),
         (.systemLarge, CGSize(width: 338, height: 354)),
         (.accessoryRectangular, CGSize(width: 156, height: 72)),
         (.accessoryCircular, CGSize(width: 72, height: 72)),
         (.accessoryInline, CGSize(width: 280, height: 26))]
    }

    @discardableResult
    private func render(entry: DiaryWidgetEntry, family: WidgetFamily, size: CGSize,
                        appearance: Appearance, name: String) throws -> UIImage
    {
        let view = DiaryWidgetView(entry: entry, familyOverride: family, renderingModeOverride: appearance.mode)
            .environment(\.colorScheme, appearance.theme)
            .environment(\.dynamicTypeSize, appearance.typeSize)
            .padding(family.isAccessory ? 0 : 16)
            .frame(width: size.width, height: size.height)
            .background(appearance.theme == .dark ? Color.black : Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, name)
        XCTAssertEqual(image.size, size, name)
        if family.isAccessory, appearance.typeSize >= .xxxLarge {
            try assertAccessoryTextStaysInsideCanvas(image, theme: appearance.theme, name: name)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func assertAccessoryTextStaysInsideCanvas(_ image: UIImage, theme: ColorScheme, name: String) throws {
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width
        let height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let background = theme == .dark ? 0 : 255
        for row in [0, height - 1] {
            let touchesEdge = (0 ..< width).contains { column in
                let offset = (row * width + column) * 4
                return (0 ..< 3).contains { abs(Int(pixels[offset + $0]) - background) > 10 }
            }
            XCTAssertFalse(touchesEdge, "\(name): text/symbol reaches a vertical clipping edge")
        }
    }
}

private extension WidgetFamily {
    var isAccessory: Bool {
        self == .accessoryRectangular || self == .accessoryCircular || self == .accessoryInline
    }
}
