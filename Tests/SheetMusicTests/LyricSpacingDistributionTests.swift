#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// A syllable's spacing requirement runs to the next SYLLABLE, not to the next note, and is shared out over the
    /// gaps in between.
    ///
    /// Reported 2026-09-20: typing a long word under one note in the middle of an otherwise plain run tore a wide
    /// hole beside that note, where MuseScore leaves the run evenly spaced and lets the text spill over its
    /// neighbours. The old rule asked the IMMEDIATE neighbour's gap for `curWidth / 2 + 0.25 sp` whether or not
    /// anything was written under it.
    ///
    /// These measure `lyricsPairWidth` directly rather than through a laid-out score: it is the whole of the rule,
    /// and a full layout would fold in duration spacing, which takes the `max` of the two and would hide the very
    /// difference under test on any note long enough to dominate.
    @Suite("Lyric spacing runs to the next syllable")
    struct LyricSpacingDistributionTests {
        private let _installApple = TestSupport.installApple

        /// `sp` is `staffSize / 4`, so this is a round 8-point staff space.
        private static let metrics = StaffMetrics(staffSize: 32)

        private static func syllable(_ text: String, _ syllabic: Syllabic = .single) -> [Lyric] {
            [Lyric(text: text, syllabic: syllabic)]
        }

        private static func chord(_ lyrics: [Lyric] = []) -> VoiceElement {
            .chord(Chord(
                duration: .eighth,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                lyrics: lyrics,
            ))
        }

        private static func rest() -> VoiceElement {
            .chord(Chord(duration: .eighth, notes: ChordNotes([])))
        }

        // MARK: - The walk

        @Test("the next syllable is found past notes that carry none, counting the gaps")
        func walkCountsGaps() {
            let elements: [VoiceElement] = [
                Self.chord(Self.syllable("sing")),
                Self.chord(),
                Self.chord(),
                Self.chord(Self.syllable("song")),
            ]
            let found = LayoutEngine.nextLyricBearingChord(in: elements, after: 0)
            #expect(found?.gaps == 3, "three tick gaps lie between the two syllables")
            #expect(found?.lyrics.first?.text == "song")
        }

        /// A rest is a gap like any other, and the walk continues past it. The old helper stopped at the first rest
        /// and answered "no lyric follows", so the syllable before a rest demanded its full half-width of the rest's
        /// own gap.
        @Test("a rest is crossed rather than ending the walk")
        func walkCrossesRests() {
            let elements: [VoiceElement] = [
                Self.chord(Self.syllable("sing")),
                Self.rest(),
                Self.chord(Self.syllable("song")),
            ]
            let found = LayoutEngine.nextLyricBearingChord(in: elements, after: 0)
            #expect(found?.gaps == 2)
            #expect(found?.lyrics.first?.text == "song")
        }

        @Test("no syllable after this one answers nil")
        func walkFindsNothing() {
            let elements: [VoiceElement] = [
                Self.chord(Self.syllable("end")),
                Self.chord(),
                Self.chord(),
            ]
            #expect(LayoutEngine.nextLyricBearingChord(in: elements, after: 0) == nil)
        }

        // MARK: - The requirement

        /// Adjacent syllables are the common case and the one every existing spacing expectation was written
        /// against, so they must come out exactly as before: the whole distance, on the one gap between them.
        @Test("adjacent syllables ask for the whole distance, as they always did")
        func adjacentIsUnchanged() {
            let current = Self.syllable("la")
            let next = Self.syllable("la")
            let width = LayoutEngine.lyricsPairWidth(
                currentLyrics: current, next: (lyrics: next, gaps: 1), metrics: Self.metrics,
            )
            let half = LayoutEngine.chordLyricMaxWidth(current, metrics: Self.metrics) / 2
            let nextHalf = LayoutEngine.chordLyricMaxWidth(next, metrics: Self.metrics) / 2
            #expect(width == half + Self.metrics.sp * 0.25 + nextHalf)
        }

        /// **The report, in one assertion.** The same two syllables three notes apart ask each gap for a THIRD of
        /// what they ask of a single gap — so the note the long syllable sits on is no longer pushed away from its
        /// neighbour on its own.
        @Test("syllables further apart share the distance over the gaps between them")
        func distanceIsShared() {
            let current = Self.syllable("Alleluia")
            let next = Self.syllable("men")
            let adjacent = LayoutEngine.lyricsPairWidth(
                currentLyrics: current, next: (lyrics: next, gaps: 1), metrics: Self.metrics,
            )
            let spread = LayoutEngine.lyricsPairWidth(
                currentLyrics: current, next: (lyrics: next, gaps: 3), metrics: Self.metrics,
            )
            #expect(adjacent > 0, "the fixture must ask for something in the first place")
            #expect(abs(spread - adjacent / 3) < 0.0001)
        }

        /// With nothing further to clear, a syllable constrains nothing and the tail stays at duration spacing.
        /// This is the other half of what used to tear the hole: `nextWidth == 0` still bought `curWidth / 2`.
        @Test("a syllable with none after it asks for nothing")
        func noFollowingSyllableAsksNothing() {
            let width = LayoutEngine.lyricsPairWidth(
                currentLyrics: Self.syllable("Alleluia"), next: nil, metrics: Self.metrics,
            )
            #expect(width == 0)
        }

        @Test("a chord with no syllable of its own asks for nothing")
        func noCurrentSyllableAsksNothing() {
            let width = LayoutEngine.lyricsPairWidth(
                currentLyrics: [], next: (lyrics: Self.syllable("la"), gaps: 1), metrics: Self.metrics,
            )
            #expect(width == 0)
        }

        /// A BEGIN/MIDDLE syllable still buys the wider inter-syllable room its connecting dash needs — and it is
        /// shared out the same way, since the dash is drawn across whatever lies between.
        @Test("a dashed syllable still buys the wider gap")
        func dashKeepsItsRoom() {
            let dashed = [Lyric(text: "Al", syllabic: .begin)]
            let plain = Self.syllable("Al")
            let next = Self.syllable("le")
            let withDash = LayoutEngine.lyricsPairWidth(
                currentLyrics: dashed, next: (lyrics: next, gaps: 1), metrics: Self.metrics,
            )
            let withoutDash = LayoutEngine.lyricsPairWidth(
                currentLyrics: plain, next: (lyrics: next, gaps: 1), metrics: Self.metrics,
            )
            #expect(withDash - withoutDash == Self.metrics.sp * 0.25)
        }
    }
#endif
