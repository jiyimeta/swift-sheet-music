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
    struct InvisibleLayoutTests { // swiftlint:disable:this type_body_length
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
            /// Two-note chord, both notes visible vs only one note
            /// visible (the other hidden), with toggle OFF — must
            /// produce the same chord stemOrigin.x. The partially-
            /// hidden case still emits the chord because not every
            /// note is invisible (the `allElementsInvisible` rule
            /// only fires when EVERY note is hidden).
            func chordStemX(hideOne: Bool) -> CGFloat? {
                let n1 = Note(pitch: 60, tpc: 14)
                var n2 = Note(pitch: 64, tpc: 18)
                n2.visible = !hideOne
                let chord = Chord(
                    duration: .quarter, notes: ChordNotes([n1, n2]),
                )
                let doc = LayoutEngine.layout(
                    score: scoreWithSingleChord(chord),
                    options: ScoreViewOptions(showsInvisibleElements: false),
                    availableWidth: 800,
                )
                for el in doc.systems.flatMap(\.measures)
                    .flatMap({ $0.elements + $0.invisibleElements })
                {
                    if case let .chord(_, _, _, so, _, _, _, _, _) = el { return so.x }
                }
                return nil
            }
            let xBothVisible = chordStemX(hideOne: false)
            let xOneHidden = chordStemX(hideOne: true)
            #expect(xBothVisible != nil)
            #expect(xBothVisible == xOneHidden)
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

        // MARK: - Annotation elements (Dynamic / Fermata / Lyric / RehearsalMark)

        /// Build a one-measure score whose voice carries a chord followed
        /// by a Dynamic with controllable visibility.
        private func scoreWithDynamic(visible: Bool) -> Score {
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .dynamic(Dynamic(subtype: "mf", velocity: 80, visible: visible)),
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

        private func dynamicMarks(
            _ doc: LayoutDocument,
            inInvisible: Bool = false,
        ) -> [LayoutElement] {
            doc.systems.flatMap(\.measures)
                .flatMap { inInvisible ? $0.invisibleElements : $0.elements }
                .filter {
                    if case .textMark(.dynamic, _, _) = $0 { true } else { false }
                }
        }

        @Test func hiddenDynamicDroppedWhenToggleOff() {
            let doc = LayoutEngine.layout(
                score: scoreWithDynamic(visible: false),
                options: ScoreViewOptions(showsInvisibleElements: false),
                availableWidth: 800,
            )
            #expect(dynamicMarks(doc, inInvisible: false).isEmpty)
            #expect(dynamicMarks(doc, inInvisible: true).isEmpty)
        }

        @Test func hiddenDynamicTaggedWhenToggleOn() {
            let doc = LayoutEngine.layout(
                score: scoreWithDynamic(visible: false),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            #expect(dynamicMarks(doc, inInvisible: false).isEmpty)
            #expect(dynamicMarks(doc, inInvisible: true).count == 1)
        }

        /// Build a one-measure score whose voice carries a chord followed
        /// by a Fermata with controllable visibility. (Anchor lookup
        /// scans backward through `out` so the fermata sits after the
        /// chord here — same arrangement MSCX uses.)
        private func scoreWithFermata(visible: Bool) -> Score {
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(chord),
                .fermata(Fermata(subtype: "fermataAbove", visible: visible)),
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

        private func fermataMarks(
            _ doc: LayoutDocument,
            inInvisible: Bool = false,
        ) -> [LayoutElement] {
            doc.systems.flatMap(\.measures)
                .flatMap { inInvisible ? $0.invisibleElements : $0.elements }
                .filter {
                    if case .fermata = $0 { true } else { false }
                }
        }

        @Test func hiddenFermataDroppedWhenToggleOff() {
            let doc = LayoutEngine.layout(
                score: scoreWithFermata(visible: false),
                options: ScoreViewOptions(showsInvisibleElements: false),
                availableWidth: 800,
            )
            #expect(fermataMarks(doc, inInvisible: false).isEmpty)
            #expect(fermataMarks(doc, inInvisible: true).isEmpty)
        }

        @Test func hiddenFermataTaggedWhenToggleOn() {
            let doc = LayoutEngine.layout(
                score: scoreWithFermata(visible: false),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            #expect(fermataMarks(doc, inInvisible: false).isEmpty)
            #expect(fermataMarks(doc, inInvisible: true).count == 1)
        }

        /// Build a one-measure score whose chord carries a single Lyric
        /// with controllable visibility.
        private func scoreWithLyric(visible: Bool) -> Score {
            let note = Note(pitch: 60, tpc: 14)
            let lyric = Lyric(text: "la", visible: visible)
            let chord = Chord(
                duration: .quarter,
                notes: ChordNotes([note]),
                lyrics: [lyric],
            )
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

        private func lyricMarks(
            _ doc: LayoutDocument,
            inInvisible: Bool = false,
        ) -> [LayoutElement] {
            doc.systems.flatMap(\.measures)
                .flatMap { inInvisible ? $0.invisibleElements : $0.elements }
                .filter {
                    if case .textMark(.lyrics, _, _) = $0 { true } else { false }
                }
        }

        @Test func hiddenLyricDroppedWhenToggleOff() {
            let doc = LayoutEngine.layout(
                score: scoreWithLyric(visible: false),
                options: ScoreViewOptions(showsInvisibleElements: false),
                availableWidth: 800,
            )
            #expect(lyricMarks(doc, inInvisible: false).isEmpty)
            #expect(lyricMarks(doc, inInvisible: true).isEmpty)
        }

        @Test func hiddenLyricTaggedWhenToggleOn() {
            let doc = LayoutEngine.layout(
                score: scoreWithLyric(visible: false),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            #expect(lyricMarks(doc, inInvisible: false).isEmpty)
            #expect(lyricMarks(doc, inInvisible: true).count == 1)
        }

        /// Build a one-measure score whose system measure carries a
        /// RehearsalMark with controllable visibility.
        private func scoreWithRehearsalMark(visible: Bool) -> Score {
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
                    element: .rehearsalMark(RehearsalMark(text: "A", visible: visible)),
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

        private func rehearsalMarks(
            _ doc: LayoutDocument,
            inInvisible: Bool = false,
        ) -> [LayoutElement] {
            doc.systems.flatMap(\.measures)
                .flatMap { inInvisible ? $0.invisibleElements : $0.elements }
                .filter {
                    if case .rehearsalMark = $0 { true } else { false }
                }
        }

        @Test func hiddenRehearsalMarkDroppedWhenToggleOff() {
            let doc = LayoutEngine.layout(
                score: scoreWithRehearsalMark(visible: false),
                options: ScoreViewOptions(showsInvisibleElements: false),
                availableWidth: 800,
            )
            #expect(rehearsalMarks(doc, inInvisible: false).isEmpty)
            #expect(rehearsalMarks(doc, inInvisible: true).isEmpty)
        }

        @Test func hiddenRehearsalMarkTaggedWhenToggleOn() {
            let doc = LayoutEngine.layout(
                score: scoreWithRehearsalMark(visible: false),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            #expect(rehearsalMarks(doc, inInvisible: false).isEmpty)
            #expect(rehearsalMarks(doc, inInvisible: true).count == 1)
        }

        // MARK: - Hidden rests, fully-hidden chords, partial-hidden chord stem geometry

        /// Build a one-measure score whose voice carries a single hidden
        /// rest (a `Chord` with `notes: []`, `visible: false`).
        private func scoreWithHiddenRest() -> Score {
            let rest = Chord(
                duration: .quarter,
                notes: ChordNotes([]),
                visible: false,
            )
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(rest),
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

        private func rests(
            _ doc: LayoutDocument,
            inInvisible: Bool = false,
        ) -> [LayoutElement] {
            doc.systems.flatMap(\.measures)
                .flatMap { inInvisible ? $0.invisibleElements : $0.elements }
                .filter {
                    if case .rest = $0 { true } else { false }
                }
        }

        @Test func hiddenRestDroppedWhenToggleOff() {
            let doc = LayoutEngine.layout(
                score: scoreWithHiddenRest(),
                options: ScoreViewOptions(showsInvisibleElements: false),
                availableWidth: 800,
            )
            #expect(rests(doc, inInvisible: false).isEmpty)
            #expect(rests(doc, inInvisible: true).isEmpty)
        }

        @Test func hiddenRestTaggedWhenToggleOn() {
            let doc = LayoutEngine.layout(
                score: scoreWithHiddenRest(),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            #expect(rests(doc, inInvisible: false).isEmpty)
            #expect(rests(doc, inInvisible: true).count == 1)
        }

        /// Two-note chord whose notes are both hidden (per-note `visible
        /// = false`). All-notes-invisible must hide the whole chord.
        private func scoreWithAllNotesHiddenChord() -> Score {
            var n1 = Note(pitch: 60, tpc: 14)
            n1.visible = false
            var n2 = Note(pitch: 64, tpc: 18)
            n2.visible = false
            let chord = Chord(
                duration: .quarter, notes: ChordNotes([n1, n2]),
            )
            return scoreWithSingleChord(chord)
        }

        private func chords(
            _ doc: LayoutDocument,
            inInvisible: Bool = false,
        ) -> [LayoutElement] {
            doc.systems.flatMap(\.measures)
                .flatMap { inInvisible ? $0.invisibleElements : $0.elements }
                .filter {
                    if case .chord = $0 { true } else { false }
                }
        }

        @Test func allNotesInvisibleHidesChordWhenToggleOff() {
            let doc = LayoutEngine.layout(
                score: scoreWithAllNotesHiddenChord(),
                options: ScoreViewOptions(showsInvisibleElements: false),
                availableWidth: 800,
            )
            // No chord in either visible or invisible list — slot still
            // preserved by tick cursor.
            #expect(chords(doc, inInvisible: false).isEmpty)
            #expect(chords(doc, inInvisible: true).isEmpty)
        }

        @Test func allNotesInvisibleRoutesChordWhenToggleOn() {
            let doc = LayoutEngine.layout(
                score: scoreWithAllNotesHiddenChord(),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            #expect(chords(doc, inInvisible: false).isEmpty)
            let invisibleChords = chords(doc, inInvisible: true)
            #expect(invisibleChords.count == 1)
            if let first = invisibleChords.first,
               case let .chord(notes, _, _, _, _, _, _, _, _) = first
            {
                let invisibleCount = notes.count(where: \.isInvisible)
                #expect(invisibleCount == notes.count)
                // Both source notes must be present (full list, per-note
                // isInvisible flags set) — this is what proves the
                // emittedChordNotes filter was removed.
                #expect(notes.count == 2)
            }
        }

        /// Two-note chord where only one note is hidden. The emitted
        /// .chord LayoutElement must contain BOTH notes (with per-note
        /// `isInvisible`) so stem geometry remains correct regardless
        /// of the toggle.
        private func scoreWithPartiallyHiddenChord() -> Score {
            let n1 = Note(pitch: 60, tpc: 14)
            var n2 = Note(pitch: 64, tpc: 18)
            n2.visible = false
            let chord = Chord(
                duration: .quarter, notes: ChordNotes([n1, n2]),
            )
            return scoreWithSingleChord(chord)
        }

        @Test func partialHiddenChordPreservesStemGeometry() {
            for toggle in [false, true] {
                let doc = LayoutEngine.layout(
                    score: scoreWithPartiallyHiddenChord(),
                    options: ScoreViewOptions(showsInvisibleElements: toggle),
                    availableWidth: 800,
                )
                // Inspect either visible or invisible chord (only the
                // partial case applies — chord must remain in visible
                // because not allNotesInvisible).
                let allChords = chords(doc, inInvisible: false)
                #expect(allChords.count == 1)
                if let first = allChords.first,
                   case let .chord(notes, _, _, _, _, _, _, _, _) = first
                {
                    // FULL note list must be present — proves stem
                    // geometry sees both notes regardless of toggle.
                    #expect(notes.count == 2)
                    // Exactly one is flagged invisible (the hidden one).
                    #expect(notes.count(where: \.isInvisible) == 1)
                }
            }
        }
    }
#endif
