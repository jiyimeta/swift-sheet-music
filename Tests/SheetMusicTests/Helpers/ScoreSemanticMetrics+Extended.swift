import Foundation
import SheetMusicCore

/// Aligned-content metric families (pitch, duration, tie, running
/// clef/key/time state), EXTRACTED VERBATIM from the untracked
/// real-corpus spike harness. See `ScoreSemanticMetrics.swift` for the
/// definition contract — do not "improve" a metric here.
extension ScoreSemanticMetrics {
    // MARK: - Pitch (aligned + multiset)

    static func measureAlignedPitchMatch(
        scoreA: Score, scoreB: Score, pitchedOnly: Bool = false,
    ) -> (pos: (m: Int, c: Int), set: (m: Int, c: Int)) {
        let nParts = min(scoreA.parts.count, scoreB.parts.count)
        var posM = 0, posC = 0, setM = 0, setC = 0
        for pi in 0 ..< nParts {
            guard let sa = scoreA.parts[pi].staves.first,
                  let sb = scoreB.parts[pi].staves.first else { continue }
            if pitchedOnly, staffIsPercussion(sb) { continue }
            let (m, c) = alignStaffPitches(a: sa, b: sb)
            posM += m; posC += c
            let (ms, cs) = alignStaffMultiset(a: sa, b: sb)
            setM += ms; setC += cs
        }
        return ((posM, posC), (setM, setC))
    }

    /// True when this staff carries a percussion clef anywhere — its
    /// notes are GM drumset key numbers, not pitch-meaningful.
    static func staffIsPercussion(_ staff: SheetMusicCore.Staff) -> Bool {
        for measure in staff.measures {
            for voice in measure.voices {
                for el in voice.elements {
                    if case let .clef(c) = el,
                       c.concertClefType == "PERCUSSION" { return true }
                }
            }
        }
        return false
    }

    static func alignStaffPitches(
        a: SheetMusicCore.Staff, b: SheetMusicCore.Staff,
    ) -> (matched: Int, compared: Int) {
        let mCount = min(a.measures.count, b.measures.count)
        var matched = 0, compared = 0
        for mi in 0 ..< mCount {
            let pa = measurePitches(a.measures[mi])
            let pb = measurePitches(b.measures[mi])
            let n = min(pa.count, pb.count)
            for i in 0 ..< n where pa[i] == pb[i] {
                matched += 1
            }
            compared += max(pa.count, pb.count)
        }
        return (matched, compared)
    }

    static func alignStaffMultiset(
        a: SheetMusicCore.Staff, b: SheetMusicCore.Staff,
    ) -> (matched: Int, compared: Int) {
        let mCount = min(a.measures.count, b.measures.count)
        var matched = 0, compared = 0
        for mi in 0 ..< mCount {
            let pa = measurePitches(a.measures[mi])
            let pb = measurePitches(b.measures[mi])
            matched += multisetIntersectionCount(pa, pb)
            compared += max(pa.count, pb.count)
        }
        return (matched, compared)
    }

    static func measurePitches(_ measure: Measure) -> [Int] {
        var out: [Int] = []
        for voice in measure.voices {
            for el in voice.elements {
                if case let .chord(c) = el, !c.notes.isEmpty {
                    out.append(c.notes[c.notes.startIndex].pitch)
                }
            }
        }
        return out
    }

    // MARK: - Duration (aligned + confusion)

    static func measureAlignedDurationMatch(
        scoreA: Score, scoreB: Score,
    ) -> (match: (m: Int, c: Int), confusion: [(key: String, value: Int)]) {
        let nParts = min(scoreA.parts.count, scoreB.parts.count)
        var matchM = 0, matchC = 0
        var confusion: [String: Int] = [:]
        for pi in 0 ..< nParts {
            guard let sa = scoreA.parts[pi].staves.first,
                  let sb = scoreB.parts[pi].staves.first else { continue }
            let (m, c) = alignStaff(a: sa, b: sb, extract: measureNoteDurations)
            matchM += m; matchC += c
            let mCount = min(sa.measures.count, sb.measures.count)
            for mi in 0 ..< mCount {
                let da = measureNoteDurations(sa.measures[mi])
                let db = measureNoteDurations(sb.measures[mi])
                for i in 0 ..< min(da.count, db.count) where da[i] != db[i] {
                    confusion["\(dur(da[i]))->\(dur(db[i]))", default: 0] += 1
                }
            }
        }
        let top = confusion.sorted { $0.value > $1.value }.prefix(8)
        return ((matchM, matchC), Array(top))
    }

    static func measureNoteDurations(_ measure: Measure) -> [NoteDuration] {
        var out: [NoteDuration] = []
        for voice in measure.voices {
            for el in voice.elements {
                if case let .chord(c) = el, !c.notes.isEmpty {
                    out.append(c.duration)
                }
            }
        }
        return out
    }

