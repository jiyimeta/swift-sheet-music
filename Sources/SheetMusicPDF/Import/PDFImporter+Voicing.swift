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
        // Permutation shared with the geometry collector (`voiceAssignment`)
        // so the side-car's element indices always match the voices built
        // here. A two-voice measure always emits exactly two voices (the
        // second may be empty), matching A's indexing.
        let placements = voiceAssignment(elements: elements, staffMidY: staffMidY)
        let voiceCount = hasCoincidentOnset(elements) ? 2 : 1
        var ordered = [[(position: Int, element: RhythmElement)]](
            repeating: [], count: voiceCount,
        )
        for (i, p) in placements.enumerated() {
            ordered[p.voice].append((p.position, elements[i]))
        }
        return ordered.map { bucket -> Voice in
            var elems: [VoiceElement] = []
            var occupied: Set<RoundedX> = []
            for (_, u) in bucket.sorted(by: { $0.position < $1.position }) {
                let key = RoundedX(u.x)
                if occupied.contains(key) {
                    emitVoice3Warning(diagnostics, location: location)
                }
                elems.append(.chord(u.chord))
                occupied.insert(key)
            }
            return Voice(elements: elems)
        }
    }

    /// Pure permutation `assignVoices` applies, exposed so the geometry
    /// collector can learn each element's final (voiceIndex, position)
    /// without re-deriving the value path. One entry per input element, in
    /// INPUT order; uses the same `hasCoincidentOnset` / `voiceFor`
    /// decisions `assignVoices` uses, so the two never disagree.
    static func voiceAssignment(
        elements: [RhythmElement], staffMidY: CGFloat,
    ) -> [(voice: Int, position: Int)] {
        guard !elements.isEmpty else { return [] }
        if hasCoincidentOnset(elements) {
            var result = [(voice: Int, position: Int)](
                repeating: (0, 0), count: elements.count,
            )
            var counts = [0, 0]
            for (i, u) in elements.enumerated() {
                // voiceFor == 1 (stem-up / high) → voice index 0 (v1);
                // else → voice index 1 (v2). Mirrors the [v1, v2] order.
                let v = voiceFor(u, staffMidY: staffMidY) == 1 ? 0 : 1
                result[i] = (v, counts[v])
                counts[v] += 1
            }
            return result
        }
        // Single voice: x-sorted into voice 0; position = rank in x.
        let order = elements.enumerated()
            .sorted { $0.element.x < $1.element.x }
            .map(\.offset)
        var result = [(voice: Int, position: Int)](
            repeating: (0, 0), count: elements.count,
        )
        for (pos, inputIdx) in order.enumerated() {
            result[inputIdx] = (0, pos)
        }
        return result
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
