#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicCore

    /// The lyric / title / tempo rows of the ground-truth sweep, split out of `MSCZGroundTruthSweep` to keep its
    /// body inside the lint budget.
    extension MSCZGroundTruthSweep {
        /// Lyric placement summed over the scored files, plus the scored files whose truth has a title / tempo and
        /// how many of those the read score matched.
        struct TextTotals {
            var lyrics = LyricPlacementResult()
            var titleTruth = 0
            var titleMatch = 0
            var titleNormMatch = 0
            var tempoTruth = 0
            var tempoMatch = 0
        }

        static func durationSeconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }

        /// The lyric / title / tempo rows, printed after the unchanged `summaryRow` so the existing row's shape
        /// stays byte-identical. Lyrics use the same part-aligned scores as the other metrics.
        static func scoreText(
            _ item: Case, aligned: (truth: Score, read: Score), original: (truth: Score, read: Score),
            mode: Mode, totals: inout Totals,
        ) {
            // `all` also counts characters outside the ja / latin buckets (digits, punctuation).
            let lyrics = ScoreSemanticMetrics.lyricPlacement(scoreA: aligned.truth, scoreB: aligned.read)
            func fields(_ key: String, _ c: LyricPlacementCounts) -> String {
                "\(key)Truth=\(c.truthChars) \(key)On=\(c.on) \(key)OneOff=\(c.oneOff) \(key)Far=\(c.far) "
                    + "\(key)Missing=\(c.missing) \(key)Extra=\(c.extra) \(key)Edits=\(c.edits)"
            }
            print("[mscz-lyrics-\(mode.tag)][\(item.name)] " + fields("all", lyrics.total) + " "
                + fields("ja", lyrics.kanaKanji) + " " + fields("latin", lyrics.latin))
            totals.text.lyrics.total += lyrics.total
            totals.text.lyrics.kanaKanji += lyrics.kanaKanji
            totals.text.lyrics.latin += lyrics.latin
            let fields = titleTempoFields(original.truth, original.read, &totals)
            print("[mscz-text-\(mode.tag)][\(item.name)] \(fields)")
        }

        /// `title= tempo= titleNorm=` plus, on a miss, the two sides' values. `title` is strict equality of the trimmed
        /// title, `titleNorm` the NFKC / whitespace-collapsed comparison; `none` means the truth has none.
        private static func titleTempoFields(_ truth: Score, _ read: Score, _ totals: inout Totals) -> String {
            var title = "none"
            var titleNorm = "none"
            var detail = ""
            let readTitle = ScoreSemanticMetrics.titleText(read)
            if let truthTitle = ScoreSemanticMetrics.titleText(truth) {
                totals.text.titleTruth += 1
                title = readTitle == truthTitle ? "match" : "miss"
                if title == "match" { totals.text.titleMatch += 1 }
                let normalized = readTitle.map(ScoreSemanticMetrics.normalizedTitle)
                titleNorm = normalized == ScoreSemanticMetrics.normalizedTitle(truthTitle) ? "match" : "miss"
                if titleNorm == "match" { totals.text.titleNormMatch += 1 }
                if title == "miss" {
                    detail += " titleTruth=\(quoted(truthTitle)) titleRead=\(readTitle.map(quoted) ?? "-")"
                }
            }
            var tempo = "none"
            let truthTempo = ScoreSemanticMetrics.firstTempoBPM(truth)
            let readTempo = ScoreSemanticMetrics.firstTempoBPM(read)
            if let truthTempo {
                totals.text.tempoTruth += 1
                tempo = readTempo == truthTempo ? "match" : "miss"
                if tempo == "match" { totals.text.tempoMatch += 1 }
                if tempo == "miss" {
                    detail += " tempoTruth=\(truthTempo) tempoRead=\(readTempo.map(String.init) ?? "-")"
                }
            }
            return "title=\(title) tempo=\(tempo) titleNorm=\(titleNorm)" + detail
        }

        /// `"…"` with `\`, `"` and newlines escaped, so a title stays on its one row.
        private static func quoted(_ text: String) -> String {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r\n", with: "\\n")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\n")
            return "\"\(escaped)\""
        }

        /// The lyric / title / tempo totals for one mode, on a line of their own so `summaryLine` keeps its shape.
        /// A ratio over an empty denominator prints `-`.
        static func lyricsLine(mode: Mode, totals: Totals) -> String {
            func cer(_ c: LyricPlacementCounts) -> String {
                c.truthChars == 0 ? "-" : String(format: "%.4f", Double(c.edits) / Double(c.truthChars))
            }
            func counts(_ key: String, _ c: LyricPlacementCounts) -> String {
                "\(key)Truth=\(c.truthChars) \(key)On=\(c.on) \(key)OneOff=\(c.oneOff) \(key)Far=\(c.far) "
                    + "\(key)Missing=\(c.missing) \(key)Extra=\(c.extra)"
            }
            let lyrics = totals.text.lyrics
            return "[mscz][LYRICS] mode=\(mode.tag) ocr=\(totals.ocrOn ? "on" : "off") "
                + counts("all", lyrics.total) + " cer=\(cer(lyrics.total)) "
                + counts("ja", lyrics.kanaKanji) + " jaCer=\(cer(lyrics.kanaKanji)) "
                + counts("latin", lyrics.latin) + " latinCer=\(cer(lyrics.latin)) "
                + "titleMatch=\(totals.text.titleMatch)/\(totals.text.titleTruth) "
                + "titleNormMatch=\(totals.text.titleNormMatch)/\(totals.text.titleTruth) "
                + "tempoMatch=\(totals.text.tempoMatch)/\(totals.text.tempoTruth) "
                + "seconds=\(String(format: "%.1f", totals.seconds))"
        }
    }
#endif
