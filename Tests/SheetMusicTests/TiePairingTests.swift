#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    #if !canImport(CoreGraphics)
        /// On Android and WebAssembly, SheetMusicCore and SheetMusicLayout both export portable
        /// `CGFloat` / `CGPoint` shims, so anchor explicitly to SheetMusicLayout's definitions.
        ///
        /// `private typealias` keeps these file-scoped — a module-scope alias here would collide
        /// with the same pattern in every other file in this target that needs it.
        private typealias CGFloat = SheetMusicLayout.CGFloat
        private typealias CGPoint = SheetMusicLayout.CGPoint
    #endif

    @Suite("Tie pairing")
    struct TiePairingTests {
        private let _installApple = TestSupport.installApple

        @Test("Two quarter notes tied with number 1 produce one TiePair")
        func twoQuartersTied() {
            guard #available(macOS 15.0, *) else { return }
            let a = Note(pitch: 60, tpc: 14, tieForward: 1)
            let b = Note(pitch: 60, tpc: 14, tieBack: 1)
            let m = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [a])),
                .chord(Chord(duration: .quarter, notes: [b])),
            ])])
            let staff = Staff(measures: [m])
            let score = ScoreEditor(score: Score(
                division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
            )).score
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            let ties = LayoutEngine.resolveTies(for: doc, score: score)
            #expect(ties.count == 1)
        }

        @Test("Unmatched tieForward with no tieBack produces no pair")
        func unmatchedTie() {
            guard #available(macOS 15.0, *) else { return }
            let a = Note(pitch: 60, tpc: 14, tieForward: 1)
            let b = Note(pitch: 60, tpc: 14) // no tieBack
            let m = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [a])),
                .chord(Chord(duration: .quarter, notes: [b])),
            ])])
            let staff = Staff(measures: [m])
            let score = ScoreEditor(score: Score(
                division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
            )).score
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            let ties = LayoutEngine.resolveTies(for: doc, score: score)
            #expect(ties.isEmpty)
        }

        @Test("Tie matched across a system break (vertical wrap)")
        func tieAcrossSystemBreak() {
            guard #available(macOS 15.0, *) else { return }
            // Two tied notes in adjacent measures. Force a wrap by making
            // the available width too small to hold both measures so the
            // second one is pushed to a new system. An earlier version
            // discriminated ties by absolute staff-midline Y, which
            // differs across systems and silently dropped these pairs.
            let a = Note(pitch: 60, tpc: 14, tieForward: 1)
            let b = Note(pitch: 60, tpc: 14, tieBack: 1)
            let m1 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [a])),
            ])])
            let m2 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [b])),
            ])])
            let staff = Staff(measures: [m1, m2])
            let score = ScoreEditor(score: Score(
                division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
            )).score
            let opts = ScoreViewOptions(wrapToViewWidth: true)
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: 200,
            )
            // Sanity: the wrap actually produced two systems.
            #expect(doc.systems.count == 2)
            let ties = LayoutEngine.resolveTies(for: doc, score: score)
            #expect(ties.count == 1)
            // The pair endpoints sit in different systems (the from and
            // to absolute Y values land in distinct system bands).
            if let pair = ties.first {
                let fromIdx = LayoutEngine.systemIndex(
                    for: pair.fromOrigin.y, in: doc.systems,
                )
                let toIdx = LayoutEngine.systemIndex(
                    for: pair.toOrigin.y, in: doc.systems,
                )
                #expect(fromIdx != toIdx)
            }
        }

        @Test("Cross-system tie attaches a half-arc to BOTH systems")
        func crossSystemHalfArcs() {
            guard #available(macOS 15.0, *) else { return }
            let a = Note(pitch: 60, tpc: 14, tieForward: 1)
            let b = Note(pitch: 60, tpc: 14, tieBack: 1)
            let m1 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [a])),
            ])])
            let m2 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [b])),
            ])])
            let staff = Staff(measures: [m1, m2])
            let score = ScoreEditor(score: Score(
                division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
            )).score
            let opts = ScoreViewOptions(wrapToViewWidth: true)
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: 200,
            )
            #expect(doc.systems.count == 2)
            /// System 0 carries a half-arc from the chord out to its right
            /// edge; system 1 carries the matching half-arc from a point
            /// just before the chord up to the chord. Anchoring the END
            /// segment at x=0 would cross the synthesised clef + key sig,
            /// which is wrong — we anchor it near `firstContentX` instead.
            func tieArcs(in system: LayoutSystem) -> [(from: CGPoint, to: CGPoint)] {
                system.spanners.compactMap { el in
                    if case let .tieArc(f, t, _, _) = el {
                        return (from: f, to: t)
                    }
                    return nil
                }
            }
            let arcs0 = tieArcs(in: doc.systems[0])
            let arcs1 = tieArcs(in: doc.systems[1])
            #expect(arcs0.count == 1)
            #expect(arcs1.count == 1)
            // BEGIN segment ends near the right edge of system 0.
            if let arc = arcs0.first {
                #expect(arc.to.x >= doc.systems[0].size.width - 4)
            }
            // END segment starts AFTER x=0 (i.e., past the synth header).
            if let arc = arcs1.first {
                #expect(arc.from.x > 0)
            }
        }

        @Test("A same-system tie preserves exact source and destination note IDs")
        func sameSystemTieIdentity() throws {
            guard #available(macOS 15.0, *) else { return }
            let (score, document) = Self.identityFixture(split: false)
            let pairs = LayoutEngine.resolveTies(for: document, score: score)
            #expect(pairs.count == 1)
            let pair = try #require(pairs.first)
            #expect(pair.identity == Self.tieIdentity)
            #expect(pair.staff == 0)
            #expect(pair.fromOrigin == CGPoint(x: 30, y: 20))
            #expect(pair.toOrigin == CGPoint(x: 60, y: 20))
            #expect(pair.above)
            let systems = LayoutEngine.attachTies(to: document.systems, pairs: pairs, metrics: document.metrics)
            #expect(systems[0].spanners == [.tieArc(
                fromOrigin: CGPoint(x: 30, y: 20), toOrigin: CGPoint(x: 60, y: 20),
                above: true, identity: Self.tieIdentity,
            )])
            #expect(systems[0].spanners.first?.elementID == Self.tieIdentity)
            #expect(systems[0].spanners.first?.elementItemID == .element(Self.tieIdentity))
            let unaddressed = LayoutElement.tieArc(
                fromOrigin: CGPoint(x: 30, y: 20), toOrigin: CGPoint(x: 60, y: 20), above: true,
            )
            #expect(unaddressed.elementID == nil)
        }

        @Test("Both cross-system segments retain identity and exact local endpoints")
        func splitTieIdentityAndGeometry() throws {
            guard #available(macOS 15.0, *) else { return }
            let (score, document) = Self.identityFixture(split: true)
            let pairs = LayoutEngine.resolveTies(for: document, score: score)
            #expect(pairs.count == 1)
            let pair = try #require(pairs.first)
            #expect(pair.identity == Self.tieIdentity)
            #expect(pair.fromOrigin == CGPoint(x: 30, y: 20))
            #expect(pair.toOrigin == CGPoint(x: 60, y: 120))
            #expect(LayoutEngine.firstContentX(in: document.systems[1]) == 60)
            let systems = LayoutEngine.attachTies(to: document.systems, pairs: pairs, metrics: document.metrics)
            // BEGIN ends at width - 2 = 98.
            #expect(systems[0].spanners == [.tieArc(
                fromOrigin: CGPoint(x: 30, y: 20), toOrigin: CGPoint(x: 98, y: 20),
                above: true, identity: Self.tieIdentity,
            )])
            // END starts at min(max(60 - 5, 60 - 40), 60 - 10) = 50; local Y = 120 - 100 = 20.
            #expect(systems[1].spanners == [.tieArc(
                fromOrigin: CGPoint(x: 50, y: 20), toOrigin: CGPoint(x: 60, y: 20),
                above: true, identity: Self.tieIdentity,
            )])
            #expect(systems.flatMap(\.spanners).compactMap(\.elementID) == [Self.tieIdentity, Self.tieIdentity])
        }

        @Test("A forward-only tie gets neither a fabricated identity nor an arc")
        func unmatchedTieHasNoIdentityOrArc() {
            guard #available(macOS 15.0, *) else { return }
            let (score, document) = Self.identityFixture(split: false, matched: false)
            let pairs = LayoutEngine.resolveTies(for: document, score: score)
            #expect(pairs.isEmpty)
            let systems = LayoutEngine.attachTies(to: document.systems, pairs: pairs, metrics: document.metrics)
            #expect(systems == document.systems)
            #expect(systems.flatMap(\.spanners).isEmpty)
        }

        private static let tieStart = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
        )
        private static let tieEnd = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 1, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
        )
        private static let tieIdentity = ScoreElementID.tie(start: tieStart, end: tieEnd)

        private static func identityFixture(split: Bool, matched: Bool = true) -> (Score, LayoutDocument) {
            let measures = [
                Measure(voices: [Voice(elements: [
                    .rest(duration: .quarter),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14, tieForward: 7)])),
                ])]),
                Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .quarter, notes: [
                        Note(pitch: 60, tpc: 14, tieBack: matched ? 7 : nil),
                    ])),
                ])]),
            ]
            let score = ScoreEditor(score: Score(division: 480, parts: [
                Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: measures)]),
            ])).score
            let first = LayoutMeasure(
                measureIndex: 0, origin: .zero, width: 100,
                elements: [identityChord(id: tieStart, x: 30, forward: 7, back: nil)],
            )
            let second = LayoutMeasure(
                measureIndex: 1, origin: .zero, width: 100,
                elements: [identityChord(id: tieEnd, x: 60, forward: nil, back: matched ? 7 : nil)],
            )
            let systems = split
                ? [identitySystem(y: 0, measures: [first]), identitySystem(y: 100, measures: [second])]
                : [identitySystem(y: 0, measures: [first, second])]
            return (score, LayoutDocument(
                size: .init(width: 100, height: 140), systems: systems, metrics: StaffMetrics(staffSize: 40),
            ))
        }

        private static func identityChord(id: NoteID, x: CGFloat, forward: Int?, back: Int?) -> LayoutElement {
            .chord(
                notes: [LayoutChordNote(
                    noteID: id, step: 0, accidental: nil, origin: CGPoint(x: x, y: 20),
                    tieForward: forward, tieBack: back, hasGlissando: false,
                )],
                duration: .quarter, stem: .down, stemOrigin: CGPoint(x: x, y: 20),
                hasArpeggio: false, arpeggioRawType: nil, isBeamed: false,
                voiceIndex: 0, stemExtension: 0, stemIsInvisible: false, mag: 1,
            )
        }

        private static func identitySystem(y: CGFloat, measures: [LayoutMeasure]) -> LayoutSystem {
            LayoutSystem(
                origin: CGPoint(x: 0, y: y), size: .init(width: 100, height: 40), measures: measures,
                staffOrigins: [.zero], staffAddresses: [tieStart.staff], partLabels: [], spanners: [], sp: 10,
            )
        }
    }
#endif
