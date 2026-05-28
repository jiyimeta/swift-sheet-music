#if !os(Android)
    import CoreGraphics
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// Exercises the parallel "invisible" layout containers
    /// (`LayoutMeasure.invisibleElements`) end-to-end: when
    /// `ScoreViewOptions.showsInvisibleElements` is on, hidden
    /// annotations must still be laid out but routed into the
    /// invisible container; when off they are dropped as today.
    struct InvisibleLayoutTests {
        private let _installApple = TestSupport.installApple

        /// Build the smallest valid score whose single measure carries a
        /// hidden `Tempo`. Tempo lives in `Score.systemMeasures` as a
        /// `PositionedSystemElement` (the same path
        /// `placeMeasureElements` reads for tempo marks).
        private func scoreWithHiddenTempo() -> Score {
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(chord),
            ])
            let measure = Measure(voices: [voice])
            let systemMeasure = SystemMeasure(elements: [
                PositionedSystemElement(
                    position: .start,
                    element: .tempo(Tempo(beatsPerSecond: 2.0, visible: false)),
                ),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "voice"),
                    staves: [Staff(measures: [measure])],
                )],
                systemMeasures: [systemMeasure],
            )
        }

        private func tempoMarks(_ doc: LayoutDocument) -> [LayoutElement] {
            doc.systems.flatMap(\.measures).flatMap(\.elements)
                .filter { if case .textMark(.tempo, _, _) = $0 { true } else { false } }
        }

        private func invisibleTempoMarks(_ doc: LayoutDocument) -> [LayoutElement] {
            doc.systems.flatMap(\.measures).flatMap(\.invisibleElements)
                .filter { if case .textMark(.tempo, _, _) = $0 { true } else { false } }
        }

        @Test func hiddenTempoDroppedWhenToggleOff() {
            let doc = LayoutEngine.layout(
                score: scoreWithHiddenTempo(),
                options: ScoreViewOptions(showsInvisibleElements: false),
                availableWidth: 800,
            )
            #expect(tempoMarks(doc).isEmpty)
            #expect(invisibleTempoMarks(doc).isEmpty)
        }

        @Test func hiddenTempoTaggedWhenToggleOn() {
            let doc = LayoutEngine.layout(
                score: scoreWithHiddenTempo(),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            #expect(tempoMarks(doc).isEmpty) // not in visible list
            #expect(invisibleTempoMarks(doc).count == 1) // tagged invisible
        }

        /// Build a minimal one-measure score whose single voice contains
        /// the supplied chord. Mirrors `scoreWithHiddenTempo()`'s scaffold
        /// (clef + time sig + chord) but without any tempo annotation, so
        /// the chord is the only timed element to inspect.
        private func scoreWithSingleChord(_ chord: Chord) -> Score {
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(chord),
            ])
            let measure = Measure(voices: [voice])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "voice"),
                    staves: [Staff(measures: [measure])],
                )],
            )
        }

        @Test func hiddenNoteTaggedInvisibleWhenToggleOn() {
            var note = Note(pitch: 60, tpc: 14)
            note.visible = false
            let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
            let doc = LayoutEngine.layout(
                score: scoreWithSingleChord(chord),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            // Search BOTH `.elements` and `.invisibleElements`: with a
            // single-note chord where that note is hidden, the
            // all-notes-invisible rule may route the whole chord to
            // `invisibleElements` instead.
            let allChordNotes = doc.systems.flatMap(\.measures)
                .flatMap { $0.elements + $0.invisibleElements }
                .compactMap { el -> [LayoutChordNote]? in
                    if case let .chord(notes, _, _, _, _, _, _, _, _) = el { notes } else { nil }
                }
                .flatMap(\.self)
            #expect(allChordNotes.contains { $0.isInvisible })
        }

        @Test func hiddenNotePreservesSlotWhenToggleOff() {
            /// Same single-note chord, visible vs hidden, must produce
            /// the same chord stemOrigin.x with toggle OFF — slot is
            /// preserved, only glyph suppression differs.
            func chordStemX(hidden: Bool) -> CGFloat? {
                var note = Note(pitch: 60, tpc: 14)
                note.visible = !hidden
                let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
                let doc = LayoutEngine.layout(
                    score: scoreWithSingleChord(chord),
                    options: ScoreViewOptions(showsInvisibleElements: false),
                    availableWidth: 800,
                )
                // Look in BOTH `.elements` and `.invisibleElements`:
                // a fully-hidden chord may be dropped from `.elements`
                // when the toggle is off but its slot still needs to
                // line up with the visible variant's stem column.
                for el in doc.systems.flatMap(\.measures)
                    .flatMap({ $0.elements + $0.invisibleElements })
                {
                    if case let .chord(_, _, _, so, _, _, _, _, _) = el { return so.x }
                }
                return nil
            }
            let xVisible = chordStemX(hidden: false)
            let xHidden = chordStemX(hidden: true)
            #expect(xVisible != nil)
            #expect(xVisible == xHidden)
        }
    }
#endif
