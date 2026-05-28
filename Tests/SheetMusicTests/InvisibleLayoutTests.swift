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

        // MARK: - Structural elements (Clef / KeySig / TimeSig / BarLine)

        /// Build a one-measure score whose voice leads with an explicit
        /// clef (with controllable visibility) followed by a single
        /// quarter-note chord. Mirrors `scoreWithSingleChord` but lets the
        /// caller toggle the clef's visibility so we can route the
        /// explicit clef through the visible / invisible accumulators.
        private func scoreWithLeadingClef(clefVisible: Bool) -> Score {
            var clef = Clef(concertClefType: "G")
            clef.visible = clefVisible
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
            let voice = Voice(elements: [
                .clef(clef),
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

        /// Anchor-bearing clef LayoutElements explicitly tagged
        /// `.explicit(...)` (i.e. voice-element-driven, not the
        /// synthesized leading clef which uses `.staffDefault` / `nil`).
        private func explicitClefs(
            _ doc: LayoutDocument,
            inInvisible: Bool = false,
        ) -> [LayoutElement] {
            doc.systems.flatMap(\.measures)
                .flatMap { inInvisible ? $0.invisibleElements : $0.elements }
                .filter {
                    if case let .clef(_, _, anchor) = $0,
                       case .explicit = anchor
                    {
                        true
                    } else {
                        false
                    }
                }
        }

        @Test func hiddenClefTaggedWhenToggleOn() {
            let doc = LayoutEngine.layout(
                score: scoreWithLeadingClef(clefVisible: false),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            // The explicit voice-element clef is routed to
            // invisibleElements. The synthesized leading clef (if any)
            // uses `.staffDefault` anchor and is NOT relevant here.
            #expect(!explicitClefs(doc, inInvisible: true).isEmpty)
            #expect(explicitClefs(doc, inInvisible: false).isEmpty)
        }

        @Test func hiddenClefPreservesSlotWhenToggleOff() {
            /// First-chord x-position must be identical whether the
            /// leading clef is visible or hidden (slot is preserved).
            func firstChordX(clefVisible: Bool) -> CGFloat? {
                let doc = LayoutEngine.layout(
                    score: scoreWithLeadingClef(clefVisible: clefVisible),
                    options: ScoreViewOptions(showsInvisibleElements: false),
                    availableWidth: 800,
                )
                for el in doc.systems.flatMap(\.measures)
                    .flatMap({ $0.elements + $0.invisibleElements })
                {
                    if case let .chord(_, _, _, so, _, _, _, _, _) = el {
                        return so.x
                    }
                }
                return nil
            }
            let xVisible = firstChordX(clefVisible: true)
            let xHidden = firstChordX(clefVisible: false)
            #expect(xVisible != nil)
            #expect(xVisible == xHidden)
        }

        /// Build a one-measure score whose voice ends with an explicit
        /// `BarLine` (with controllable visibility).
        private func scoreWithTrailingBarLine(barVisible: Bool) -> Score {
            var bar = BarLine(subtype: "double")
            bar.visible = barVisible
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(chord),
                .barLine(bar),
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

        /// Filter for explicit `double` barlines so we don't get tangled
        /// up with the implicit-trailing barline path (which emits a
        /// `nil`-subtype bar when no voice supplied one).
        private func doubleBarLines(
            _ doc: LayoutDocument,
            inInvisible: Bool = false,
        ) -> [LayoutElement] {
            doc.systems.flatMap(\.measures)
                .flatMap { inInvisible ? $0.invisibleElements : $0.elements }
                .filter {
                    if case let .barLine(subtype, _) = $0,
                       subtype == "double"
                    {
                        true
                    } else {
                        false
                    }
                }
        }

        @Test func hiddenBarLineTaggedWhenToggleOn() {
            let doc = LayoutEngine.layout(
                score: scoreWithTrailingBarLine(barVisible: false),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            #expect(!doubleBarLines(doc, inInvisible: true).isEmpty)
            #expect(doubleBarLines(doc, inInvisible: false).isEmpty)
        }

        @Test func hiddenBarLineDroppedWhenToggleOff() {
            let doc = LayoutEngine.layout(
                score: scoreWithTrailingBarLine(barVisible: false),
                options: ScoreViewOptions(showsInvisibleElements: false),
                availableWidth: 800,
            )
            #expect(doubleBarLines(doc, inInvisible: true).isEmpty)
            #expect(doubleBarLines(doc, inInvisible: false).isEmpty)
        }

        /// Build a one-measure score whose voice carries an explicit
        /// `TimeSignature` (with controllable visibility) plus a leading
        /// clef.
        private func scoreWithLeadingTimeSig(tsVisible: Bool) -> Score {
            var ts = TimeSignature(numerator: 4, denominator: 4)
            ts.visible = tsVisible
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(ts),
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

        private func timeSignatures(
            _ doc: LayoutDocument,
            inInvisible: Bool = false,
        ) -> [LayoutElement] {
            doc.systems.flatMap(\.measures)
                .flatMap { inInvisible ? $0.invisibleElements : $0.elements }
                .filter {
                    if case .timeSignature = $0 { true } else { false }
                }
        }

        @Test func hiddenTimeSigTaggedWhenToggleOn() {
            let doc = LayoutEngine.layout(
                score: scoreWithLeadingTimeSig(tsVisible: false),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            #expect(!timeSignatures(doc, inInvisible: true).isEmpty)
            #expect(timeSignatures(doc, inInvisible: false).isEmpty)
        }

        /// Build a one-measure score whose voice carries an explicit
        /// `KeySignature` (G major, +1 sharp).
        private func scoreWithLeadingKeySig(keyVisible: Bool) -> Score {
            var key = KeySignature(concertKey: 1)
            key.visible = keyVisible
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .keySignature(key),
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

        private func keySignatures(
            _ doc: LayoutDocument,
            inInvisible: Bool = false,
        ) -> [LayoutElement] {
            doc.systems.flatMap(\.measures)
                .flatMap { inInvisible ? $0.invisibleElements : $0.elements }
                .filter {
                    if case .keySignature = $0 { true } else { false }
                }
        }

        @Test func hiddenKeySigTaggedWhenToggleOn() {
            let doc = LayoutEngine.layout(
                score: scoreWithLeadingKeySig(keyVisible: false),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            // The explicit voice-element key sig must be routed to
            // invisibleElements. (The synthesized leading key sig uses
            // `initialKeyForSynth` and is unrelated.)
            #expect(!keySignatures(doc, inInvisible: true).isEmpty)
            #expect(keySignatures(doc, inInvisible: false).isEmpty)
        }
    }
#endif
