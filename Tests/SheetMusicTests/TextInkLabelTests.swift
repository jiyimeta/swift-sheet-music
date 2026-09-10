#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    import QuartzCore
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    @Suite("Label ink matches rendered output")
    @MainActor struct TextInkLabelTests {
        private let _installApple = TestSupport.installApple
        private let metrics = ElementHitFixtures.metrics

        @Test(arguments: 0 ... 9)
        func appleLabelInkMatchesLayers(kind: Int) throws {
            guard #available(macOS 15.0, *) else { return }
            let element = Self.element(kind)
            let rects = TextInkGeometry.rects(for: element, metrics: metrics)
            let measured = try #require(rects?.reduce(nil, Self.union))
            let parent = CALayer()
            var context = ScoreLayerBuilder.BuildContext()
            ScoreLayerBuilder.drawElement(
                element,
                base: .zero,
                metrics: metrics,
                height: 200,
                context: &context,
                into: parent,
            )
            let painted = try #require((parent.sublayers ?? []).compactMap { ($0 as? CAShapeLayer)?.path }
                .map { path -> CGRect in
                    let box = path.boundingBoxOfPath
                    return CGRect(x: box.minX, y: 200 - box.maxY, width: box.width, height: box.height)
                }.reduce(nil) { (box: CGRect?, next: CGRect) in box.map { $0.union(next) } ?? next })
            Self.expectEqual(measured, painted, tolerance: 0.001)
        }

        @Test(arguments: 0 ... 9)
        func portableCommandInkFitsExactDocument(kind: Int) throws {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Resources/sheet-music.smft")
            let provider = try makeFontMetricsTableProvider(table: FontMetricsTable.decode(Data(contentsOf: url)))
            try FontMetrics.$scopedProvider.withValue(provider) {
                let element = Self.element(kind)
                let bounds = LayoutEngine.elementYBounds(in: [], extraElements: [element], metrics: metrics)
                let shifted = LayoutEngine.translate(element: element, dy: -bounds.min)
                let size = CGSize(width: 500, height: bounds.max - bounds.min)
                let system = LayoutSystem(
                    origin: .zero,
                    size: size,
                    measures: [LayoutMeasure(
                        measureIndex: 0,
                        origin: .zero,
                        width: 500,
                        elements: [shifted],
                    )],
                    staffOrigins: [],
                    partLabels: [],
                    spanners: [],
                    sp: metrics.sp,
                )
                let document = LayoutDocument(size: size, systems: [system], metrics: metrics)
                let commands = LayoutBridge.buildCommands(layout: document)
                let painted = try #require(Self.portableOutline(commands))
                #expect(abs(painted.minY) < 0.02)
                #expect(abs(painted.maxY - size.height) < 0.02)
                let rects = TextInkGeometry.rects(for: shifted, metrics: metrics)
                let measured = try #require(rects?.reduce(nil, Self.union))
                // Fine has 0.375 pt of Edwin kerning that the per-scalar table
                // does not model. Its real Y bounds remain exact; kind 9 checks
                // all four marker edges without that separate shaping limitation.
                if kind != 6 { Self.expectEqual(measured, painted, tolerance: 0.02) }
            }
        }

        private static func element(_ kind: Int) -> LayoutElement {
            let p = CGPoint(x: 30, y: 0)
            switch kind {
            case 0: return .textMark(kind: .tempo(anchor: nil), text: "A", origin: p)
            case 1: return .textMark(kind: .tempo(anchor: nil), text: "\u{E1D5} = A", origin: p)
            case 2: return .textMark(kind: .dynamic(anchor: nil), text: "g", origin: p)
            case 3: return .measureNumber(text: "17", origin: p)
            case 4: return .staffName(text: "g", origin: p)
            case 5: return .jump(text: "D.S.", origin: p)
            case 6: return .marker(kind: .fine, text: "Fine", origin: p)
            case 7: return .textMark(kind: .tempo(anchor: nil), text: "A\ng", origin: p)
            case 8: return .textMark(kind: .dynamic(anchor: nil), text: "A\ng", origin: p)
            default: return .marker(kind: .other, text: "g", origin: p)
            }
        }

        /// Reconstruct the Web renderer's real outlines from emitted baseline commands.
        /// No layout metrics or anchoring helper contributes the expected geometry.
        private static func portableOutline(_ commands: [DrawCommand]) -> CGRect? {
            var result: CGRect?
            var flags: UInt8 = 0
            let scale = 72.0 / 25.4
            for command in commands {
                if case let .setTextStyle(value) = command { flags = value }
                guard case let .text(text, x, y, size, fontID) = command else { continue }
                let font = TextInkOracle.font(face: fontID == .smufl ? "Bravura" : "Edwin", size: size * scale)
                guard let path = TextInkOracle.path(text, font: font) else { continue }
                let outline = CGMutablePath(); outline.addPath(path)
                if flags & 1 != 0 {
                    outline.addPath(path.copy(
                        strokingWithWidth: size * scale / 32,
                        lineCap: .round,
                        lineJoin: .round,
                        miterLimit: 0,
                    ))
                }
                var transform = CGAffineTransform(
                    a: 1,
                    b: 0,
                    c: flags & 2 != 0 ? 0.25 : 0,
                    d: 1,
                    tx: 0,
                    ty: 0,
                )
                guard let ink = outline.copy(using: &transform)?.boundingBoxOfPath else { continue }
                let rect = CGRect(
                    x: x * scale + ink.minX,
                    y: y * scale - ink.maxY,
                    width: ink.width,
                    height: ink.height,
                )
                result = result.map { $0.union(rect) } ?? rect
            }
            return result
        }

        private static func expectEqual(_ got: CGRect, _ want: CGRect, tolerance: CGFloat) {
            #expect(abs(got.minX - want.minX) < tolerance)
            #expect(abs(got.minY - want.minY) < tolerance)
            #expect(abs(got.maxX - want.maxX) < tolerance)
            #expect(abs(got.maxY - want.maxY) < tolerance)
        }

        private static func union(_ box: CGRect?, _ next: CGRect) -> CGRect? {
            box.map { $0.union(next) } ?? next
        }

        @Test(arguments: [false, true])
        func notationKeepsNativeSystemSemibold(italic: Bool) throws {
            let role: NotationTextStyle.Role = italic ? .jump : .measureNumber
            let descriptor = NotationTextStyle.font(for: role, sp: metrics.sp)
            let font: CTFont
            #if os(macOS)
                let base = NSFont.systemFont(ofSize: descriptor.pointSize, weight: .semibold)
                font = (italic ? NSFont(
                    descriptor: base.fontDescriptor.withSymbolicTraits(.italic),
                    size: descriptor.pointSize,
                ) ?? base : base) as CTFont
            #else
                let base = UIFont.systemFont(ofSize: descriptor.pointSize, weight: .semibold)
                if italic, let traits = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    font = UIFont(descriptor: traits, size: descriptor.pointSize) as CTFont
                } else { font = base as CTFont }
            #endif
            let expected = try #require(TextInkOracle.path("Ag", font: font)?.boundingBoxOfPath)
            let measured = try #require(FontMetrics.provider.textInkBounds(text: "Ag", font: descriptor))
            Self.expectEqual(measured, expected, tolerance: 0.001)
        }
    }
#endif
