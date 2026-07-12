#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// Stage [11] — derive structural marks (BarLine subtypes, voltas,
// rehearsal marks, markers and jumps) from path geometry plus
// adjacent text. All helpers are pure: they take already-classified
// glyphs / paths / text and return Score-model values that the
// final assembler in Task 13 wires into the Score.

extension PDFImporter {
    // MARK: Barline classification

    /// Classify a barline path's subtype from line-width pattern +
    /// adjacent repeat dots.
    static func classifyBarline(
        primary: PathSegment,
        in measureXRange: ClosedRange<CGFloat>,
        paths: [PathSegment],
        glyphs: [ClassifiedGlyph],
    ) -> BarLine {
        _ = measureXRange // reserved: future "barline belongs to which side" disambiguation
        let primaryX = primary.rect.midX
        let neighbors = paths.filter {
            $0.kind == .vertical
                && $0.rect != primary.rect
                && abs($0.rect.midX - primaryX) <= 6
        }
        let dotsLeft = repeatDotsCount(near: primaryX, side: .left, glyphs: glyphs)
        let dotsRight = repeatDotsCount(near: primaryX, side: .right, glyphs: glyphs)
        if dotsLeft > 0, dotsRight > 0 {
            return BarLine(subtype: "end-start-repeat")
        }
        if dotsRight > 0 { return BarLine(subtype: "start-repeat") }
        if dotsLeft > 0 { return BarLine(subtype: "end-repeat") }
        return classifyByVerticals(primary: primary, neighbors: neighbors)
    }

    private enum RepeatDotsSide { case left, right }

    private static func repeatDotsCount(
        near primaryX: CGFloat,
        side: RepeatDotsSide,
        glyphs: [ClassifiedGlyph],
    ) -> Int {
        glyphs.count(where: { glyph in
            guard glyph.semantic == .repeatBarlineDots else { return false }
            let dx = glyph.raw.origin.x - primaryX
            return switch side {
            case .left: dx < 0 && dx >= -10
            case .right: dx > 0 && dx <= 10
            }
        })
    }

    private static func classifyByVerticals(
        primary: PathSegment,
        neighbors: [PathSegment],
    ) -> BarLine {
        guard let other = neighbors.first else {
            // Single vertical: a thick line on its own is a final-style
            // ending (rare in MuseScore output but observed). Default
            // (nil) covers the common single barline.
            return BarLine(subtype: nil)
        }
        let widths = [primary.lineWidth, other.lineWidth]
        let thick = widths.contains { $0 >= 1.5 }
        if !thick {
            return BarLine(subtype: "double")
        }
        // One thick + one thin → end (final barline). The thick line
        // is on the right in MuseScore's "final" rendering; we don't
        // currently consult that to choose an alternate subtype.
        return BarLine(subtype: "end")
    }

    // MARK: Volta detection

    /// Detect volta brackets above a system of measures.
    static func detectVoltas(
        measures: [(index: Int, xRange: ClosedRange<CGFloat>)],
        paths: [PathSegment],
        texts: [TextGlyph],
        systemTopY: CGFloat,
        pageIndex: Int,
    ) -> [(measureIndex: Int, spanner: Spanner)] {
        let candidates = paths.filter { p in
            p.pageIndex == pageIndex
                && p.kind == .rectangle
                && p.rect.height <= 30
                && p.rect.width > 50
                && p.rect.maxY <= systemTopY + 0.5
        }
        var out: [(measureIndex: Int, spanner: Spanner)] = []
        for rect in candidates {
            guard let spanner = voltaSpanner(
                rect: rect, measures: measures, texts: texts,
            ) else { continue }
            out.append(spanner)
        }
        return out
    }

    private static func voltaSpanner(
        rect: PathSegment,
        measures: [(index: Int, xRange: ClosedRange<CGFloat>)],
        texts: [TextGlyph],
    ) -> (measureIndex: Int, spanner: Spanner)? {
        let covered = measures.filter { m in
            // A measure is "covered" when its xRange center lies
            // inside the rectangle's x-extent.
            let center = (m.xRange.lowerBound + m.xRange.upperBound) / 2
            return rect.rect.minX <= center && center <= rect.rect.maxX
        }
        guard let first = covered.first, let last = covered.last else { return nil }
        let inside = texts.filter { rect.rect.intersects($0.bbox) }
        let endings = parseVoltaEndings(inside.map(\.text).joined(separator: " "))
        let span = Spanner(
            kind: .volta,
            rawType: "volta",
            nextMeasuresOffset: max(0, last.index - first.index),
            voltaEndings: endings,
        )
        return (first.index, span)
    }

    private static func parseVoltaEndings(_ text: String) -> [Int] {
        // Common labels: "1.", "2.", "1.–2.", "1, 2", "3."
        let scalars = text.unicodeScalars
        var digits: [Int] = []
        var current = ""
        for s in scalars {
            if s.value >= 0x30 && s.value <= 0x39 {
                current.append(Character(s))
            } else if !current.isEmpty {
                if let n = Int(current) { digits.append(n) }
                current = ""
            }
        }
        if !current.isEmpty, let n = Int(current) { digits.append(n) }
        return Array(Set(digits)).sorted()
    }

    // MARK: Rehearsal marks

