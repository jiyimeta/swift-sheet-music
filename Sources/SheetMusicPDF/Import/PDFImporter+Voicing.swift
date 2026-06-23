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
        location: String = "",
    ) -> [Voice] {
        guard !elements.isEmpty else { return [] }
        // A measure is two-voice only when two elements share an x ONSET
        // — i.e. they begin at (near) the same horizontal position, the
        // visual signature of two simultaneous voices. A single melodic
        // line never stacks two onsets at the same x.
        //
        // The previous trigger — temporal-interval overlap from estimated
        // durations — fired spuriously: with beam-based durations not yet
        // decoded, every beamed run reads as `.quarter`, inflating each
        // note's estimated width so x-adjacent notes "overlapped" and a
        // single melodic line scattered across two voices (observed: 116
        // phantom two-voice measures and 245 measures with an empty voice 0
        // against a score that is entirely single-voice). Coincident x
        // onset is the robust, duration-independent signal.
        if hasCoincidentOnset(elements) {
            return splitIntoTwoVoices(
                elements: elements,
                staffMidY: staffMidY,
                diagnostics: diagnostics,
                location: location,
            )
        }
        // Single voice: keep every element in x-order in voice 0, matching
        // A's single-voice indexing.
        let ordered = elements.sorted { $0.x < $1.x }
        return [Voice(elements: ordered.map { .chord($0.chord) })]
    }

    /// True when two distinct elements begin at (near) the same x. A
    /// notehead and its own chord-mates already collapsed into one
    /// `RhythmElement` upstream, so two elements at the same x genuinely
    /// represent two voices sounding together. Tolerance ~half a notehead
    /// (3pt) absorbs PDF coordinate jitter.
    private static func hasCoincidentOnset(_ elements: [RhythmElement]) -> Bool {
        let xs = elements.map(\.x).sorted()
        for i in 1 ..< xs.count where abs(xs[i] - xs[i - 1]) < 3 {
            return true
        }
        return false
    }

    private static func splitIntoTwoVoices(
        elements: [RhythmElement],
        staffMidY: CGFloat,
        diagnostics: ((PDFImportDiagnostic) -> Void)?,
        location: String,
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
        location: String,
    ) {
        diagnostics?(PDFImportDiagnostic(
            severity: .warning,
            location: location,
            message: "Voice 3+ collapsed into voice 1/2",
        ))
    }
}

// MARK: - Voice placement

extension PDFImporter {
    private static func voiceFor(
        _ element: RhythmElement, staffMidY: CGFloat,
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
}

// MARK: - Helpers

extension PDFImporter {
    /// Round x to the nearest point so coincident-but-jittered glyph
    /// positions hash to the same bucket when checking for voice
    /// collisions.
    fileprivate struct RoundedX: Hashable {
        let value: Int
        init(_ x: CGFloat) {
            value = Int((x * 2).rounded())
        }
    }
}
