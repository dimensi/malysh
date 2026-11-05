import SwiftUI
import UIKit
import WidgetKit
import XCTest

/// Renders the production extension view. Attachments are visual review evidence,
/// not pixel goldens: system widget compositing is additionally checked in SpringBoard.
@MainActor
final class DiaryWidgetRenderingTests: XCTestCase {
    func testProductionSurfaceMatrix() throws {
        let now = Date()
        let baby = Baby(name: "Малыш", birthDate: now.addingTimeInterval(-90 * 86400), birthDateConfirmed: true)
        let events = [
            CareEvent(
                babyID: baby.id,
                kind: .bottle,
                start: now.addingTimeInterval(-3600),
                end: now.addingTimeInterval(-3600),
                volumeML: 90
            ),
            CareEvent(
                babyID: baby.id,
                kind: .diaper,
                start: now.addingTimeInterval(-1800),
                end: now.addingTimeInterval(-1800),
                diaperType: .mixed
            ),
            CareEvent(
                babyID: baby.id,
                kind: .sleep,
                start: now.addingTimeInterval(-10800),
                end: now.addingTimeInterval(-7200)
            ),
        ]
        let active = events + [
            CareEvent(babyID: baby.id, kind: .breast, start: now.addingTimeInterval(-420)),
            CareEvent(babyID: baby.id, kind: .diaper, start: now.addingTimeInterval(-900),
                      end: now.addingTimeInterval(-900), diaperType: .dirty),
            CareEvent(babyID: baby.id, kind: .sleep, start: now.addingTimeInterval(-1800)),
        ]
        let states: [(String, WidgetSnapshot?)] = [
            ("populated", WidgetSnapshot(baby: baby, events: events, generatedAt: now)),
            ("active", WidgetSnapshot(baby: baby, events: active, generatedAt: now)),
            ("empty", WidgetSnapshot(baby: baby, events: [], generatedAt: now)),
            ("unavailable", nil),
        ]
        for surface in DiaryWidgetSurface.allCases {
            for family in surface.families {
                let size = try XCTUnwrap(families.first { $0.0 == family }?.1)
                for theme in [ColorScheme.light, .dark] {
                    for (state, snapshot) in states {
                        for typeSize in [
                            DynamicTypeSize.large,
                            .xxxLarge,
                            .accessibility1,
                            .accessibility3,
                            .accessibility5,
                        ] {
                            try render(entry: DiaryWidgetEntry(date: now, snapshot: snapshot), family: family,
                                       size: size, appearance: Appearance(theme: theme,
                                                                          mode: family
                                                                              .isAccessory ? .vibrant : .fullColor,
                                                                          typeSize: typeSize),
                                       name: "\(surface)-\(family)-\(state)-\(typeSize)-\(theme)", surface: surface)
                        }
                    }
                    if !family.isAccessory {
                        for mode in [WidgetRenderingMode.accented, .vibrant] {
                            try render(entry: DiaryWidgetEntry(date: now, snapshot: states[1].1), family: family,
                                       size: size, appearance: Appearance(theme: theme, mode: mode),
                                       name: "\(surface)-\(family)-\(mode)-\(theme)", surface: surface)
                        }
                    }
                }
            }
        }
    }

    func testLegacyInstalledFamiliesRemainRenderable() throws {
        for (family, size) in families {
            try render(entry: DiaryWidgetEntry(date: .now, snapshot: nil), family: family,
                       size: size, appearance: Appearance(theme: .light, mode: .fullColor), name: "legacy-\(family)")
        }
    }

    func testIdleRecordedTimesFromPreviousDays() throws {
        let now = Date()
        let baby = Baby(name: "Малыш")
        let previous = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: now))
        let snapshot = WidgetSnapshot(baby: baby, events: [
            CareEvent(babyID: baby.id, kind: .bottle, start: previous, end: previous, volumeML: 90),
            CareEvent(babyID: baby.id, kind: .sleep, start: previous.addingTimeInterval(-3600), end: previous),
            CareEvent(babyID: baby.id, kind: .diaper, start: previous, end: previous, diaperType: .dirty),
        ], generatedAt: now)
        for surface in [DiaryWidgetSurface.feeding, .sleep, .quickActions, .dashboard] {
            let family = try XCTUnwrap(surface.families.first)
            let size = try XCTUnwrap(families.first { $0.0 == family }?.1)
            try render(entry: DiaryWidgetEntry(date: now, snapshot: snapshot), family: family,
                       size: size, appearance: Appearance(theme: .light, mode: .fullColor),
                       name: "\(surface)-idle-previous-day-static-time", surface: surface)
        }
    }

    func testLiveActivityExpandedProductionContent() throws {
        let attributes = CareActivityAttributes(eventID: UUID(), babyID: UUID())
        for kind in [EventKind.breast, .sleep] {
            let state = CareActivityAttributes.ContentState(kind: kind, start: .now.addingTimeInterval(-742),
                                                            side: kind == .breast ? .left : nil, babyName: "Малыш")
            for typeSize in [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5] {
                let view = VStack(spacing: 8) {
                    CareActivityIslandInfo(state: state)
                    CareActivityControls(attributes: attributes, state: state)
                }
                .environment(\.dynamicTypeSize, typeSize)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(width: 338)
                .background(.black)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertLessThanOrEqual(
                    image.size.height,
                    160,
                    "Expanded island content must fit its native height budget"
                )
                let attachment = XCTAttachment(image: image)
                attachment.name = "liveActivity-expanded-\(kind)-\(typeSize)"
                attachment.lifetime = .keepAlways
                add(attachment)
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
                        appearance: Appearance, name: String, surface: DiaryWidgetSurface? = nil) throws -> UIImage
    {
        let view = DiaryWidgetView(
            entry: entry,
            familyOverride: family,
            renderingModeOverride: appearance.mode,
            surface: surface
        )
        .environment(\.colorScheme, appearance.theme)
        .environment(\.dynamicTypeSize, appearance.typeSize)
        .padding(family.isAccessory ? 0 : 16)
        .frame(width: size.width, height: size.height)
        .background(appearance.theme == .dark ? Color.black : Color.white)
        if (appearance.typeSize.isAccessibilitySize &&
            (surface == .dashboard || surface == .feeding || surface == .diaper || surface == .sleep)) ||
            ((surface == .quickActions || surface == .dashboard) && (appearance.typeSize.isAccessibilitySize ||
                    appearance.typeSize == .large || appearance.typeSize == .xxxLarge))
        {
            // Measure the production stack's natural height as well as its fixed
            // canvas: a clipped render can otherwise keep the correct PNG size.
            let natural = DiaryWidgetView(entry: entry, familyOverride: family,
                                          renderingModeOverride: appearance.mode, surface: surface)
                .environment(\.colorScheme, appearance.theme)
                .environment(\.dynamicTypeSize, appearance.typeSize)
                .frame(width: size.width - 32)
                .fixedSize(horizontal: false, vertical: true)
            let naturalRenderer = ImageRenderer(content: natural)
            let naturalImage = try XCTUnwrap(naturalRenderer.uiImage, name)
            XCTAssertLessThanOrEqual(naturalImage.size.height, size.height - 32,
                                     "\(name): readable action stack exceeds the available canvas")
        }
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
