import Foundation
import SheetMusicCore

/// Reporting surface over the extracted metrics: the machine-greppable
/// `[SUMMARY]` row and a first-divergence localizer. New code (not
/// extracted), but the summary row's field set and order are copied
/// from the real-corpus spike so TSV snapshots diff across corpora.
extension ScoreSemanticMetrics {
    /// One-line machine-greppable summary row — SAME field set and
    /// order as the real-corpus spike's `[SUMMARY]` row, so TSV
    /// snapshots diff across synthetic and real corpora.
    static func summaryRow(
        tag: String, scoreA: Score, scoreB: Score,
        pdfRecovered: Bool, aligned: PartAlignment, hiddenLoss: Int,
    ) -> String {
        let alignedA = aligned.scoreA
        let alignedB = aligned.scoreB
        let pitchRes = measureAlignedPitchMatch(scoreA: alignedA, scoreB: alignedB)
        let pitchedRes = measureAlignedPitchMatch(
            scoreA: alignedA, scoreB: alignedB, pitchedOnly: true,
        )
        let durRes = measureAlignedDurationMatch(scoreA: alignedA, scoreB: alignedB)
        let tieRes = measureAlignedTieMatch(scoreA: alignedA, scoreB: alignedB)
        let lyrAttach = lyricAttachment(scoreA: alignedA, scoreB: alignedB)
        let aStaves = scoreA.parts.reduce(0) { $0 + $1.staves.count }
        let bStaves = scoreB.parts.reduce(0) { $0 + $1.staves.count }
        let ta = contentTotals(scoreA)
        let tb = contentTotals(scoreB)
        return "\(tag)[SUMMARY] mscz=Y pdf=\(pdfRecovered ? "Y" : "N") "
            + "partsA=\(scoreA.parts.count) partsB=\(scoreB.parts.count) "
            + "stavesA=\(aStaves) stavesB=\(bStaves) "
            + "measuresA=\(totalMeasures(scoreA)) measuresB=\(totalMeasures(scoreB)) "
            + "notesA=\(ta.notes) notesB=\(tb.notes) "
            + "restsA=\(ta.rests) restsB=\(tb.rests) "
            + "graceA=\(graceCount(scoreA)) graceB=\(graceCount(scoreB)) "
            + "pitch%=\(pctStr(pitchRes.pos.m, pitchRes.pos.c)) "
            + "pitchedOnly%=\(pctStr(pitchedRes.pos.m, pitchedRes.pos.c)) "
            + "pitchSet%=\(pctStr(pitchRes.set.m, pitchRes.set.c)) "
            + "dur%=\(pctStr(durRes.match.m, durRes.match.c)) "
            + "tieRecall=\(pctStr(tieRes.tp, tieRes.tp + tieRes.fn)) "
            + "lyrRecall=\(pctStr(lyrAttach.tp, lyrAttach.tokA)) "
            + "partsAeff=\(alignedA.parts.count) partsBeff=\(alignedB.parts.count) "
            + "partLoss=\(aligned.partLossNotes) partGain=\(aligned.partGainNotes) "
            + "hiddenLoss=\(hiddenLoss)"
    }

    /// First-divergence report following the MidiSemanticComparison
    /// pattern (Tests/SheetMusicTests/Helpers/MidiSemanticComparison.swift):
    /// find the first differing measure, print it with `window` measures
    /// of context on both sides. Returns nil when no divergence.
    static func firstDivergenceReport(
        scoreA: Score, scoreB: Score, window: Int = 2,
    ) -> String? {
        let nParts = min(scoreA.parts.count, scoreB.parts.count)
        for pi in 0 ..< nParts {
            guard let sa = scoreA.parts[pi].staves.first,
                  let sb = scoreB.parts[pi].staves.first else { continue }
            let n = min(sa.measures.count, sb.measures.count)
            for mi in 0 ..< n where measureDump(sa.measures[mi]) != measureDump(sb.measures[mi]) {
                let lo = max(0, mi - window)
                let hi = min(n, mi + window + 1)
                var out = "first divergence: part \(pi) measure \(mi)\n"
                for k in lo ..< hi {
                    out += "  A[\(k)]: \(measureDump(sa.measures[k]))\n"
                    out += "  B[\(k)]: \(measureDump(sb.measures[k]))\n"
                }
                return out
            }
            if sa.measures.count != sb.measures.count {
                return "first divergence: part \(pi) measure count "
                    + "A=\(sa.measures.count) B=\(sb.measures.count)"
            }
        }
        return nil
    }

    /// Compact one-line dump of a measure's voice-0..n content:
    /// `c(60.64)q` = chord of pitches 60+64, quarter; `r`… = rest.
    static func measureDump(_ m: Measure) -> String {
        m.voices.enumerated().map { vi, v in
            let body = v.elements.compactMap { el -> String? in
                switch el {
                case let .chord(c):
                    let d = dur(c.duration)
                    if c.notes.isEmpty { return "r\(d)" }
                    let pitches = c.notes.map { n in
                        String(n.pitch)
                            + (n.tieForward != nil ? ">" : "")
                            + (n.tieBack != nil ? "<" : "")
                    }.joined(separator: ".")
                    return "c(\(pitches))\(d)"
                case let .timeSignature(t):
                    return "TS\(t.numerator)/\(t.denominator)"
                case let .clef(c):
                    return "CL\(c.concertClefType)"
                case .keySignature:
                    return "KS"
                default:
                    return nil
                }
            }.joined(separator: " ")
            return "v\(vi)[\(body)]"
        }.joined(separator: " ")
    }
}
