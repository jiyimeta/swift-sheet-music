#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// A `<FretDiagram>` as a figure (`TLayout::layoutFretDiagram`, `tlayout.cpp:2395-2560`; `TDraw::draw(FretDiagram)`,
/// `tdraw.cpp:1335-1485`), with MuseScore's style defaults (`styledef.cpp:442-462`): strings and frets 0.7 sp apart,
/// 0.5 sp dots, a 0.3 sp nut. Built in the vertical frame — the nut at y = 0, string `i` at x = i × 0.7 sp — and turned
/// for a horizontal diagram. The per-string fingering digits and the slur-style barre are not drawn.
enum FretDiagramGeometry {
    static let stringDistSp: CGFloat = 0.7
    static let fretDistSp: CGFloat = 0.7
    static let stringWidthSp: CGFloat = 0.08
    static let nutWidthSp: CGFloat = 0.3
    static let dotSp: CGFloat = 0.5
    /// `Sid::fretY`: the diagram's bottom stands this far above the staff's top line.
    static let staffGapSp: CGFloat = 1

    struct Built {
        let figure: LayoutFigure
        /// The grid's horizontal center, which sits on the beat's notehead.
        let gridCenterX: CGFloat
        let topY: CGFloat
        let bottomY: CGFloat
    }

    /// The diagram's measurements in the vertical frame.
    private struct Frame {
        let stringDist: CGFloat
        let fretDist: CGFloat
        let stringW: CGFloat
        let strings: Int
        let frets: Int
        let nutW: CGFloat
        let nutY: CGFloat
        let dot: CGFloat
        let marker: CGFloat
        let markerTop: CGFloat
        var x2: CGFloat {
            stringDist * CGFloat(strings - 1)
        }

        var y2: CGFloat {
            fretDist * CGFloat(frets)
        }

        var symbolW: CGFloat {
            1.2 * stringW
        }

        init(_ diagram: FretDiagram, sp: CGFloat) {
            stringDist = stringDistSp * sp
            fretDist = fretDistSp * sp
            stringW = stringWidthSp * sp
            strings = max(diagram.stringCount, 1)
            frets = max(diagram.fretCount, 1)
            nutW = (diagram.fretOffset ?? 0) > 0 || diagram.showNut == false ? stringW : nutWidthSp * sp
            nutY = -0.5 * (nutW - stringW)
            dot = dotSp * sp
            marker = 0.8 * stringDist
            markerTop = nutY - 0.5 * nutW - marker - 0.2 * sp
        }

        /// The center of fret row `fret` (1-based) on string x.
        func rowY(_ fret: Int) -> CGFloat {
            fretDist * CGFloat(fret - 1) + fretDist / 2
        }
    }

    static func figure(_ diagram: FretDiagram, sp: CGFloat) -> Built {
        let frame = Frame(diagram, sp: sp)
        var primitives = grid(frame) + contents(diagram, frame: frame)
        let horizontal = diagram.orientation == .horizontal
        if let offset = diagram.fretOffset, offset > 0 {
            primitives.append(fretNumber(offset + 1, diagram: diagram, horizontal: horizontal, sp: sp))
        }
        guard horizontal else {
            let top = min(frame.markerTop, frame.nutY - 0.5 * frame.nutW)
            return Built(
                figure: LayoutFigure(primitives: primitives), gridCenterX: frame.x2 / 2, topY: top, bottomY: frame.y2,
            )
        }
        // Turned −90°: (x, y) → (y, W − x), the first string at the bottom; ellipses and text stay upright.
        let turned = primitives.map { turn($0, width: frame.x2) }
        return Built(figure: LayoutFigure(primitives: turned), gridCenterX: frame.y2 / 2, topY: 0, bottomY: frame.x2)
    }

