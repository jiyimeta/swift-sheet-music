#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// `ScoreViewOptions.lyricsVisible` — the host's "show lyrics" switch.
    ///
    /// Two claims, and the second is the one a host reserving a fixed-height
    /// notation strip actually depends on:
    ///
    /// 1. Nothing of the lyric row is engraved — not the syllables, not the
    ///    hyphens between them, and not the melisma rules, including the
    ///    continuation segments an earlier measure's melisma pushes into later
    ///    measures.
    /// 2. The document is genuinely SHORTER. A gate that merely stopped drawing
    ///    the syllables while leaving their vertical slot reserved would pass
    ///    claim 1 and still hand the host the same height, so the height
    ///    assertion is what distinguishes "removed" from "hidden".
    ///
    /// What these tests are blind to: whether the surviving engraving is
    /// *correct*. They compare two runs of the same engine over the same score,
    /// so a bug that damages both runs equally is invisible here.
    @Suite("LayoutEngine — lyrics visibility")
    struct LyricsVisibilityTests {
        #if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
            private let _installApple = TestSupport.installApple
        #endif

        /// Two measures of a hyphenated word whose last syllable melismas past
        /// the barline. The fixture deliberately produces all three decorations —
        /// syllable text, a hyphen and a melisma rule with a continuation in the
        /// following measure — because each is emitted by a different branch and
        /// a fixture with only plain syllables cannot see two of the three.
        private static func lyricScore() -> Score {
            let division = 480
            func chord(_ pitch: Int, _ lyric: Lyric?) -> VoiceElement {
                .chord(Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: pitch, tpc: 14)]),
                    lyrics: lyric.map { [$0] } ?? [],
                ))
            }
            let measure1 = Measure(voices: [Voice(elements: [
                chord(60, Lyric(text: "Pa", syllabic: .begin)),
                chord(62, Lyric(text: "ra", syllabic: .middle)),
                chord(64, Lyric(text: "di", syllabic: .middle)),
                // `ticks` well past this chord's own quarter: a melisma that runs
                // through the trailing barline and into measure 2.
                chord(65, Lyric(text: "so", syllabic: .end, ticks: division * 3)),
            ])])
            let measure2 = Measure(voices: [Voice(elements: [
                chord(67, nil), chord(65, nil), chord(64, nil), chord(62, nil),
            ])])
            let staff = Staff(measures: [measure1, measure2])
            let part = Part(id: "1", instrument: Instrument(id: "voice"), staves: [staff])
            return Score(division: division, parts: [part])
        }

        private struct Counts {
            var syllables = 0
            var hyphens = 0
            var melismas = 0
            var height: CGFloat = 0
        }

        private static func layoutCounts(lyricsVisible: Bool) -> Counts {
            let document = LayoutEngine.layout(
                score: lyricScore(),
                options: ScoreViewOptions(lyricsVisible: lyricsVisible),
                // Wide enough that both measures land on one system, so the two
                // runs are compared over the same wrap and the height difference
                // cannot be a re-wrap in disguise.
                availableWidth: 1200,
            )
            var counts = Counts()
            counts.height = document.size.height
            for system in document.systems {
                for measure in system.measures {
                    for element in measure.elements {
                        switch element {
                        case .textMark(.lyrics, _, _): counts.syllables += 1
                        case .lyricHyphen: counts.hyphens += 1
                        case .lyricsMelisma: counts.melismas += 1
                        default: break
                        }
                    }
                    // The invisible container must not become a back door: hiding
                    // is a host display choice, not the element's `visible` flag.
                    for element in measure.invisibleElements {
                        if case .textMark(.lyrics, _, _) = element { counts.syllables += 1 }
                    }
                }
            }
            return counts
        }

        @Test func theFixtureActuallyEngravesAllThreeDecorations() {
            let shown = Self.layoutCounts(lyricsVisible: true)
            // Without this the hidden run's zeros prove nothing: a fixture that
            // never produced a hyphen or a melisma would report "none engraved"
            // under both settings and pass whatever the gate did.
            #expect(shown.syllables == 4)
            #expect(shown.hyphens > 0)
            #expect(shown.melismas > 0)
        }

        @Test func hidingLyricsRemovesEverySyllableHyphenAndMelisma() {
            let hidden = Self.layoutCounts(lyricsVisible: false)
            #expect(hidden.syllables == 0)
            #expect(hidden.hyphens == 0)
            #expect(hidden.melismas == 0)
        }

        @Test func hidingLyricsShortensTheDocument() {
            let shown = Self.layoutCounts(lyricsVisible: true)
            let hidden = Self.layoutCounts(lyricsVisible: false)
            // Strictly shorter, not merely "not taller": an implementation that
            // suppressed the glyphs but kept the row's reserved slot would give
            // the host the same height and defeat a fit-to-content strip.
            #expect(hidden.height < shown.height)
        }

        @Test func showingLyricsIsTheDefault() {
            // A host built against an earlier release passes no such option, and
            // the safe direction for it is the behaviour it already had.
            #expect(ScoreViewOptions().lyricsVisible)
        }
    }
#endif
