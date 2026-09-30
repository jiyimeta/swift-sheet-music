import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicLayout
@testable import SheetMusicRenderWindows
import Testing

/// Measured equals drawn for the system face on Windows (spec `2026-10-01-ssm-4-a-wire-v8-design.md` §7.1).
///
/// A notation label's x is its anchor resolved against the ink the layout measured: a part label's baseline sits so
/// its ink ends at the label's right-edge anchor, a measure number's so its ink starts at its left one. The renderer
/// cannot resolve that again, so the one way a label lands on its anchor is for Direct2D to draw exactly the ink
/// `WindowsFontMetricsProvider` measured. Parity with the CG walk cannot catch a gap here — both draw the same stream —
/// which is why this test renders each label and compares its pixels with the measurement the layout was given.
@Suite("Measured equals drawn for the system face")
struct LabelAnchorTests {
    /// ~203 dpi: a part label is ~50 px to the em, so an edge's partial coverage resolves well inside the tolerance.
    private static let pxPerMM = 8.0
    private static let mmToPt = 72.0 / 25.4
    /// Half a pixel, the spec's bound. Each drawn edge is read to a fraction of a pixel (`inkEdges`), so antialiasing
    /// does not eat into it: what is left is the rasterizer's coverage quantization, a small fraction of a pixel.
    private static let tolerancePx = 0.5
    /// White space around the expected ink, so a label drawn off its measurement still lands on the canvas.
    private static let marginPx = 8

    /// One `.text` command in the system face, with the style it was drawn in.
    private struct Label {
        var text: String
        var x: Double
        var y: Double
        var size: Double
        var flags: UInt8

        var isMeasureNumber: Bool {
            text.allSatisfy(\.isNumber)
        }
    }

    @Test("every system-face label's drawn ink spans the ink the layout measured and anchored")
    func labelsLandOnTheirAnchors() throws {
        let tableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SheetMusicTests/Resources/sheet-music.smft")
        let table = try FontMetricsTable.decode(Data(contentsOf: tableURL))
        let provider = try WindowsFontMetricsProvider(base: makeFontMetricsTableProvider(table: table))
        try FontMetrics.$scopedProvider.withValue(provider) {
            let score = try ScoreBridge.loadScore(bytes: Data(Self.musicXML().utf8))
            var options = LayoutOptionsWire.verticalDefault
            options.layoutMode = LayoutOptionsWire.Mode.page.rawValue
            options.measureNumberInterval = 1
            let laidOut = LayoutBridge.computePages(score: score, pageWidthMM: 210, pageHeightMM: 297, options: options)
            let labels = laidOut.pages.flatMap { Self.systemTexts(in: $0.commands) }
            // Not vacuous: the provider kept the system face, so the stream names it for both kinds of label.
            // Evaluated outside `#expect`: inside the macro a key-path `contains(where:)` reads as a throwing call.
            let hasPartLabel = labels.contains { !$0.isMeasureNumber }
            let hasMeasureNumber = labels.contains(where: \.isMeasureNumber)
            #expect(hasPartLabel, "a part label is drawn in the system face")
            #expect(hasMeasureNumber, "a measure number is drawn in the system face")
            for label in labels {
                try Self.check(label, provider: provider)
            }
        }
    }

