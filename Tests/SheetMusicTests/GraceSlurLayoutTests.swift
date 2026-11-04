#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    #if !canImport(CoreGraphics)
        private typealias CGFloat = SheetMusicLayout.CGFloat
        private typealias CGPoint = SheetMusicLayout.CGPoint
    #endif

    /// Slurs with a grace chord at one end are laid out between that grace's notehead and the other end, the way
    /// MuseScore draws the acciaccatura slurred into its principal note.
    @Suite("Grace-note slur layout")
    struct GraceSlurLayoutTests {
        private let _installApple = TestSupport.installApple

        @Test("a grace slurred into its principal pairs the grace with its own chord")
        func graceIntoPrincipalPairs() throws {
            let score = Self.score(graceSlur: Spanner(kind: .slur, rawType: "Slur"))
            let pairing = try #require(LayoutEngine.collectSlurs(score: score).first)
            #expect(LayoutEngine.collectSlurs(score: score).count == 1)
            #expect(pairing.start.grace == .init(side: .before, index: 0))
            #expect(pairing.start.elementIndex == 1) // after the time signature
            #expect(pairing.end.grace == nil)
            #expect(pairing.end.elementIndex == 1)
            // A grace's slur has no `SlurID` to name it, so it is drawn but not selectable.
            #expect(pairing.identity == nil)
        }

        @Test("the arc runs from the grace notehead to the principal notehead, below the up-stemmed grace")
        func graceIntoPrincipalArc() throws {
            let score = Self.score(graceSlur: Spanner(kind: .slur, rawType: "Slur"))
            let document = Self.layout(score)
            let arcs = Self.arcs(in: document)
            #expect(arcs.count == 1)
            let arc = try #require(arcs.first)
            let grace = try #require(Self.graceHeadX(in: document))
            let principal = try #require(Self.chordHeadXs(in: document).first)
            #expect(abs(arc.from.x - grace) < 0.5)
            #expect(abs(arc.to.x - principal) < 0.5)
            #expect(arc.from.x < arc.to.x)
            // `SlurTieLayout::computeUp`: `setUp(!chordRest1->up())` — a grace's stem is up, so the slur hangs below.
            #expect(arc.above == false)
        }

        @Test("a slur ending on the next chord's grace stops at that grace, not at its chord")
        func chordIntoNextGrace() throws {
            let score = Self.score(chordSlur: Spanner(
                kind: .slur, rawType: "Slur", nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
                nextGraceIndex: 0,
            ))
            let pairing = try #require(LayoutEngine.collectSlurs(score: score).first)
            #expect(pairing.start.grace == nil)
            #expect(pairing.end.elementIndex == 2)
            #expect(pairing.end.grace == .init(side: .before, index: 0))
            // A slur stored on a chord keeps its selectable identity, wherever it ends.
            #expect(pairing.identity != nil)
            let document = Self.layout(score)
            let arc = try #require(Self.arcs(in: document).first)
            let grace = try #require(Self.graceHeadX(in: document))
            #expect(abs(arc.to.x - grace) < 0.5)
        }

        @Test("a grace index the end chord has no grace for draws nothing")
        func missingEndGraceDropsSilently() {
            let score = Self.score(chordSlur: Spanner(
                kind: .slur, rawType: "Slur", nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
                nextGraceIndex: 3,
            ))
            #expect(LayoutEngine.collectSlurs(score: score).isEmpty)
            #expect(Self.arcs(in: Self.layout(score)).isEmpty)
        }

        // MARK: - Helpers

        /// One 2/4 bar: a quarter C5 with an acciaccatura D5 before it (carrying `graceSlur`), then a quarter B4.
        private static func score(graceSlur: Spanner) -> Score {
            let grace = GraceChord(
                graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: 74, tpc: 16)], spanners: [graceSlur],
            )
            return score(elements: [
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)], graceNotesBefore: [grace])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 71, tpc: 19)])),
            ])
        }

        /// One 2/4 bar: a quarter C5 carrying `chordSlur`, then a quarter B4 with an acciaccatura D5 before it.
        private static func score(chordSlur: Spanner) -> Score {
            let grace = GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: 74, tpc: 16)])
            return score(elements: [
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)], spanners: [chordSlur])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 71, tpc: 19)], graceNotesBefore: [grace])),
            ])
        }

        private static func score(elements: [VoiceElement]) -> Score {
            ScoreEditor(score: Score(division: 480, parts: [Part(
                id: "1", instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 2, denominator: 4)),
                ] + elements)])])],
            )])).score
        }

        private static func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(score: score, options: .init(), availableWidth: 800)
        }

        /// Every slur arc in the document, in absolute coordinates.
        private static func arcs(in document: LayoutDocument) -> [(from: CGPoint, to: CGPoint, above: Bool)] {
            document.systems.flatMap { system in
                system.spanners.compactMap { element in
                    guard case let .tieArc(from, to, above, _) = element else { return nil }
                    return (
                        CGPoint(x: from.x + system.origin.x, y: from.y + system.origin.y),
                        CGPoint(x: to.x + system.origin.x, y: to.y + system.origin.y),
                        above,
                    )
                }
            }
        }

        /// Absolute x of the one grace notehead.
        private static func graceHeadX(in document: LayoutDocument) -> CGFloat? {
            for system in document.systems {
                for measure in system.measures {
                    for element in measure.elements {
                        guard case let .graceChord(notes, _, stem, _, _, _, mag, _) = element,
                              let note = notes.first
                        else { continue }
                        return system.origin.x + measure.origin.x + note.origin.x
                            + note.mirrorDx(stem: stem, sp: document.metrics.sp * mag)
                    }
                }
            }
            return nil
        }

        /// Absolute x of each ordinary chord's first notehead, in order.
        private static func chordHeadXs(in document: LayoutDocument) -> [CGFloat] {
            document.systems.flatMap { system in
                system.measures.flatMap { measure in
                    measure.elements.compactMap { element -> CGFloat? in
                        guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = element,
                              let note = notes.first
                        else { return nil }
                        return system.origin.x + measure.origin.x + note.origin.x
                            + note.mirrorDx(stem: stem, sp: document.metrics.sp)
                    }
                }
            }
        }
    }
#endif
