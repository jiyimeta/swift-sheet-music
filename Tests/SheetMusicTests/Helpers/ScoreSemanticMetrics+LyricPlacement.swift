import Foundation
import SheetMusicCore

/// Script bucket of one lyric character, for the per-script placement counts.
enum LyricScript { case kanaKanji, latin, other }

/// Per-character placement tallies for one script (or for all of them).
struct LyricPlacementCounts: Equatable {
    var truthChars = 0, on = 0, oneOff = 0, far = 0, missing = 0, extra = 0, edits = 0
}

/// `total` includes `other` (digits, punctuation), which has no bucket of its own.
struct LyricPlacementResult: Equatable {
    var total = LyricPlacementCounts(), kanaKanji = LyricPlacementCounts(), latin = LyricPlacementCounts()
}

/// Per-character lyric placement: how many of the read lyric characters land on the chord the truth put them on.
/// Unlike `lyrRecall` (token recall per measure), this scores the note each character is attached to.
extension ScoreSemanticMetrics {
    /// One lyric character with the measure and chord slot it sits on.
    private struct PlacedChar {
        var char: Character
        var measure: Int
        var chordIndex: Int
    }

    /// Per-character lyric placement of `scoreB` (read) against `scoreA` (truth), per script and in total.
    /// Both scores must already be part-aligned (`alignNotefulParts` output).
    static func lyricPlacement(scoreA: Score, scoreB: Score) -> LyricPlacementResult {
        var result = LyricPlacementResult()
        let nParts = min(scoreA.parts.count, scoreB.parts.count)
        for pi in 0 ..< nParts {
            let staffsA = scoreA.parts[pi].staves
            let staffsB = scoreB.parts[pi].staves
            for si in 0 ..< min(staffsA.count, staffsB.count) {
                placeStaff(a: staffsA[si], b: staffsB[si], into: &result)
            }
        }
        return result
    }

    /// Kana / kanji, other Unicode letters (Latin), or anything else (digits, punctuation, symbols).
    /// Its own table: `PDFImporter.isFullWidth` is private and also counts Hangul and symbols.
    static func lyricScript(_ c: Character) -> LyricScript {
        if let scalar = c.unicodeScalars.first {
            let v = scalar.value
            let isKanaKanji = (0x3005 ... 0x3006).contains(v)
                || (0x3041 ... 0x30FF).contains(v)
                || (0x3400 ... 0x4DBF).contains(v)
                || (0x4E00 ... 0x9FFF).contains(v)
                || (0xF900 ... 0xFAFF).contains(v)
                || (0xFF66 ... 0xFF9F).contains(v)
            if isKanaKanji { return .kanaKanji }
        }
        return c.isLetter ? .latin : .other
    }

    // MARK: - Staff / verse streams

    private static func placeStaff(
        a: SheetMusicCore.Staff, b: SheetMusicCore.Staff, into result: inout LyricPlacementResult,
    ) {
        let countA = a.measures.map { chordCount($0) }
        var startA: [Int] = []
        var running = 0
        for n in countA {
            startA.append(running)
            running += n
        }
        let streamsA = verseStreams(a)
        let streamsB = verseStreams(b)
        for verse in Set(streamsA.keys).union(streamsB.keys).sorted() {
            align(
                truth: streamsA[verse] ?? [], read: streamsB[verse] ?? [],
                countA: countA, startA: startA, into: &result,
            )
        }
    }

    /// Chords counted exactly as `measurePitches` does: voices in order, elements in order, non-empty chords only.
    private static func chordCount(_ measure: Measure) -> Int {
        var n = 0
        for voice in measure.voices {
            for el in voice.elements {
                if case let .chord(c) = el, !c.notes.isEmpty { n += 1 }
            }
        }
        return n
    }

    /// Lyric characters of one staff per verse, in measure / voice / chord order. Whitespace, `-` and `_` are dropped.
    private static func verseStreams(_ staff: SheetMusicCore.Staff) -> [Int: [PlacedChar]] {
        var out: [Int: [PlacedChar]] = [:]
        for (mi, measure) in staff.measures.enumerated() {
            var chordIndex = 0
            for voice in measure.voices {
                for el in voice.elements {
                    guard case let .chord(c) = el, !c.notes.isEmpty else { continue }
                    for lyric in c.lyrics {
                        for ch in lyric.text where !ch.isWhitespace && ch != "-" && ch != "_" {
                            out[lyric.verse, default: []].append(
                                PlacedChar(char: ch, measure: mi, chordIndex: chordIndex),
                            )
                        }
                    }
                    chordIndex += 1
                }
            }
        }
        return out
    }

    // MARK: - Edit-distance alignment

    private static func align(
        truth: [PlacedChar], read: [PlacedChar], countA: [Int], startA: [Int],
        into result: inout LyricPlacementResult,
    ) {
        let n = truth.count, m = read.count
        let width = m + 1
        var dp = [Int32](repeating: 0, count: (n + 1) * width)
        for i in 0 ... n {
            dp[i * width] = Int32(i)
        }
        for j in 0 ... m {
            dp[j] = Int32(j)
        }
        if n > 0, m > 0 {
            for i in 1 ... n {
                for j in 1 ... m {
                    let sub = dp[(i - 1) * width + j - 1] + (truth[i - 1].char == read[j - 1].char ? 0 : 1)
                    dp[i * width + j] = min(sub, dp[(i - 1) * width + j] + 1, dp[i * width + j - 1] + 1)
                }
            }
        }

        for t in truth {
            update(&result, lyricScript(t.char)) { $0.truthChars += 1 }
        }

        var i = n, j = m
        while i > 0 || j > 0 {
            let here = dp[i * width + j]
            if i > 0, j > 0 {
                let same = truth[i - 1].char == read[j - 1].char
                if here == dp[(i - 1) * width + j - 1] + (same ? 0 : 1) {
                    let distance = placementDistance(
                        truth: truth[i - 1], read: read[j - 1], countA: countA, startA: startA,
                    )
                    update(&result, lyricScript(truth[i - 1].char)) { counts in
                        switch distance {
                        case 0: counts.on += 1
                        case 1: counts.oneOff += 1
                        default: counts.far += 1
                        }
                        if !same { counts.edits += 1 }
                    }
                    i -= 1; j -= 1
                    continue
                }
            }
            if i > 0, here == dp[(i - 1) * width + j] + 1 {
                update(&result, lyricScript(truth[i - 1].char)) { $0.missing += 1; $0.edits += 1 }
                i -= 1
            } else {
                update(&result, lyricScript(read[j - 1].char)) { $0.extra += 1; $0.edits += 1 }
                j -= 1
            }
        }
    }

    /// `|globalA − mappedB|`, or `Int.max` (far) when the read character has no chord to map to.
    private static func placementDistance(
        truth: PlacedChar, read: PlacedChar, countA: [Int], startA: [Int],
    ) -> Int {
        guard read.measure < countA.count, countA[read.measure] > 0,
              truth.measure < startA.count else { return .max }
        let globalA = startA[truth.measure] + truth.chordIndex
        let mapped = startA[read.measure] + min(read.chordIndex, countA[read.measure] - 1)
        return abs(globalA - mapped)
    }

    /// Applies `change` to the total and to the script's own bucket (`other` has none).
    private static func update(
        _ result: inout LyricPlacementResult, _ script: LyricScript,
        _ change: (inout LyricPlacementCounts) -> Void,
    ) {
        change(&result.total)
        switch script {
        case .kanaKanji: change(&result.kanaKanji)
        case .latin: change(&result.latin)
        case .other: break
        }
    }
}