    /// Renders `label` alone and compares its ink with baseline + the provider's ink bounds: the right edge is a part
    /// label's anchor, the left edge a measure number's, and both edges together are its centre.
    private static func check(_ label: Label, provider: WindowsFontMetricsProvider) throws {
        let weight: FontWeight = if label.flags & DrawCommand.TextStyleFlag.bold != 0 {
            .bold
        } else if label.flags & DrawCommand.TextStyleFlag.semibold != 0 {
            .semibold
        } else {
            .regular
        }
        let font = LayoutFont(
            face: "", pointSize: label.size * mmToPt, weight: weight,
            isItalic: label.flags & DrawCommand.TextStyleFlag.italic != 0,
        )
        let ink = try #require(provider.textInkBounds(text: label.text, font: font), "\(label.text): no measured ink")
        // Y-up points from the baseline to Y-down canvas pixels.
        let pxPerPt = pxPerMM / mmToPt
        let baselineX = label.x * pxPerMM
        let baselineY = label.y * pxPerMM
        let expectedLeft = baselineX + ink.minX * pxPerPt
        let expectedRight = baselineX + ink.maxX * pxPerPt
        let expectedTop = baselineY - ink.maxY * pxPerPt
        let expectedBottom = baselineY - ink.minY * pxPerPt

        // Only this label, on white, around where it should be: nothing else on the page (a staff line, a bracket)
        // can be taken for its ink. No font files, so Segoe UI comes from the installed fonts, as it does on screen.
        let originX = Int(expectedLeft.rounded(.down)) - marginPx
        let originY = Int(expectedTop.rounded(.down)) - marginPx
        let width = Int(expectedRight.rounded(.up)) - originX + marginPx
        let height = Int(expectedBottom.rounded(.up)) - originY + marginPx
        let pixels = try Direct2DPageRenderer.renderPixels(
            [
                .setTextStyle(flags: label.flags),
                .text(text: label.text, x: label.x, y: label.y, size: label.size, fontId: .system),
            ],
            widthPx: width, heightPx: height, pxPerMM: pxPerMM, offsetPx: (Double(-originX), Double(-originY)),
            fontFiles: [],
        )
        let drawn = try #require(inkEdges(pixels, width: width, height: height), "\(label.text): nothing drawn")
        #expect(!drawn.touchesBorder, "\(label.text): the drawn ink runs off its \(marginPx) px margin")
        let left = Double(originX) + drawn.left
        let right = Double(originX) + drawn.right
        let kind = label.isMeasureNumber ? "measure number" : "part label"
        #expect(
            abs(right - expectedRight) <= tolerancePx,
            "\(kind) \(label.text): ink ends at \(right) px, measured \(expectedRight) px",
        )
        #expect(
            abs(left - expectedLeft) <= tolerancePx,
            "\(kind) \(label.text): ink starts at \(left) px, measured \(expectedLeft) px",
        )
    }

    /// The drawn ink's horizontal extent in canvas pixels, to a fraction of a pixel: the outermost columns with any
    /// coverage, each taken in by the part the ink leaves empty. That part is one minus the column's darkest pixel's
    /// coverage, which on a vertical edge — or a curve whose radius is several pixels, as every glyph's here — is the
    /// fraction of the column the outline covers.
    private static func inkEdges(
        _ pixels: [UInt8], width: Int, height: Int,
    ) -> (left: Double, right: Double, touchesBorder: Bool)? {
        var coverage = [Double](repeating: 0, count: width)
        for y in 0 ..< height {
            for x in 0 ..< width {
                // Premultiplied BGRA, black over white: green falls from 255 as coverage rises.
                let green = Double(pixels[(y * width + x) * 4 + 1])
                coverage[x] = max(coverage[x], 1 - green / 255)
            }
        }
        let threshold = 0.01
        guard let first = coverage.firstIndex(where: { $0 > threshold }),
              let last = coverage.lastIndex(where: { $0 > threshold })
        else { return nil }
        return (
            left: Double(first) + 1 - coverage[first], right: Double(last) + coverage[last],
            touchesBorder: first == 0 || last == width - 1,
        )
    }

    /// Every unrotated `.text` in the system face, with the `setTextStyle` flags in force at it.
    private static func systemTexts(in commands: [DrawCommand]) -> [Label] {
        var flags = DrawCommand.TextStyleFlag.none
        var rotated = false
        var labels: [Label] = []
        for command in commands {
            switch command {
            case let .setTextStyle(value):
                flags = value
            case let .setRotation(radians, _, _):
                rotated = radians != 0
            case let .text(text, x, y, size, fontId) where fontId == .system && !rotated:
                labels.append(Label(text: text, x: x, y: y, size: size, flags: flags))
            default:
                break
            }
        }
        return labels
    }

    /// Two named parts (so each system start carries part labels), sixteen measures of quarters (several systems on
    /// A4, each measure numbered under `measureNumberInterval = 1`).
    private static func musicXML() -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
        <part-list>
        <score-part id="P1"><part-name>Flute</part-name></score-part>
        <score-part id="P2"><part-name>Violoncello</part-name></score-part>
        </part-list>

        """
        let parts: [(sign: String, line: Int, octave: Int)] = [("G", 2, 5), ("F", 4, 3)]
        for (index, part) in parts.enumerated() {
            xml += "<part id=\"P\(index + 1)\">\n"
            for measure in 1 ... 16 {
                xml += "<measure number=\"\(measure)\">"
                if measure == 1 {
                    xml += "<attributes><divisions>1</divisions><key><fifths>0</fifths></key>"
                    xml += "<time><beats>4</beats><beat-type>4</beat-type></time>"
                    xml += "<clef><sign>\(part.sign)</sign><line>\(part.line)</line></clef></attributes>"
                }
                for step in ["C", "D", "E", "F"] {
                    xml += "<note><pitch><step>\(step)</step><octave>\(part.octave)</octave></pitch>"
                    xml += "<duration>1</duration><type>quarter</type></note>"
                }
                xml += "</measure>\n"
            }
            xml += "</part>\n"
        }
        return xml + "</score-partwise>\n"
    }
}
