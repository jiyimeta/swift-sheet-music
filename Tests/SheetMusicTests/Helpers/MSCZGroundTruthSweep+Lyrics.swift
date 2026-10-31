#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicCore

    /// The lyric / title / tempo rows of the ground-truth sweep, split out of `MSCZGroundTruthSweep` to keep its
    /// body inside the lint budget.
    extension MSCZGroundTruthSweep {
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
            let lyrics = ScoreSemanticMetrics.lyricPlacement(scoreA: aligned.truth, scoreB: aligned.read)
            func fields(_ key: String, _ c: LyricPlacementCounts) -> String {
                "\(key)Truth=\(c.truthChars) \(key)On=\(c.on) \(key)OneOff=\(c.oneOff) \(key)Far=\(c.far) "
                    + "\(key)Missing=\(c.missing) \(key)Extra=\(c.extra) \(key)Edits=\(c.edits)"
            }
            print("[mscz-lyrics-\(mode.tag)][\(item.name)] " + fields("all", lyrics.total) + " "
                + fields("ja", lyrics.kanaKanji) + " " + fields("latin", lyrics.latin))
            totals.lyrics.total += lyrics.total
            totals.lyrics.kanaKanji += lyrics.kanaKanji
            totals.lyrics.latin += lyrics.latin

            var title = "none"
            if let truthTitle = ScoreSemanticMetrics.titleText(original.truth) {
                totals.titleTruth += 1
                title = ScoreSemanticMetrics.titleText(original.read) == truthTitle ? "match" : "miss"
                if title == "match" { totals.titleMatch += 1 }
            }
            var tempo = "none"
            if let truthTempo = ScoreSemanticMetrics.firstTempoBPM(original.truth) {
                totals.tempoTruth += 1
                tempo = ScoreSemanticMetrics.firstTempoBPM(original.read) == truthTempo ? "match" : "miss"
                if tempo == "match" { totals.tempoMatch += 1 }
            }
            print("[mscz-text-\(mode.tag)][\(item.name)] title=\(title) tempo=\(tempo)")
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
            let lyrics = totals.lyrics
            return "[mscz][LYRICS] mode=\(mode.tag) ocr=\(totals.ocrOn ? "on" : "off") "
                + counts("all", lyrics.total) + " cer=\(cer(lyrics.total)) "
                + counts("ja", lyrics.kanaKanji) + " jaCer=\(cer(lyrics.kanaKanji)) "
                + counts("latin", lyrics.latin) + " latinCer=\(cer(lyrics.latin)) "
                + "titleMatch=\(totals.titleMatch)/\(totals.titleTruth) "
                + "tempoMatch=\(totals.tempoMatch)/\(totals.tempoTruth) "
                + "seconds=\(String(format: "%.1f", totals.seconds))"
        }
    }
#endif
