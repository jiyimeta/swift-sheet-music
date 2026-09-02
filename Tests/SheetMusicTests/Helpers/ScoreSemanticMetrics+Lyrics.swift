import Foundation
import SheetMusicCore

/// Lyric census and attachment metrics, EXTRACTED VERBATIM from the
/// untracked real-corpus spike harness. See `ScoreSemanticMetrics.swift`
/// for the definition contract — do not "improve" a metric here.
extension ScoreSemanticMetrics {
    static func lyricStats(_ score: Score) -> (count: Int, perPart: [Int]) {
        var perPart: [Int] = []
        for part in score.parts {
            var n = 0
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for el in voice.elements {
                            if case let .chord(c) = el {
                                n += c.lyrics.count { !$0.text.isEmpty }
                            }
                        }
                    }
                }
            }
            perPart.append(n)
        }
        return (perPart.reduce(0, +), perPart)
    }

    static func lyricAttachment(
        scoreA: Score, scoreB: Score,
    ) -> LyricAttachResult {
        let nParts = min(scoreA.parts.count, scoreB.parts.count)
        var r = LyricAttachResult()
        for pi in 0 ..< nParts {
            guard let sa = scoreA.parts[pi].staves.first,
                  let sb = scoreB.parts[pi].staves.first else { continue }
            let mc = min(sa.measures.count, sb.measures.count)
            for mi in 0 ..< mc {
                let la = measureLyrics(sa.measures[mi])
                let lb = measureLyrics(sb.measures[mi])
                if la.isEmpty, lb.isEmpty { continue }
                r.measures += 1
                if la == lb { r.exact += 1 }
                r.tokA += la.count
                r.tokB += lb.count
                r.tp += multisetIntersectionCount(
                    la.map { hashStr($0) }, lb.map { hashStr($0) },
                )
            }
        }
        return r
    }

    static func hashStr(_ s: String) -> Int {
        var h = 5381
        for b in s.unicodeScalars {
            h = (h &* 33) &+ Int(b.value)
        }
        return h
    }

    static func measureLyrics(_ measure: Measure) -> [String] {
        var out: [String] = []
        for voice in measure.voices {
            for el in voice.elements {
                if case let .chord(c) = el {
                    for ly in c.lyrics where ly.verse == 0 && !ly.text.isEmpty {
                        out.append(ly.text)
                    }
                }
            }
        }
        return out
    }
}