    // MARK: - Tie (recall / precision)

    static func measureAlignedTieMatch(
        scoreA: Score, scoreB: Score,
    ) -> TieResult {
        let nParts = min(scoreA.parts.count, scoreB.parts.count)
        var r = TieResult()
        for pi in 0 ..< nParts {
            guard let sa = scoreA.parts[pi].staves.first,
                  let sb = scoreB.parts[pi].staves.first else { continue }
            let mCount = min(sa.measures.count, sb.measures.count)
            for mi in 0 ..< mCount {
                let ta = measureNoteTies(sa.measures[mi])
                let tb = measureNoteTies(sb.measures[mi])
                r.aTied += ta.count { $0 }
                r.bTied += tb.count { $0 }
                for i in 0 ..< min(ta.count, tb.count) {
                    if ta[i], tb[i] {
                        r.tp += 1
                    } else if ta[i], !tb[i] {
                        r.fn += 1
                    } else if !ta[i], tb[i] {
                        r.fp += 1
                        if ProcessInfo.processInfo
                            .environment["PDF_TIE_FP_PROBE"] == "1"
                        {
                            print(
                                "[tieFP] part=\(pi) mi=\(mi) ci=\(i) "
                                    + "b=\(chordTieDesc(sb.measures[mi], i))",
                            )
                        }
                    }
                }
            }
        }
        return r
    }

    /// Probe helper: describe the `i`-th chord's ties + pitches in a
    /// measure (temporary forensic; PDF_TIE_FP_PROBE=1).
    static func chordTieDesc(_ measure: Measure, _ index: Int) -> String {
        var ci = 0
        for voice in measure.voices {
            for el in voice.elements {
                if case let .chord(c) = el, !c.notes.isEmpty {
                    if ci == index {
                        let notes = c.notes.map { n in
                            "\(n.pitch)"
                                + (n.tieForward != nil ? "→" : "")
                                + (n.tieBack != nil ? "←" : "")
                        }
                        return "dur=\(c.duration) \(notes.joined(separator: ","))"
                    }
                    ci += 1
                }
            }
        }
        return "?"
    }

    static func measureNoteTies(_ measure: Measure) -> [Bool] {
        var out: [Bool] = []
        for voice in measure.voices {
            for el in voice.elements {
                if case let .chord(c) = el, !c.notes.isEmpty {
                    let tied = (c.notes.startIndex ..< c.notes.endIndex)
                        .contains {
                            c.notes[$0].tieForward != nil
                                || c.notes[$0].tieBack != nil
                        }
                    out.append(tied)
                }
            }
        }
        return out
    }

    // MARK: - Clef / key / time running match

    static func perMeasureStateMatch(
        scoreA: Score, scoreB: Score,
    ) -> (clef: (m: Int, c: Int), key: (m: Int, c: Int), time: (m: Int, c: Int)) {
        let nParts = min(scoreA.parts.count, scoreB.parts.count)
        var clefM = 0, clefC = 0, keyM = 0, keyC = 0, timeM = 0, timeC = 0
        for pi in 0 ..< nParts {
            guard let sa = scoreA.parts[pi].staves.first,
                  let sb = scoreB.parts[pi].staves.first else { continue }
            let (cm, cc) = matchSeq(runningClefs(sa), runningClefs(sb))
            let (km, kc) = matchSeq(runningKeys(sa), runningKeys(sb))
            let (tm, tc) = matchSeq(runningTimes(sa), runningTimes(sb))
            clefM += cm; clefC += cc
            keyM += km; keyC += kc
            timeM += tm; timeC += tc
        }
        return ((clefM, clefC), (keyM, keyC), (timeM, timeC))
    }

    static func runningClefs(_ staff: SheetMusicCore.Staff) -> [String] {
        var out: [String] = []
        var cur = "G"
        for measure in staff.measures {
            for voice in measure.voices {
                for el in voice.elements {
                    if case let .clef(c) = el { cur = c.concertClefType }
                }
            }
            out.append(cur)
        }
        return out
    }

    static func runningKeys(_ staff: SheetMusicCore.Staff) -> [Int] {
        var out: [Int] = []
        var cur = 0
        for measure in staff.measures {
            for voice in measure.voices {
                for el in voice.elements {
                    if case let .keySignature(k) = el { cur = k.concertKey }
                }
            }
            out.append(cur)
        }
        return out
    }

    static func runningTimes(_ staff: SheetMusicCore.Staff) -> [String] {
        var out: [String] = []
        var cur = "4/4"
        for measure in staff.measures {
            for voice in measure.voices {
                for el in voice.elements {
                    if case let .timeSignature(t) = el {
                        cur = "\(t.numerator)/\(t.denominator)"
                    }
                }
            }
            out.append(cur)
        }
        return out
    }
}
