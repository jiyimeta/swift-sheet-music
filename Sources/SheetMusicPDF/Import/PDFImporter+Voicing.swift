import CoreGraphics
import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Assign rhythm elements to voices based on temporal overlap and
    /// stem direction / y-position. Single-voice when no two elements'
    /// time intervals overlap; otherwise split into voice 1 / voice 2
    /// with stem direction (or rest y-position) deciding placement.
    /// Voice 3+ collisions collapse into voice 1 with a warning
    /// diagnostic at this measure's location.
    ///
    /// Beam grouping is deferred: until beam-path detection lands,
    /// every `RhythmElement` is treated as its own rhythmic unit.
    static func assignVoices(
        elements: [RhythmElement],
        measureXRange: ClosedRange<CGFloat>,
        timeSignature: TimeSignature,
        staffMidY: CGFloat,
        diagnostics: ((PDFImportDiagnostic) -> Void)? = nil,
        location: String = ""
    ) -> [Voice] {
        guard !elements.isEmpty else { return [] }
        let intervals = elements.map {
            interval(for: $0, xRange: measureXRange, timeSignature: timeSignature)
        }
        if !anyOverlap(intervals) {
            return [Voice(elements: elements.map { .chord($0.chord) })]
        }
        return splitIntoTwoVoices(
            elements: elements,
            staffMidY: staffMidY,
            diagnostics: diagnostics,
            location: location
        )
    }

    private static func splitIntoTwoVoices(
        elements: [RhythmElement],
        staffMidY: CGFloat,
        diagnostics: ((PDFImportDiagnostic) -> Void)?,
        location: String
    ) -> [Voice] {
        var v1: [VoiceElement] = []
        var v2: [VoiceElement] = []
        var v1OccupiedAt: Set<RoundedX> = []
        var v2OccupiedAt: Set<RoundedX> = []
        for u in elements {
            let key = RoundedX(u.x)
            switch voiceFor(u, staffMidY: staffMidY) {
            case 1:
                if v1OccupiedAt.contains(key) {
                    emitVoice3Warning(diagnostics, location: location)
                }
                v1.append(.chord(u.chord))
                v1OccupiedAt.insert(key)
            default:
                if v2OccupiedAt.contains(key) {
                    emitVoice3Warning(diagnostics, location: location)
                }
                v2.append(.chord(u.chord))
                v2OccupiedAt.insert(key)
            }
        }
        return [Voice(elements: v1), Voice(elements: v2)]
    }

    private static func emitVoice3Warning(
        _ diagnostics: ((PDFImportDiagnostic) -> Void)?,
        location: String
    ) {
        diagnostics?(PDFImportDiagnostic(
            severity: .warning,
            location: location,
            message: "Voice 3+ collapsed into voice 1/2"
        ))
    }
}

// MARK: - Time / overlap helpers

extension PDFImporter {
    private static func interval(
        for element: RhythmElement,
        xRange: ClosedRange<CGFloat>,
        timeSignature: TimeSignature
    ) -> ClosedRange<CGFloat> {
        let totalQuarters = quartersOfMeasure(timeSignature: timeSignature)
        let pxPerQuarter =
            (xRange.upperBound - xRange.lowerBound) / CGFloat(totalQuarters)
        let widthPx = CGFloat(quartersOf(element.chord.duration)) * pxPerQuarter
        return element.x ... (element.x + widthPx)
    }

    /// True when any two intervals overlap by more than `grace` points
    /// at both ends. Touching boundaries don't count: PDF coordinates
    /// have rounding noise, and adjacent quarters often share an x
    /// boundary by a fraction of a point.
    private static func anyOverlap(
        _ intervals: [ClosedRange<CGFloat>]
    ) -> Bool {
        let grace: CGFloat = 0.5
        for i in 0 ..< intervals.count {
            for j in (i + 1) ..< intervals.count {
                let a = intervals[i]
                let b = intervals[j]
                let lo = max(a.lowerBound, b.lowerBound)
                let hi = min(a.upperBound, b.upperBound)
                if hi - lo > grace { return true }
            }
        }
        return false
    }

    private static func voiceFor(
        _ element: RhythmElement, staffMidY: CGFloat
    ) -> Int {
        if element.isRest {
            return element.y > staffMidY ? 1 : 2
        }
        switch element.stemDirection {
        case .up: return 1
        case .down: return 2
        case .none: return element.y > staffMidY ? 1 : 2
        }
    }

    private static func quartersOfMeasure(
        timeSignature ts: TimeSignature
    ) -> Double {
        4.0 * Double(ts.numerator) / Double(ts.denominator)
    }

    private static func quartersOf(_ d: NoteDuration) -> Double {
        let f = d.asFraction
        return 4.0 * Double(f.numerator) / Double(f.denominator)
    }
}

// MARK: - Helpers

extension PDFImporter {
    /// Round x to the nearest point so coincident-but-jittered glyph
    /// positions hash to the same bucket when checking for voice
    /// collisions.
    fileprivate struct RoundedX: Hashable {
        let value: Int
        init(_ x: CGFloat) { value = Int((x * 2).rounded()) }
    }
}
