#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    /// A clef a bar opens with is drawn small at the end of the bar before it, before the barline — MuseScore's
    /// spelling of a clef change at a barline (`LayoutEngine+BarlineClef`). A system head draws it in its own header as
    /// well, and the system before announces it.
    @Suite("Clef change at a barline")
    struct BarlineClefLayoutTests {
        /// `LayoutEngine.layout` asserts a real FontMetrics provider.
        private let _installApple = TestSupport.installApple

        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        /// The bass clef bar 1 opens with.
        private static let anchor = ClefAnchor.explicit(VoiceElementID(
            staff: staff, measureIndex: 1, voiceIndex: 0, elementIndex: 0,
        ))

        // MARK: - Fixtures

        private static func quarter(_ pitch: Int) -> VoiceElement {
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: pitch, tpc: 14)])))
        }

        /// Three 4/4 bars of quarters; bar 1 opens with `clef` (a bass clef by default).
        private static func score(
            clef: String = "F", lineBreakAfterFirst: Bool = false, sectionBreakAfterFirst: Bool = false,
        ) -> Score {
            var first = Measure(voices: [Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                quarter(72), quarter(74), quarter(76), quarter(77),
            ])])
            first.lineBreak = lineBreakAfterFirst
            first.sectionBreak = sectionBreakAfterFirst
            let second = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: clef)), quarter(48), quarter(50), quarter(52), quarter(53),
            ])])
            let third = Measure(voices: [Voice(elements: [quarter(48), quarter(50), quarter(52), quarter(53)])])
            return Score(division: 480, parts: [
                Part(id: "P0", instrument: Instrument(id: "x"), staves: [Staff(measures: [first, second, third])]),
            ])
        }

        private static func layout(_ score: Score, cache: LayoutCache? = nil) -> LayoutDocument {
            LayoutEngine.layout(
                score: score, options: ScoreViewOptions(wrapToViewWidth: true), availableWidth: 2000, cache: cache,
            )
        }

        // MARK: - Readers

        private struct DrawnClef {
            let rawType: String
            let x: CGFloat
            let mag: CGFloat
        }

        /// Every clef `measure` draws under `anchor`, in the measure's own coordinates.
        private static func clefs(in measure: LayoutMeasure, named anchor: ClefAnchor = anchor) -> [DrawnClef] {
            measure.elements.compactMap { element in
                guard case let .clef(rawType, origin, elementAnchor, mag) = element, elementAnchor == anchor
                else { return nil }
                return DrawnClef(rawType: rawType, x: origin.x, mag: mag)
            }
        }

        /// The x of `measure`'s first notehead, in the measure's own coordinates.
        private static func firstNoteX(in measure: LayoutMeasure) -> CGFloat? {
            measure.elements.lazy.compactMap { element -> CGFloat? in
                guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element else { return nil }
                return notes.first?.origin.x
            }.first
        }

        private static func advance(_ rawType: String, sp: CGFloat) -> CGFloat {
            let codepoint = ClefGlyph.glyph(for: NotatedClef(rawType: rawType)).codepoint
            guard let scalar = UnicodeScalar(codepoint) else { return 0 }
            return FontMetrics.provider.typographicWidth(
                text: String(Character(scalar)),
                font: LayoutFont(face: SMuFLFamily.bravura, pointSize: StaffMetrics(staffSize: sp * 4).glyphFontSize),
            )
        }

        // MARK: - Tests

        @Test("a clef a bar opens with mid-system is drawn small before the barline of the bar before")
        func midSystemClefMovesBeforeTheBarline() throws {
            let doc = Self.layout(Self.score())
            let sp = doc.metrics.sp
            let measures = try #require(doc.systems.first?.measures)
            try #require(doc.systems.count == 1 && measures.count == 3)

            let moved = Self.clefs(in: measures[0])
            #expect(moved.count == 1)
            let drawn = try #require(moved.first)
            #expect(drawn.rawType == "F")
            #expect(drawn.mag == LayoutEngine.smallClefMag)
            let right = drawn.x + Self.advance("F", sp: sp) * drawn.mag / 2
            #expect(abs((measures[0].width - sp / 2 - right) / sp - LayoutEngine.clefBarlineDistanceSp) < 0.01)
            #expect(Self.clefs(in: measures[1]).isEmpty)
        }

        /// The bar it leaves keeps no clef column: its first note stands where a bar with no header puts it.
        @Test("the bar a clef leaves draws no header for it")
        func barItLeavesHasNoClefColumn() throws {
            let doc = Self.layout(Self.score())
            let measures = try #require(doc.systems.first?.measures)
            try #require(measures.count == 3)
            let opening = try #require(Self.firstNoteX(in: measures[1]))
            let plain = try #require(Self.firstNoteX(in: measures[2]))
            #expect(abs(opening - plain) < 0.01)
        }

        @Test("a system head draws the clef it opens with full size, and the system before announces it small")
        func systemHeadKeepsItsClefAndIsAnnounced() throws {
            let doc = Self.layout(Self.score(lineBreakAfterFirst: true))
            try #require(doc.systems.count == 2)
            let ending = try #require(doc.systems[0].measures.last)
            let head = try #require(doc.systems[1].measures.first)

            #expect(Self.clefs(in: ending).map(\.mag) == [LayoutEngine.smallClefMag])
            #expect(Self.clefs(in: head).map(\.mag) == [1])
        }

        @Test("after a section break the clef stays in the bar it opens and is not announced")
        func sectionBreakKeepsTheClef() throws {
            let doc = Self.layout(Self.score(sectionBreakAfterFirst: true))
            let measures = doc.systems.flatMap(\.measures)
            try #require(measures.count == 3)
            #expect(Self.clefs(in: measures[0]).isEmpty)
            #expect(Self.clefs(in: measures[1]).map(\.mag) == [1])
        }

        /// The bar that draws the clef holds nothing of it: the clef lives in the next bar, which the width cache
        /// and the system cache key by separately.
        @Test("a cached layout redraws the bar before when the clef a bar opens with changes")
        func cacheFollowsTheNextBarsClef() throws {
            let cache = LayoutCache()
            _ = Self.layout(Self.score(), cache: cache)
            let doc = Self.layout(Self.score(clef: "C3"), cache: cache)
            let measures = try #require(doc.systems.first?.measures)
            #expect(Self.clefs(in: measures[0]).map(\.rawType) == ["C3"])
        }

        /// Across a system break the announcing system holds neither bar the clef lives in nor any width that tells
        /// a treble clef from an octave-down one — the system cache has to be keyed by the following clef itself.
        @Test("a cached layout re-announces a changed clef at the end of the system before")
        func cacheFollowsTheNextSystemsClef() throws {
            let cache = LayoutCache()
            _ = Self.layout(Self.score(clef: "G", lineBreakAfterFirst: true), cache: cache)
            let doc = Self.layout(Self.score(clef: "G8vb", lineBreakAfterFirst: true), cache: cache)
            let ending = try #require(doc.systems.first?.measures.last)
            #expect(Self.clefs(in: ending).map(\.rawType) == ["G8vb"])
        }

        @Test("a click on the moved clef selects the clef it names")
        func movedClefIsHitWhereItIsDrawn() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = Self.layout(Self.score())
            let rects = ScoreHitTester(document: doc).clefHitRects(for: Self.anchor)
            let system = try #require(doc.systems.first)
            let first = try #require(system.measures.first)
            let second = try #require(system.measures.dropFirst().first)
            try #require(rects.count == 1)
            let rect = try #require(rects.first)
            #expect(rect.midX > system.origin.x + first.origin.x + first.width / 2)
            #expect(rect.midX < system.origin.x + second.origin.x)
        }
    }
#endif