    /// The nut, the strings and the fret lines.
    private static func grid(_ frame: Frame) -> [LayoutFigure.Primitive] {
        let left = -frame.stringW / 2
        let right = frame.x2 + frame.stringW / 2
        var primitives: [LayoutFigure.Primitive] = [.line(
            from: CGPoint(x: left, y: frame.nutY), to: CGPoint(x: right, y: frame.nutY), width: frame.nutW, cap: .flat,
        )]
        for string in 0 ..< frame.strings {
            let x = frame.stringDist * CGFloat(string)
            primitives.append(.line(
                from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: frame.y2 + 0.5 * frame.stringW), width: frame.stringW,
                cap: .flat,
            ))
        }
        for fret in 1 ... frame.frets {
            let y = frame.fretDist * CGFloat(fret)
            primitives.append(.line(
                from: CGPoint(x: left, y: y), to: CGPoint(x: right, y: y), width: frame.stringW, cap: .flat,
            ))
        }
        return primitives
    }

    /// The dots and markers of each string, then the barres.
    private static func contents(_ diagram: FretDiagram, frame: Frame) -> [LayoutFigure.Primitive] {
        var primitives: [LayoutFigure.Primitive] = []
        for string in diagram.strings where (0 ..< frame.strings).contains(string.index) {
            let x = frame.stringDist * CGFloat(string.index)
            for item in string.dots where item.fret >= 1 {
                let center = CGPoint(x: x, y: frame.rowY(item.fret))
                primitives += dotShape(item.kind, center: center, size: frame.dot, width: frame.symbolW)
            }
            let box = CGRect(x: x - frame.marker / 2, y: frame.markerTop, width: frame.marker, height: frame.marker)
            switch string.marker {
            case .circle?: primitives.append(.ellipse(rect: box, fill: false, width: frame.symbolW))
            case .cross?: primitives += cross(in: box, width: frame.symbolW)
            default: break
            }
        }
        for barre in diagram.barres where barre.fret >= 1 {
            let y = frame.rowY(barre.fret)
            let start = frame.stringDist * CGFloat(max(barre.startString, 0))
            let end = barre.endString < 0 ? frame.x2 : frame.stringDist * CGFloat(barre.endString)
            primitives.append(.line(
                from: CGPoint(x: start, y: y), to: CGPoint(x: end, y: y), width: frame.dot * 0.85, cap: .round,
            ))
        }
        return primitives
    }

    /// A dot by kind, `size` across, centered on `center`.
    private static func dotShape(
        _ kind: FretString.Dot.Kind, center: CGPoint, size: CGFloat, width: CGFloat,
    ) -> [LayoutFigure.Primitive] {
        let box = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        switch kind {
        case .cross:
            return cross(in: box, width: width * 1.5)
        case .square:
            return [.rectOutline(rect: box, width: width)]
        case .triangle:
            return [.polyline(
                points: [
                    CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY),
                    CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.midX, y: box.minY),
                ],
                width: width,
            )]
        default:
            return [.ellipse(rect: box, fill: true, width: 0)]
        }
    }

    private static func cross(in box: CGRect, width: CGFloat) -> [LayoutFigure.Primitive] {
        [
            .line(
                from: CGPoint(x: box.minX, y: box.minY),
                to: CGPoint(x: box.maxX, y: box.maxY),
                width: width,
                cap: .flat,
            ),
            .line(
                from: CGPoint(x: box.maxX, y: box.minY),
                to: CGPoint(x: box.minX, y: box.maxY),
                width: width,
                cap: .flat,
            ),
        ]
    }

    /// The fret number of an offset diagram (`.fretDiagramFretNumber`: the text face at 6 pt), right-aligned left of
    /// the grid and centered on the first fret row — above the first fret column when the diagram is horizontal (the
    /// caller turns the rest; this one is built where it ends up, upright).
    private static func fretNumber(
        _ number: Int, diagram: FretDiagram, horizontal: Bool, sp: CGFloat,
    ) -> LayoutFigure.Primitive {
        let text = String(number)
        let face = TextInkGeometry.font(for: .staffText, metrics: StaffMetrics(staffSize: 4 * sp)).face
        let font = LayoutFont(face: face, pointSize: 6 * sp / 5)
        let provider = FontMetrics.provider
        let width = provider.typographicWidth(text: text, font: font)
        let ascent = provider.ascent(font: font)
        let descent = provider.descent(font: font)
        let barreAtFirstString = diagram.barres.contains { $0.startString == 0 }
        let padding = 0.4 * stringDistSp * sp + (barreAtFirstString ? 0.2 * dotSp * sp * 0.85 : 0)
        let rowCenter = fretDistSp * sp / 2
        let baseline = if horizontal {
            // Turned frame: the first fret column is centered on x = rowCenter; the text sits above the top string.
            CGPoint(x: rowCenter - width / 2, y: -padding - descent)
        } else {
            CGPoint(x: -padding - width, y: rowCenter + (ascent - descent) / 2)
        }
        let run = LayoutRichTextPositionedRun(content: .text(text), font: font, baseline: baseline)
        return .run(run, rotation: 0, pivot: baseline)
    }

    /// One primitive of the vertical frame turned into the horizontal one. A run is left where it is: the only run is
    /// the fret number, already built in place.
    private static func turn(_ primitive: LayoutFigure.Primitive, width: CGFloat) -> LayoutFigure.Primitive {
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.y, y: width - p.x)
        }
        switch primitive {
        case let .line(from, to, lineWidth, cap):
            return .line(from: point(from), to: point(to), width: lineWidth, cap: cap)
        case let .polyline(points, lineWidth):
            return .polyline(points: points.map(point), width: lineWidth)
        case let .ellipse(rect, fill, lineWidth):
            let center = point(CGPoint(x: rect.midX, y: rect.midY))
            return .ellipse(
                rect: CGRect(
                    x: center.x - rect.height / 2,
                    y: center.y - rect.width / 2,
                    width: rect.height,
                    height: rect.width,
                ),
                fill: fill, width: lineWidth,
            )
        case let .rectOutline(rect, lineWidth):
            let center = point(CGPoint(x: rect.midX, y: rect.midY))
            return .rectOutline(
                rect: CGRect(
                    x: center.x - rect.height / 2,
                    y: center.y - rect.width / 2,
                    width: rect.height,
                    height: rect.width,
                ),
                width: lineWidth,
            )
        case .run:
            return primitive
        }
    }
}
