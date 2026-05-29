#if os(macOS)
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite("LayoutEngine")
    struct LayoutEngineTests {
        private let _installApple = TestSupport.installApple

        @Test("Empty score produces zero systems")
        func emptyScore() {
            guard #available(macOS 15.0, *) else { return }
            let score = Score(division: 480)
            let doc = LayoutEngine.layout(
                score: score,
                options: .init(),
                availableWidth: 800,
            )
            #expect(doc.systems.isEmpty)
        }

        @Test("Single measure with a whole note produces one system")
        func oneWholeNote() {
            guard #available(macOS 15.0, *) else { return }
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .whole, notes: [note])
            let measure = Measure(
                voices: [Voice(elements: [.chord(chord)])],
            )
            let staff = Staff(measures: [measure])
            let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            #expect(doc.systems.count == 1)
            #expect(doc.systems[0].measures.count == 1)
            let chordCount = doc.systems[0].measures[0].elements.count(where: {
                if case .chord = $0 { true } else { false }
            })
            #expect(chordCount == 1)
        }

        @Test("Many measures at narrow width wrap to multiple systems")
        func manyMeasuresWrap() {
            guard #available(macOS 15.0, *) else { return }
            let note = Note(pitch: 60, tpc: 14)
            let m = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [note])),
                .chord(Chord(duration: .whole, notes: [note])),
                .chord(Chord(duration: .whole, notes: [note])),
            ])])
            let staff = Staff(
                measures: [m, m, m, m, m, m, m, m],
            )
            let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
            let doc = LayoutEngine.layout(
                score: score, options: .init(),
                availableWidth: 120,
            )
            #expect(doc.systems.count >= 2)
        }

        @Test("Piano (2 staves) stacks staff origins vertically")
        func pianoTwoStaves() {
            guard #available(macOS 15.0, *) else { return }
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .whole, notes: [note])
            let m = Measure(voices: [Voice(elements: [.chord(chord)])])
            let staff1 = Staff(measures: [m])
            let staff2 = Staff(measures: [m])
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "piano", longName: "Piano", shortName: "Pno.",
                ),
                staves: [staff1, staff2],
            )
            let score = Score(
                division: 480,
                parts: [part],
            )
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            #expect(doc.systems.count == 1)
            #expect(doc.systems[0].staffOrigins.count == 2)
            #expect(
                doc.systems[0].staffOrigins[0].y
                    < doc.systems[0].staffOrigins[1].y,
            )
        }

        @Test("Part labels: long name on first system, short name after")
        func partLabelsFirstVsLater() throws {
            guard #available(macOS 15.0, *) else { return }
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .whole, notes: [note])
            let m = Measure(voices: [Voice(elements: [.chord(chord)])])
            let staff = Staff(
                measures: [m, m, m, m, m, m, m, m],
            )
            let part = Part(
                id: "P1",
                trackName: "Violin",
                instrument: Instrument(
                    id: "violin", longName: "Violin", shortName: "Vln.",
                ),
                staves: [staff],
            )
            let score = Score(
                division: 480,
                parts: [part],
            )
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 180,
            )
            try #require(doc.systems.count >= 2)
            #expect(doc.systems[0].partLabels.first?.text == "Violin")
            #expect(doc.systems[1].partLabels.first?.text == "Vln.")
        }

        // MARK: - Notehead mirroring (seconds)

        private static func note(pitch: Int, tpc: Int) -> Note {
            Note(pitch: pitch, tpc: tpc)
        }

        /// Build a single-measure single-staff score from one chord and
        /// return its laid-out chord notes + stem direction.
        @available(macOS 15.0, *)
        private static func layoutChord(
            notes chordNotes: [Note],
        ) -> (notes: [LayoutChordNote], stem: StemDirection)? {
            let chord = Chord(
                duration: .quarter, notes: ChordNotes(chordNotes),
            )
            let measure = Measure(
                voices: [Voice(elements: [.chord(chord)])],
            )
            let staff = Staff(measures: [measure])
            let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            for el in doc.systems[0].measures[0].elements {
                if case let .chord(n, _, s, _, _, _, _, _, _, _) = el {
                    return (n, s)
                }
            }
            return nil
        }

        @Test("No mirror when notes are not adjacent")
        func noMirrorOnThirds() throws {
            guard #available(macOS 15.0, *) else { return }
            // C4 (60, tpc 14) + E4 (64, tpc 18): a major third, no
            // collision — neither head should be mirrored.
            let result = try #require(Self.layoutChord(notes: [
                Self.note(pitch: 60, tpc: 14),
                Self.note(pitch: 64, tpc: 18),
            ]))
            #expect(result.notes.allSatisfy { !$0.mirror })
        }

        @Test("Stem-up second mirrors the upper note")
        func upstemSecondMirrorsUpper() throws {
            guard #available(macOS 15.0, *) else { return }
            // C4 (60) + D4 (62, tpc 16): a second on a low chord
            // (median below middle line → stem up). Default side for
            // upstem is left of stem; the upper note flips to the right.
            let result = try #require(Self.layoutChord(notes: [
                Self.note(pitch: 60, tpc: 14),
                Self.note(pitch: 62, tpc: 16),
            ]))
            #expect(result.stem == .up)
            // Sort notes by step ascending so we can address bottom/top
            // independent of the order they came in via `chord.notes`.
            let sorted = result.notes.sorted { $0.step < $1.step }
            #expect(sorted[0].mirror == false)
            #expect(sorted[1].mirror == true)
        }

        @Test("Stem-down second mirrors the lower note")
        func downstemSecondMirrorsLower() throws {
            guard #available(macOS 15.0, *) else { return }
            // C5 (72) + D5 (74, tpc 16): high chord (median above
            // middle line → stem down). Default side for downstem is
            // right of stem; the lower note flips to the left.
            let result = try #require(Self.layoutChord(notes: [
                Self.note(pitch: 72, tpc: 14),
                Self.note(pitch: 74, tpc: 16),
            ]))
            #expect(result.stem == .down)
            let sorted = result.notes.sorted { $0.step < $1.step }
            #expect(sorted[0].mirror == true)
            #expect(sorted[1].mirror == false)
        }

        @Test("Cluster of 3 consecutive seconds alternates sides")
        func clusterAlternatesSides() throws {
            guard #available(macOS 15.0, *) else { return }
            // C4, D4, E4: two consecutive seconds. From the bottom up
            // for a stem-up chord the sides should go default-flip-default.
            let result = try #require(Self.layoutChord(notes: [
                Self.note(pitch: 60, tpc: 14),
                Self.note(pitch: 62, tpc: 16),
                Self.note(pitch: 64, tpc: 18),
            ]))
            #expect(result.stem == .up)
            let sorted = result.notes.sorted { $0.step < $1.step }
            #expect(sorted[0].mirror == false)
            #expect(sorted[1].mirror == true)
            #expect(sorted[2].mirror == false)
        }

        @Test("Mirror dx is one notehead width to the appropriate side")
        func mirrorDxMatchesNoteheadWidth() throws {
            guard #available(macOS 15.0, *) else { return }
            let upResult = try #require(Self.layoutChord(notes: [
                Self.note(pitch: 60, tpc: 14),
                Self.note(pitch: 62, tpc: 16),
            ]))
            let upMirrored = upResult.notes.first { $0.mirror }
            let upDx = try #require(
                upMirrored?.mirrorDx(stem: upResult.stem, sp: 5),
            )
            // 5 sp × 1.18 = 5.9, positive (to the right) for upstem.
            #expect(abs(upDx - 5.9) < 1e-9)

            let downResult = try #require(Self.layoutChord(notes: [
                Self.note(pitch: 72, tpc: 14),
                Self.note(pitch: 74, tpc: 16),
            ]))
            let downMirrored = downResult.notes.first { $0.mirror }
            let downDx = try #require(
                downMirrored?.mirrorDx(stem: downResult.stem, sp: 5),
            )
            #expect(abs(downDx - -5.9) < 1e-9)
        }

        // MARK: - Drum-staff stem direction

        /// Build a single-measure drum-staff score and return the
        /// stem direction of the first chord laid out in `voiceIndex`.
        @available(macOS 15.0, *)
        private static func drumStaffStem(
            voices: [Voice],
            drumLineMap: [Int: Int],
            voiceIndex: Int = 0,
        ) -> StemDirection? {
            let measure = Measure(voices: voices)
            let staff = Staff(measures: [measure])
            let part = Part(
                id: "drum",
                instrument: Instrument(
                    id: "drumset",
                    useDrumset: true,
                    drumLineMap: drumLineMap,
                ),
                staves: [staff],
            )
            let score = Score(division: 480, parts: [part])
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            var seen = -1
            for el in doc.systems[0].measures[0].elements {
                if case let .chord(_, _, s, _, _, _, _, _, _, _) = el {
                    seen += 1
                    if seen == voiceIndex { return s }
                }
            }
            return nil
        }

        @Test("Drum staff: voice 1 forced stem-up even when voice 2 is empty")
        func drumStaffSingleVoiceForcesUp() throws {
            guard #available(macOS 15.0, *) else { return }
            // Pitch 47 (Low-Mid Tom) sits at line=1 → step=3 (above
            // the middle line). The median heuristic picks DOWN for a
            // step-3 chord, but MuseScore's Drumset says stem=up for
            // pitch 47. The renderer must honor the drum-staff
            // convention (voice 1 = up) regardless of multi-voice state.
            let chord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 47, tpc: 19)]),
            )
            let stem = try #require(Self.drumStaffStem(
                voices: [Voice(elements: [.chord(chord)])],
                drumLineMap: [47: 1],
            ))
            #expect(stem == .up)
        }

        @Test("Drum staff: voice 1 still up when voice 2 holds only rests")
        func drumStaffVoice2RestOnlyStillForcesUp() throws {
            guard #available(macOS 15.0, *) else { return }
            // Mirrors the test-now.mscx measure-62 layout: voice 1 has
            // chords, voice 2 has only a half rest. Without the
            // drum-staff guard, `isMultiVoice` is false (only one
            // voice has chords) and the median rule wins.
            let chord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 38, tpc: 16)]),
            )
            let voice1 = Voice(elements: [.chord(chord)])
            let voice2 = Voice(elements: [.rest(duration: .half)])
            let stem = try #require(Self.drumStaffStem(
                voices: [voice1, voice2],
                drumLineMap: [38: 3],
            ))
            #expect(stem == .up)
        }
    }
#endif
