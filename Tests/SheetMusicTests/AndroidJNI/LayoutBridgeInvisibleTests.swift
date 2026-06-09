#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// The Android draw-command bridge must engrave elements parked in the
    /// `invisibleElements` / `invisibleSpanners` containers (and per-note-
    /// invisible noteheads) when "Show Invisible" is on — drawing them in
    /// MuseScore's `invisibleColor()` = #808080 via a `setColor` run, matching
    /// the Apple `ScoreCanvas` / `ScoreLayerBuilder` renderers. With the
    /// toggle off they must be dropped entirely (no gray run).
    struct LayoutBridgeInvisibleTests {
        private let _installApple = TestSupport.installApple

        private static let invisibleGray: UInt32 = 0xFF80_8080

        // MARK: - Fixtures

        /// One-measure score whose only annotation is a hidden tempo mark
        /// (routed through `Score.systemMeasures`, exactly as
        /// `InvisibleLayoutTests`). The clef + time sig + chord scaffold the
        /// measure so layout has real content.
        private static func scoreWithHiddenTempo() -> Score {
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(chord),
            ])
            let systemMeasure = SystemMeasure(elements: [
                PositionedSystemElement(
                    position: .start,
                    element: .tempo(Tempo(beatsPerSecond: 2.0, visible: false)),
                ),
            ])
            return Score(
                division: 480,
                parts: [
                    Part(
                        id: "P1",
                        instrument: Instrument(id: "voice"),
                        staves: [Staff(measures: [Measure(voices: [voice])])],
                    ),
                ],
                systemMeasures: [systemMeasure],
            )
        }

        /// One-measure score with a single two-note chord whose upper note is
        /// optionally hidden. Both pitches are naturals (no accidental glyphs),
        /// so the only per-note glyph is the notehead itself.
        private static func scoreWithPartlyHiddenChord(hideUpper: Bool) -> Score {
            let lower = Note(pitch: 60, tpc: 14) // C4, visible
            var upper = Note(pitch: 64, tpc: 18) // E4
            upper.visible = !hideUpper
            let chord = Chord(duration: .quarter, notes: ChordNotes([lower, upper]))
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(chord),
            ])
            return Score(
                division: 480,
                parts: [
                    Part(
                        id: "P1",
                        instrument: Instrument(id: "voice"),
                        staves: [Staff(measures: [Measure(voices: [voice])])],
                    ),
                ],
            )
        }

        private static func commands(_ score: Score, showsInvisible: Bool) -> [DrawCommand] {
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(showsInvisibleElements: showsInvisible),
                availableWidth: 800,
            )
            return LayoutBridge.buildCommands(layout: doc)
        }

        private static func hasInvisibleGray(_ commands: [DrawCommand]) -> Bool {
            commands.contains { if case .setColor(Self.invisibleGray) = $0 { true } else { false } }
        }

        private static func glyphCount(_ commands: [DrawCommand]) -> Int {
            commands.reduce(into: 0) { if case .glyph = $1 { $0 += 1 } }
        }

        // MARK: - Invisible container (hidden tempo)

        @Test("hidden tempo is drawn in #808080 when the toggle is on")
        func hiddenTempoGrayedWhenOn() {
            #expect(Self.hasInvisibleGray(Self.commands(Self.scoreWithHiddenTempo(), showsInvisible: true)))
        }

        @Test("hidden tempo is dropped entirely when the toggle is off")
        func hiddenTempoDroppedWhenOff() {
            #expect(!Self.hasInvisibleGray(Self.commands(Self.scoreWithHiddenTempo(), showsInvisible: false)))
        }

        // MARK: - Per-note-invisible notehead

        @Test("a hidden notehead inside a visible chord is grayed when on")
        func hiddenNoteGrayedWhenOn() {
            #expect(Self.hasInvisibleGray(
                Self.commands(Self.scoreWithPartlyHiddenChord(hideUpper: true), showsInvisible: true),
            ))
        }

        @Test("a hidden notehead inside a visible chord is dropped when off")
        func hiddenNoteDroppedWhenOff() {
            let off = Self.commands(Self.scoreWithPartlyHiddenChord(hideUpper: true), showsInvisible: false)
            #expect(!Self.hasInvisibleGray(off))
            // The grayed-on pass adds back the hidden notehead glyph, so it
            // emits strictly more glyphs than the dropped-off pass.
            let on = Self.commands(Self.scoreWithPartlyHiddenChord(hideUpper: true), showsInvisible: true)
            #expect(Self.glyphCount(on) > Self.glyphCount(off))
        }

        @Test("a fully-visible chord emits no gray run regardless of the toggle")
        func visibleChordNeverGray() {
            #expect(!Self.hasInvisibleGray(
                Self.commands(Self.scoreWithPartlyHiddenChord(hideUpper: false), showsInvisible: true),
            ))
        }
    }
#endif
