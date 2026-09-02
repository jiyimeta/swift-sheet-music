import Foundation
import SheetMusicCore

/// Score-vs-score semantic scoring, EXTRACTED VERBATIM from the untracked
/// real-corpus spike harness (PDFCorpusGroundTruthSpikeTests, main
/// worktree) so synthetic (OMR) and real-corpus numbers share one set of
/// definitions. Do not "improve" a metric here without re-running the
/// real corpus — the definitions are load-bearing for comparability.
///
/// Metric definitions (unchanged):
/// - pitch% / positional: per (part, first staff, measure, voice 0),
///   element-aligned pitch-list equality, counted per element.
/// - pitchSet%: per-measure pitch multiset match (position-insensitive).
/// - pitchedOnly: excludes percussion-clef staves in B.
/// - dur%: element-aligned NoteDuration equality (+ confusion pairs).
/// - tieRecall: tieForward/tieBack presence matched per aligned note.
/// - lyrRecall: token recall of lyric syllables per aligned measure.
///
/// Split across `ScoreSemanticMetrics{,+Extended,+Lyrics,+Report}.swift`
/// purely to respect the file-length cap; all members belong to this one
/// namespace.
enum ScoreSemanticMetrics {
    // MARK: - Result types

    /// Positionally-aligned tie confusion counts (avoids a 5-member
    /// tuple flagged by SwiftLint's large_tuple rule).
    struct TieResult {
        var aTied = 0, bTied = 0, tp = 0, fn = 0, fp = 0
    }

    /// Lyric-attachment correctness counters (avoids a 5-member tuple).
    struct LyricAttachResult {
        var measures = 0, exact = 0, tp = 0, tokA = 0, tokB = 0
    }

    struct PartAlignment {
        var scoreA: Score
        var scoreB: Score
        var partLossNotes = 0
        var partGainNotes = 0
    }

    // MARK: - R0 content-based part alignment (harness hygiene)

    /// Total note count across ALL staves of a part (empty-part test).
    static func partNoteCount(_ part: SheetMusicCore.Part) -> Int {
        var n = 0
        for staff in part.staves {
            for measure in staff.measures {
                for voice in measure.voices {
                    for el in voice.elements {
                        if case let .chord(c) = el { n += c.notes.count }
                    }
                }
            }
        }
        return n
    }

    /// R0 harness hygiene — content-based part alignment. MuseScore
    /// hides empty staves in the PDF, so Score A (mscz) can carry a
    /// zero-note part with no printed counterpart; raw index pairing
    /// then compares the wrong instruments downstream (catastrophic
    /// false %). Drop zero-note parts from BOTH sides, pair the
    /// remaining noteful parts by index, and count the notes in any
    /// unpaired noteful tail as partLossNotes (A side, real content
    /// loss — keeps cluster C2 visible even when the % look high) /
    /// partGainNotes (B side, spurious content). When neither side has
    /// a zero-note part and part counts are equal (exactly the curated
    /// 6), this reduces to the previous index pairing bit-for-bit.
    static func alignNotefulParts(
        scoreA: Score, scoreB: Score,
    ) -> PartAlignment {
        let aNoteful = scoreA.parts.filter { partNoteCount($0) > 0 }
        let bNoteful = scoreB.parts.filter { partNoteCount($0) > 0 }
        let paired = min(aNoteful.count, bNoteful.count)
        var out = PartAlignment(scoreA: scoreA, scoreB: scoreB)
        out.scoreA.parts = aNoteful
        out.scoreB.parts = bNoteful
        out.partLossNotes = aNoteful.dropFirst(paired)
            .reduce(0) { $0 + partNoteCount($1) }
        out.partGainNotes = bNoteful.dropFirst(paired)
            .reduce(0) { $0 + partNoteCount($1) }
        return out
    }

    // MARK: - Census

    static func measureRestCount(_ measure: Measure) -> Int {
        var n = 0
        for voice in measure.voices {
            for el in voice.elements {
                if case let .chord(c) = el, c.notes.isEmpty { n += 1 }
            }
        }
        return n
    }

    static func totalMeasures(_ score: Score) -> Int {
        score.parts
            .flatMap(\.staves)
            .map(\.measures.count)
            .max() ?? 0
    }

    static func contentTotals(
        _ score: Score,
    ) -> (notes: Int, rests: Int, chords: Int, elements: Int) {
        var notes = 0, rests = 0, chords = 0, elements = 0
        for part in score.parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for el in voice.elements {
                            elements += 1
                            if case let .chord(c) = el {
                                if c.notes.isEmpty {
                                    rests += 1
                                } else {
                                    chords += 1
                                    notes += c.notes.count
                                }
                            }
                        }
                    }
                }
            }
        }
        return (notes, rests, chords, elements)
    }

    // MARK: - Grace census

    static func gracePerPart(_ score: Score) -> [Int] {
        score.parts.map { part in
            var n = 0
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for el in voice.elements {
                            if case let .chord(c) = el {
                                n += c.graceNotesBefore.count + c.graceNotesAfter.count
                            }
                        }
                    }
                }
            }
            return n
        }
    }

    static func graceCount(_ score: Score) -> Int {
        gracePerPart(score).reduce(0, +)
    }

    static func durHistogram(_ score: Score) -> [String: Int] {
        var h: [String: Int] = [:]
        for part in score.parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for el in voice.elements {
                            if case let .chord(c) = el, !c.notes.isEmpty {
                                h[dur(c.duration), default: 0] += 1
                            }
                        }
                    }
                }
            }
        }
        return h
    }

    // MARK: - Generic aligners

    static func alignStaff<T: Equatable>(
        a: SheetMusicCore.Staff, b: SheetMusicCore.Staff,
        extract: (Measure) -> [T],
    ) -> (matched: Int, compared: Int) {
        let mCount = min(a.measures.count, b.measures.count)
        var matched = 0, compared = 0
        for mi in 0 ..< mCount {
            let pa = extract(a.measures[mi])
            let pb = extract(b.measures[mi])
            let n = min(pa.count, pb.count)
            for i in 0 ..< n where pa[i] == pb[i] {
                matched += 1
            }
            compared += max(pa.count, pb.count)
        }
        return (matched, compared)
    }

    static func matchSeq<T: Equatable>(_ a: [T], _ b: [T]) -> (Int, Int) {
        let n = min(a.count, b.count)
        var matched = 0
        for i in 0 ..< n where a[i] == b[i] {
            matched += 1
        }
        return (matched, n)
    }

    static func multisetIntersectionCount(_ a: [Int], _ b: [Int]) -> Int {
        var counts: [Int: Int] = [:]
        for v in a {
            counts[v, default: 0] += 1
        }
        var inter = 0
        for v in b where (counts[v] ?? 0) > 0 {
            counts[v, default: 0] -= 1
            inter += 1
        }
        return inter
    }

    // MARK: - Formatting helpers

    static func pctStr(_ m: Int, _ c: Int) -> String {
        c > 0 ? "\(100 * m / c)%" : "n/a"
    }

    static func dur(_ d: NoteDuration) -> String {
        switch d {
        case .whole: return "w"
        case .half: return "h"
        case .quarter: return "q"
        case .eighth: return "8"
        case .sixteenth: return "16"
        case .thirtySecond: return "32"
        case .sixtyFourth: return "64"
        case .measure: return "M"
        case let .fraction(f): return "\(f.numerator)/\(f.denominator)"
        default: return "?"
        }
    }
}
