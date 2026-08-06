#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    import SheetMusicEditWire
    @testable import SheetMusicLayout
    import Testing

    /// Task 10: selection tint is a re-encode of the already-cached `LayoutDocument`, never a relayout. The
    /// bridge brackets the draw commands belonging to a selected `ScoreItemID` with `.setColor(argb:)` …
    /// `.setColor(argb: blackARGB)`, and `nil` must reproduce today's output byte-for-byte — that is what
    /// keeps the non-editing Reader from paying for a feature it never uses.
    struct DrawProgramSelectionTests {
        private let _installApple = TestSupport.installApple

        private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        private static let tintArgb: UInt32 = 0xFFAB_CDEF

        private static func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 1200,
            )
        }

        private static func setColorIndices(_ commands: [DrawCommand], argb: UInt32) -> [Int] {
            commands.indices.filter {
                if case let .setColor(a) = commands[$0] { return a == argb }
                return false
            }
        }

        // MARK: - Fixtures

        /// One measure, 4/4, a single plain quarter chord (no author color, no accidental, no tuplet, no
        /// invisible elements) followed by three quarter rests — nothing anywhere in this fixture should ever
        /// need a `.setColor` command on its own.
        private static func plainQuarterChordScore() -> Score {
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
            )
        }

        /// Same measure shape, but element index 1 is a two-note chord: C4 (pitch 60) below E4 (pitch 64) —
        /// the fixture Test 2 needs to prove a selected notehead tints only itself, not its chord-mate.
        private static func twoNoteChordScore() -> Score {
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(
                    duration: .quarter,
                    notes: [Note(pitch: 60, tpc: 14), Note(pitch: 64, tpc: 18)],
                )),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
            )
        }

        /// One measure, 4/4: a triplet of quarter-time chords (C4, D4, E4 — each 1/12 of a whole note, filling
        /// one quarter beat) followed by three quarter rests. `Voice.tuplets` carries the matching `Tuplet`
        /// span so `LayoutEngine` emits a `.tupletLabel` with a populated `tupletID` — see
        /// `LayoutEngine+Placement.swift`'s tuplet-bracket pass, which builds that ID from
        /// `(staff, measureIndex, voiceIndex, tuplet.startIndex)`.
        private static func tripletScore() -> Score {
            let third = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))
            let voice = Voice(
                elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(Chord(duration: third, notes: [Note(pitch: 60, tpc: 14)])),
                    .chord(Chord(duration: third, notes: [Note(pitch: 62, tpc: 16)])),
                    .chord(Chord(duration: third, notes: [Note(pitch: 64, tpc: 18)])),
                    .rest(duration: .quarter),
                    .rest(duration: .quarter),
                    .rest(duration: .quarter),
                ],
                tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)],
            )
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
            )
        }

        /// A single dotted-quarter, parenthesized C4 (no accidental, so the only tint-eligible glyph is the
        /// notehead itself) followed by filler eighth rests to complete the 4/4 measure. Built to isolate dots
        /// (`.fillRect` commands) and parenthesis glyphs (SMuFL 0xE0F5 / 0xE0F6) from the notehead so a test
        /// can check they land outside the tint bracket.
        private static func dottedParenthesizedNoteScore() -> Score {
            let note = Note(pitch: 60, tpc: 14, parentheses: .both)
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .fraction(Fraction(numerator: 3, denominator: 8)), notes: [note])),
                .rest(duration: .eighth),
                .rest(duration: .eighth),
                .rest(duration: .eighth),
                .rest(duration: .eighth),
                .rest(duration: .eighth),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
            )
        }

        /// A single note carrying an author color (`<Note><color>`, opaque red) — the fixture Finding 2's
        /// "nil tint must not disturb the author-color path" test needs, since `plainQuarterChordScore` was
        /// deliberately colorless and can't exercise it.
        private static func authorColoredNoteScore() -> Score {
            var note = Note(pitch: 60, tpc: 14)
            note.elementProperties.color = ScoreColor(red: 255, green: 0, blue: 0)
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [note])),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
            )
        }

        /// A two-note chord whose upper note (E4) is individually hidden while the chord itself stays visible
        /// — the fixture Finding 2's "nil tint must not disturb the invisible-note reset" test needs, since it
        /// is the one path `resetArgb` overrides away from `blackARGB`. Mirrors
        /// `LayoutBridgeInvisibleTests.scoreWithPartlyHiddenChord`.
        private static func partlyHiddenChordScore() -> Score {
            let lower = Note(pitch: 60, tpc: 14)
            var upper = Note(pitch: 64, tpc: 18)
            upper.visible = false
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [lower, upper])),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
            )
        }

        // MARK: - Tests

        /// With no selection the encoder must produce exactly what it produced before this feature existed —
        /// otherwise every unselected redraw pays for a feature it isn't using. Two independent gates: passing
        /// `tint: nil` explicitly must equal omitting the parameter, AND (the stronger check — a mutant that
        /// unconditionally brackets every note would still pass the first gate, since both calls take the same
        /// code path) a plain, colorless, tuplet-less fixture must emit zero `.setColor` commands at all.
        @Test("an empty tint changes nothing")
        func emptyTintChangesNothing() {
            let doc = Self.layout(Self.plainQuarterChordScore())

            let withExplicitNil = LayoutBridge.buildCommands(layout: doc, tint: nil)
            let withOmittedTint = LayoutBridge.buildCommands(layout: doc)
            #expect(withExplicitNil == withOmittedTint)

            let hasAnySetColor = withExplicitNil.contains {
                if case .setColor = $0 { return true }
                return false
            }
            #expect(!hasAnySetColor)
        }

        /// The "empty tint changes nothing" gate above uses a colorless, non-invisible fixture specifically so
        /// it can assert *zero* `.setColor` commands — but that means it never actually exercises the two
        /// pre-existing paths careless parameter threading is most likely to break: the author-color path
        /// (`note.color`) and the invisible-element path (`resetArgb: invisibleARGB`). This test closes that
        /// gap for the author-color path: a `tint: nil` call must still equal the no-tint entry point, AND the
        /// author color's own `.setColor` must still be present — proving the threading didn't accidentally
        /// swallow it.
        @Test("a nil tint does not disturb the author-color path")
        func nilTintPreservesAuthorColor() {
            let doc = Self.layout(Self.authorColoredNoteScore())

            let withTintNil = LayoutBridge.buildCommands(layout: doc, tint: nil)
            let withNoTint = LayoutBridge.buildCommands(layout: doc)
            #expect(withTintNil == withNoTint)

            // 0xFFFF0000 = opaque red, per `LayoutBridge.argb(from:)`'s ARGB (0xAARRGGBB) packing of
            // `ScoreColor(red: 255, green: 0, blue: 0)`. Not asserting an exact count: the stem/flag inherit
            // the chord's notehead color too (`encodeChord`'s "first colored note wins" — a second, unrelated
            // bracket), so more than one occurrence is legitimate; the point here is "at least one", not
            // "exactly one".
            let authorArgb: UInt32 = 0xFFFF_0000
            #expect(!Self.setColorIndices(withTintNil, argb: authorArgb).isEmpty)
        }

        /// Same gap, for the invisible-element path: a per-note-invisible chord routes through
        /// `resetArgb: LayoutBridge.invisibleARGB` instead of the default `blackARGB` (see `encodeChord`), so
        /// it is the one call site most likely to regress silently from careless parameter threading.
        @Test("a nil tint does not disturb the invisible-element path")
        func nilTintPreservesInvisibleReset() {
            let doc = LayoutEngine.layout(
                score: Self.partlyHiddenChordScore(),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 1200,
            )

            let withTintNil = LayoutBridge.buildCommands(layout: doc, tint: nil)
            let withNoTint = LayoutBridge.buildCommands(layout: doc)
            #expect(withTintNil == withNoTint)

            #expect(!Self.setColorIndices(withTintNil, argb: LayoutBridge.invisibleARGB).isEmpty)
        }

        /// A selected notehead is bracketed by `setColor(argb)` … `setColor(default)`, and its chord-mate is
        /// not — the per-note (not per-chord) granularity `ScoreLayerBuilder+Chord.swift` establishes. Proven
        /// without hardcoding any glyph coordinates: selecting C4 vs. selecting E4 (same document, same call)
        /// must each tint exactly one bracket, and the two must land on different glyphs. A mutant that tints
        /// the whole chord would fail the "exactly one bracket" check; a mutant that always tints the same
        /// note regardless of which ID was selected would fail the "different glyphs" check.
        @Test("a selected note is tinted and its neighbor is not")
        func selectedNoteTintedNeighborNot() throws {
            let doc = Self.layout(Self.twoNoteChordScore())
            let c4 = NoteID(staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0)
            let e4 = NoteID(staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 1)

            func tintedGlyphPosition(selecting id: NoteID) throws -> (Double, Double) {
                let commands = LayoutBridge.buildCommands(
                    layout: doc, tint: (argb: Self.tintArgb, ids: [.note(id)]),
                )
                let brackets = Self.setColorIndices(commands, argb: Self.tintArgb)
                #expect(brackets.count == 1)
                let idx = try #require(brackets.first)
                guard idx + 1 < commands.count, case let .glyph(_, x, y, _, _) = commands[idx + 1] else {
                    Issue.record("expected a glyph immediately after the tint bracket")
                    return (.nan, .nan)
                }
                return (x, y)
            }

            let posWhenC4Selected = try tintedGlyphPosition(selecting: c4)
            let posWhenE4Selected = try tintedGlyphPosition(selecting: e4)
            #expect(posWhenC4Selected != posWhenE4Selected)
        }

        /// A selected note's dots and parentheses must NOT take the tint — only the notehead (and, if present,
        /// the accidental) do. This is not a looser granularity choice; it's `ScoreLayerBuilder+Chord.swift`'s
        /// own mechanism (`drawChord` attaches only the notehead + accidental glyph layers to `.note(noteID)`;
        /// `drawNoteheadParentheses` and `drawDots` attach nothing, so Apple's `applySelection` cannot reach
        /// them). Dots surface as `.fillRect` commands and parens as `.glyph` commands carrying SMuFL 0xE0F5 /
        /// 0xE0F6 — this test locates both by shape/codepoint (no coordinate math) and asserts neither one ever
        /// has an active `.setColor(argb: tintArgb)` ahead of it in command order.
        @Test("a selected note's dots and parentheses stay outside the tint bracket")
        func selectedNoteDotsAndParensStayUntinted() {
            let doc = Self.layout(Self.dottedParenthesizedNoteScore())
            let noteID = NoteID(
                staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            )
            let commands = LayoutBridge.buildCommands(
                layout: doc, tint: (argb: Self.tintArgb, ids: [.note(noteID)]),
            )

            // Exactly one bracket — the notehead. No accidental in this fixture, so no second one.
            #expect(Self.setColorIndices(commands, argb: Self.tintArgb).count == 1)

            /// "Inside a tint bracket" = the most recent `.setColor` at or before this index set the tint
            /// color and hasn't been superseded yet.
            func isTintedAt(_ index: Int) -> Bool {
                var tinted = false
                for i in 0 ..< index {
                    if case let .setColor(a) = commands[i] { tinted = a == Self.tintArgb }
                }
                return tinted
            }

            let parenGlyphIndices = commands.indices.filter {
                if case let .glyph(cp, _, _, _, _) = commands[$0] { return cp == 0xE0F5 || cp == 0xE0F6 }
                return false
            }
            #expect(!parenGlyphIndices.isEmpty)
            #expect(parenGlyphIndices.allSatisfy { !isTintedAt($0) })

            let dotIndices = commands.indices.filter {
                if case .fillRect = commands[$0] { return true }
                return false
            }
            #expect(!dotIndices.isEmpty)
            #expect(dotIndices.allSatisfy { !isTintedAt($0) })
        }

        /// Selecting a tuplet tints every member, because `SelectionExpansion` says so — the same rule the
        /// Apple renderer follows (see `SelectionExpansion.expand(_:in:)`'s doc comment). The `ids` set here is
        /// pre-expanded by the test, exactly as a real caller would: `LayoutBridge.buildCommands` does no
        /// expansion of its own. Would fail if the bridge tinted only the ID it was literally handed (the
        /// tuplet ID) and ignored the member note IDs the expansion also produced — the bracket text would
        /// light up but all three noteheads would stay black, so the count below would read 1, not 4.
        @Test("a tuplet selection tints its members")
        func tupletSelectionTintsItsMembers() {
            let score = Self.tripletScore()
            let doc = Self.layout(score)
            let tid = TupletID(staff: Self.staff0, measureIndex: 0, voiceIndex: 0, startElementIndex: 1)
            let ids = SelectionExpansion.expand(.tuplet(tid), in: score)
            // Sanity on the fixture itself: the tuplet ID plus its 3 note members, nothing else.
            #expect(ids.count == 4)

            let commands = LayoutBridge.buildCommands(
                layout: doc, tint: (argb: Self.tintArgb, ids: ids),
            )

            let brackets = Self.setColorIndices(commands, argb: Self.tintArgb)
            #expect(brackets.count == 4)
        }

        /// Round-trips the wire payload `LayoutBridge.buildCommands(layout:tint:)`'s future JNI caller will
        /// send: a color plus an unordered ID set. Exercises all 4 `ScoreItemID` cases so a case this codec
        /// mishandles doesn't hide behind ones it handles correctly.
        @Test("SelectionTintCodec round-trips argb + ids")
        func selectionTintCodecRoundTrips() throws {
            let ids: Set<ScoreItemID> = [
                .note(NoteID(staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0)),
                .rest(RestID(staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2)),
                .tuplet(TupletID(staff: Self.staff0, measureIndex: 0, voiceIndex: 0, startElementIndex: 1)),
                .clef(.staffDefault(Self.staff0)),
            ]
            let data = SelectionTintCodec.encode(argb: Self.tintArgb, ids: ids)
            let decoded = try SelectionTintCodec.decode(data)
            #expect(decoded.argb == Self.tintArgb)
            #expect(decoded.ids == ids)
        }
    }
#endif
