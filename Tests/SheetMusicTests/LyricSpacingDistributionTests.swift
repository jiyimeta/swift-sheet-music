#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// A syllable's spacing requirement runs to the next SYLLABLE, not to the next note.
    ///
    /// Reported 2026-09-20: typing a long word under one note in the middle of an otherwise plain run tore a wide
    /// hole beside that note, where MuseScore leaves the run evenly spaced and lets the text spill over its
    /// neighbours. The old rule asked the IMMEDIATE neighbour's gap for `curWidth / 2 + 0.25 sp` whether or not
    /// anything was written under it.
    ///
    /// These measure `lyricsPairWidth` and the walk directly rather than through a laid-out score: a full layout
    /// would fold in duration spacing, which takes over wherever it is the wider. How the requirement is shared over
    /// the gaps up to the next syllable is pinned in layout (`LyricSpacingLayoutTests`).
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

        @Test("the next syllable is found past notes that carry none")
        func walkSkipsBareNotes() {
            let elements: [VoiceElement] = [
                Self.chord(Self.syllable("sing")),
                Self.chord(),
                Self.chord(),
                Self.chord(Self.syllable("song")),
            ]
            let found = LayoutEngine.nextLyricBearingChord(in: elements, after: 0)
            #expect(found?.index == 3)
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
            #expect(found?.index == 2)
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

        /// The two syllables are centered on their columns, so the columns must stand both half-widths and the
        /// inter-syllable room apart.
        @Test("a pair asks for both half-widths and the room between them")
        func pairAsksForBothHalves() {
            let current = Self.syllable("Alleluia")
            let next = Self.syllable("men")
            let width = LayoutEngine.lyricsPairWidth(currentLyrics: current, nextLyrics: next, metrics: Self.metrics)
            let half = LayoutEngine.chordLyricMaxWidth(current, metrics: Self.metrics) / 2
            let nextHalf = LayoutEngine.chordLyricMaxWidth(next, metrics: Self.metrics) / 2
            #expect(width == half + Self.metrics.sp * 0.25 + nextHalf)
        }

        /// With nothing further to clear, a syllable constrains nothing and the tail stays at duration spacing.
        /// This is the other half of what used to tear the hole: `nextWidth == 0` still bought `curWidth / 2`.
        @Test("a syllable with none after it asks for nothing")
        func noFollowingSyllableAsksNothing() {
            let width = LayoutEngine.lyricsPairWidth(
                currentLyrics: Self.syllable("Alleluia"), nextLyrics: nil, metrics: Self.metrics,
            )
            #expect(width == 0)
        }

        @Test("a chord with no syllable of its own asks for nothing")
        func noCurrentSyllableAsksNothing() {
            let width = LayoutEngine.lyricsPairWidth(
                currentLyrics: [], nextLyrics: Self.syllable("la"), metrics: Self.metrics,
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
            let withDash = LayoutEngine.lyricsPairWidth(currentLyrics: dashed, nextLyrics: next, metrics: Self.metrics)
            let withoutDash = LayoutEngine.lyricsPairWidth(
                currentLyrics: plain, nextLyrics: next, metrics: Self.metrics,
            )
            #expect(withDash - withoutDash == Self.metrics.sp * 0.25)
        }

        /// The spacing walks measure each chord once and carry the width to the chord's own pair
        /// (`VoiceLyricSpacing`). Whatever they save, each chord must be asked for exactly what the pair rule asks, up
        /// to the chord the walk finds: across a note without a syllable, a rest, and a syllable of symbols alone
        /// (which only its runs give width).
        @Test("a voice walk asks each chord for exactly what the pair rule asks")
        func voiceWalkMatchesThePairRule() {
            let elision = Lyric(text: "", preservedTextMarkup: PreservedTextMarkup(
                content: [.element(.init(name: "sym", content: [.characters("lyricsElision")]))], derivedText: "",
            ))
            let elements: [VoiceElement] = [
                Self.chord(Self.syllable("Al", .begin)), Self.chord(), Self.rest(), Self.chord([elision]),
                Self.chord(Self.syllable("lu", .middle)), Self.chord(Self.syllable("ia", .end)), Self.chord(),
            ]
            var walk = VoiceLyricSpacing(elements, metrics: Self.metrics)
            var asked: [Int?] = []
            for (index, element) in elements.enumerated() {
                guard case let .chord(chord) = element, !chord.notes.isEmpty else { continue }
                let next = LayoutEngine.nextLyricBearingChord(in: elements, after: index)
                let expected = LayoutEngine.lyricsPairWidth(
                    currentLyrics: chord.lyrics, nextLyrics: next?.lyrics, metrics: Self.metrics,
                )
                let demand = walk.demand(at: index, lyrics: chord.lyrics)
                #expect((demand?.width ?? 0) == expected, "chord \(index): \(demand?.width ?? 0) vs \(expected)")
                #expect(demand.map { $0.nextIndex == next?.index } ?? true, "chord \(index) reaches the wrong chord")
                asked.append(demand?.nextIndex)
            }
            // "Al" reaches the elision past a bare note and a rest, the elision "lu", "lu" "ia"; "ia" and the bare
            // notes ask for nothing.
            #expect(asked == [3, nil, 4, 5, nil, nil])
        }
    }
#endif
