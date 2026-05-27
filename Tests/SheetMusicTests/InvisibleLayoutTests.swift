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
    }
#endif