    /// Detect rehearsal marks (boxed capital letter or digit) above
    /// a measure.
    static func detectRehearsalMarks(
        measures: [(index: Int, xRange: ClosedRange<CGFloat>)],
        paths: [PathSegment],
        texts: [TextGlyph],
        systemTopY: CGFloat,
        pageIndex: Int,
    ) -> [(measureIndex: Int, mark: RehearsalMark)] {
        let boxes = paths.filter { p in
            p.pageIndex == pageIndex
                && p.kind == .rectangle
                && p.rect.width <= 30
                && p.rect.height <= 20
                && p.rect.maxY <= systemTopY + 0.5
        }
        var out: [(measureIndex: Int, mark: RehearsalMark)] = []
        for box in boxes {
            guard let hit = rehearsalMark(box: box, measures: measures, texts: texts)
            else { continue }
            out.append(hit)
        }
        return out
    }

    private static func rehearsalMark(
        box: PathSegment,
        measures: [(index: Int, xRange: ClosedRange<CGFloat>)],
        texts: [TextGlyph],
    ) -> (measureIndex: Int, mark: RehearsalMark)? {
        let inside = texts.filter { box.rect.intersects($0.bbox) }
        guard inside.count == 1 else { return nil }
        let stripped = inside[0].text.trimmingCharacters(in: .whitespaces)
        guard isRehearsalLabel(stripped) else { return nil }
        let center = box.rect.midX
        guard let owner = measures.first(where: { m in
            m.xRange.contains(center)
        }) ?? measures.min(by: {
            abs(($0.xRange.lowerBound + $0.xRange.upperBound) / 2 - center)
                < abs(($1.xRange.lowerBound + $1.xRange.upperBound) / 2 - center)
        }) else { return nil }
        return (owner.index, RehearsalMark(text: stripped))
    }

    private static func isRehearsalLabel(_ s: String) -> Bool {
        guard s.count == 1, let scalar = s.unicodeScalars.first else {
            return false
        }
        let v = scalar.value
        let isUpper = v >= 0x41 && v <= 0x5A
        let isDigit = v >= 0x30 && v <= 0x39
        return isUpper || isDigit
    }

    // MARK: Markers and Jumps

    /// Parse Marker / Jump records from text glyphs adjacent to
    /// a measure's left or right end.
    static func detectMarkersAndJumps(
        texts: [TextGlyph],
        measures: [(index: Int, xRange: ClosedRange<CGFloat>)],
        systemTopY: CGFloat,
        pageIndex: Int,
    ) -> (
        markers: [(measureIndex: Int, marker: Marker)],
        jumps: [(measureIndex: Int, jump: Jump)],
    ) {
        var markers: [(Int, Marker)] = []
        var jumps: [(Int, Jump)] = []
        for glyph in texts where glyph.pageIndex == pageIndex {
            let stripped = glyph.text.trimmingCharacters(in: .whitespaces)
            if let jump = parseJump(stripped) {
                if let mi = nearestMeasure(forRightEdge: glyph, measures: measures) {
                    jumps.append((mi, jump))
                }
                continue
            }
            if let marker = parseMarker(stripped) {
                if let mi = nearestMeasure(forLeftEdge: glyph, measures: measures) {
                    markers.append((mi, marker))
                }
            }
        }
        _ = systemTopY
        return (markers.map { ($0.0, $0.1) }, jumps.map { ($0.0, $0.1) })
    }

    private static func parseMarker(_ text: String) -> Marker? {
        switch text {
        case "Segno": return Marker(kind: .segno, label: "segno", text: "Segno")
        case "Coda": return Marker(kind: .coda, label: "coda", text: "Coda")
        case "Fine": return Marker(kind: .fine, label: "fine", text: "Fine")
        case "To Coda":
            return Marker(kind: .toCoda, label: "to-coda", text: "To Coda")
        default: return nil
        }
    }

    private static func parseJump(_ text: String) -> Jump? {
        switch text {
        case "D.C.":
            return Jump(jumpTo: "start", playUntil: "end", text: "D.C.")
        case "D.C. al Fine":
            return Jump(jumpTo: "start", playUntil: "fine", text: "D.C. al Fine")
        case "D.C. al Coda":
            return Jump(
                jumpTo: "start", playUntil: "coda",
                continueAt: "codab", text: "D.C. al Coda",
            )
        case "D.S.":
            return Jump(jumpTo: "segno", playUntil: "end", text: "D.S.")
        case "D.S. al Fine":
            return Jump(jumpTo: "segno", playUntil: "fine", text: "D.S. al Fine")
        case "D.S. al Coda":
            return Jump(
                jumpTo: "segno", playUntil: "coda",
                continueAt: "codab", text: "D.S. al Coda",
            )
        default: return nil
        }
    }

    private static func nearestMeasure(
        forRightEdge glyph: TextGlyph,
        measures: [(index: Int, xRange: ClosedRange<CGFloat>)],
    ) -> Int? {
        let x = glyph.bbox.maxX
        // Pick the measure whose right edge is nearest to the text's
        // right edge.
        return measures.min(by: {
            abs($0.xRange.upperBound - x) < abs($1.xRange.upperBound - x)
        })?.index
    }

    private static func nearestMeasure(
        forLeftEdge glyph: TextGlyph,
        measures: [(index: Int, xRange: ClosedRange<CGFloat>)],
    ) -> Int? {
        let x = glyph.bbox.minX
        return measures.min(by: {
            abs($0.xRange.lowerBound - x) < abs($1.xRange.lowerBound - x)
        })?.index
    }
}
