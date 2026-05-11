import CoreGraphics
import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Walk a staff's measures left-to-right and emit score-state
    /// events (clef changes, key signatures, time signatures, tempos).
    ///
    /// Per measure we scan glyphs in left-to-right x-order and emit at
    /// most one clef, one key signature, and one time signature event.
    /// Tempos are extracted from the page's text glyphs and tied to
    /// measure 0 of the staff (best-effort).
    static func scoreStateEvents(
        staff: ImportStaff, texts: [TextGlyph],
    ) -> [ScoreStateEvent] {
        var events: [ScoreStateEvent] = []
        for (i, measure) in staff.measures.enumerated() {
            let sorted = measure.glyphs.sorted { $0.raw.origin.x < $1.raw.origin.x }
            if let clef = readClef(from: sorted) {
                events.append(.clefChange(clef, atMeasureIndex: i))
            }
            if let key = readKey(from: sorted) {
                events.append(.keySignature(key, atMeasureIndex: i))
            }
            if let timeSig = readTime(from: sorted) {
                events.append(.timeSignature(timeSig, atMeasureIndex: i))
            }
        }
        for tempo in extractTempos(texts: texts) {
            events.append(.tempo(tempo, atMeasureIndex: 0))
        }
        return events
    }

    // MARK: - Clef

    private static func readClef(from glyphs: [ClassifiedGlyph]) -> Clef? {
        for glyph in glyphs {
            switch glyph.semantic {
            case .clefG: return Clef(concertClefType: "G")
            case .clefF: return Clef(concertClefType: "F")
            case .clefC: return Clef(concertClefType: "C")
            case .clefPercussion: return Clef(concertClefType: "PERCUSSION")
            case .noteheadBlack, .noteheadHalf, .noteheadWhole, .noteheadDoubleWhole:
                return nil
            default: continue
            }
        }
        return nil
    }

    // MARK: - Key signature

    private static func readKey(from glyphs: [ClassifiedGlyph]) -> KeySignature? {
        var sharps = 0
        var flats = 0
        for glyph in glyphs {
            switch glyph.semantic {
            case .accidentalSharp:
                sharps += 1
            case .accidentalFlat:
                flats += 1
            case .noteheadBlack, .noteheadHalf, .noteheadWhole, .noteheadDoubleWhole:
                // Stop at the first notehead — anything after is a note,
                // not part of the leading key signature.
                return finalize(sharps: sharps, flats: flats)
            default: continue
            }
        }
        return finalize(sharps: sharps, flats: flats)
    }

    private static func finalize(sharps: Int, flats: Int) -> KeySignature? {
        if sharps > 0 { return KeySignature(concertKey: sharps) }
        if flats > 0 { return KeySignature(concertKey: -flats) }
        return nil
    }

    // MARK: - Time signature

    private static func readTime(from glyphs: [ClassifiedGlyph]) -> TimeSignature? {
        for glyph in glyphs {
            switch glyph.semantic {
            case .timeSignatureCommon:
                return TimeSignature(numerator: 4, denominator: 4)
            case .timeSignatureCutTime:
                return TimeSignature(numerator: 2, denominator: 2)
            case .timeSignatureDigit:
                return parseStackedDigits(from: glyphs)
            case .noteheadBlack, .noteheadHalf, .noteheadWhole, .noteheadDoubleWhole:
                return nil
            default: continue
            }
        }
        return nil
    }

    /// Group digit glyphs by x-cluster (within 3pt). Within a cluster
    /// the higher-y glyph is the numerator and the lower-y glyph is
    /// the denominator. Side-by-side digits (two distinct x-clusters)
    /// are read as `num / denom`.
    private static func parseStackedDigits(
        from glyphs: [ClassifiedGlyph],
    ) -> TimeSignature? {
        let digits = collectDigits(from: glyphs)
        guard !digits.isEmpty else { return nil }
        let clusters = clusterDigitsByX(digits)
        let firstCluster = clusters[0]
        if firstCluster.count >= 2 {
            let sortedByY = firstCluster.sorted { $0.y > $1.y }
            return TimeSignature(
                numerator: sortedByY[0].n,
                denominator: sortedByY[1].n,
            )
        }
        if clusters.count >= 2 {
            return TimeSignature(
                numerator: firstCluster[0].n,
                denominator: clusters[1][0].n,
            )
        }
        return TimeSignature(numerator: firstCluster[0].n, denominator: 4)
    }

    private struct DigitGlyph {
        var x: CGFloat
        var y: CGFloat
        var n: Int
    }

    private static func collectDigits(
        from glyphs: [ClassifiedGlyph],
    ) -> [DigitGlyph] {
        glyphs.compactMap { g in
            if case let .timeSignatureDigit(n) = g.semantic {
                return DigitGlyph(x: g.raw.origin.x, y: g.raw.origin.y, n: n)
            }
            return nil
        }
    }

    private static func clusterDigitsByX(
        _ digits: [DigitGlyph],
    ) -> [[DigitGlyph]] {
        let sorted = digits.sorted { $0.x < $1.x }
        var clusters: [[DigitGlyph]] = []
        for digit in sorted {
            if let lastDigit = clusters.last?.last,
               abs(digit.x - lastDigit.x) < 3
            {
                clusters[clusters.count - 1].append(digit)
            } else {
                clusters.append([digit])
            }
        }
        return clusters
    }

    // MARK: - Tempo

    /// Best-effort tempo extraction. Looks for `= NN` anywhere in the
    /// text and emits `Tempo(beatsPerSecond: NN/60)`. Text-only tempo
    /// markings without a numeric equation are skipped.
    private static func extractTempos(texts: [TextGlyph]) -> [Tempo] {
        var out: [Tempo] = []
        for text in texts {
            if let bpm = parseBpm(from: text.text) {
                out.append(Tempo(beatsPerSecond: Double(bpm) / 60.0))
            }
        }
        return out
    }

    private static func parseBpm(from text: String) -> Int? {
        guard let equalsIdx = text.lastIndex(of: "=") else { return nil }
        let after = text[text.index(after: equalsIdx)...]
            .trimmingCharacters(in: .whitespaces)
        let numericPrefix = after.prefix { $0.isNumber }
        guard !numericPrefix.isEmpty,
              let bpm = Int(numericPrefix), bpm > 0 else { return nil }
        return bpm
    }
}
