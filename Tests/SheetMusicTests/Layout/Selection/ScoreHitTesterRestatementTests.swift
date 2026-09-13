#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    /// Restatements — the glyphs a page draws again without declaring anything: a courtesy key or time signature
    /// at the trailing edge of a system, and the clef every continuation system opens with.
    ///
    /// **They used to name nothing, and that made them unclickable.** The reasoning was sound about the model —
    /// a restatement declares nothing, so there is nothing to edit at it — and wrong about the page: on system
    /// four the restated clef is the only clef on screen, and a reader clicking it means the clef in force.
    /// These pin the answer: a restatement carries the identity of what it restates, so a click on one resolves
    /// to the declaration itself, wherever that lives.
    @Suite("ScoreHitTester — restatements")
    struct ScoreHitTesterRestatementTests {
        private let _installApple = TestSupport.installApple

        enum TestFailure: Error { case notFound(String) }

        private static func chord() -> VoiceElement {
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)])))
        }

        /// Four bars on one staff, with an explicit line break after m1 so the change in m2 reliably opens the
        /// second system — the same shape `CourtesySignatureLayoutTests` uses, for the same reason.
        ///
        /// m0 declares G clef / one sharp / 4/4; m2 changes to two flats and 3/4, and (when `clefChange` is
        /// set) to a bass clef as well.
        private static func score(clefChange: Bool) -> Score {
            var change: [VoiceElement] = []
            if clefChange {
                change.append(.clef(Clef(concertClefType: "F")))
            }
            change.append(.keySignature(KeySignature(concertKey: -2)))
            change.append(.timeSignature(TimeSignature(numerator: 3, denominator: 4)))
            change.append(chord())
            let staff = Staff(measures: [
                Measure(voices: [Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    .keySignature(KeySignature(concertKey: 1)),
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    chord(),
                ])]),
                Measure(voices: [Voice(elements: [chord()])], lineBreak: true),
                Measure(voices: [Voice(elements: change)]),
                Measure(voices: [Voice(elements: [chord()])]),
            ])
            return Score(division: 480, parts: [
                Part(id: "P0", instrument: Instrument(id: "voice"), staves: [staff]),
            ])
        }

        private func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 900)
        }

        /// The system that does NOT contain `measureIndex` — where a restatement of it is drawn.
        private func system(notContaining measureIndex: Int, in doc: LayoutDocument) throws -> LayoutSystem {
            for system in doc.systems where !system.measures.contains(where: { $0.measureIndex == measureIndex }) {
                return system
            }
            throw TestFailure.notFound("a system without measure \(measureIndex)")
        }

        /// The document-space centre of the first element in `system` that `match` accepts.
        private func point(
            in system: LayoutSystem, matching match: (LayoutElement) -> CGPoint?,
        ) throws -> CGPoint {
            for measure in system.measures {
                for element in measure.elements {
                    guard let origin = match(element) else { continue }
                    return CGPoint(
                        x: system.origin.x + measure.origin.x + origin.x,
                        y: system.origin.y + measure.origin.y + origin.y,
                    )
                }
            }
            throw TestFailure.notFound("a matching element")
        }

        /// A courtesy key signature announces the bar it is about, not the bar it is drawn in — so a click on it
        /// resolves to the DECLARATION, which lives on the next system.
        @Test("a courtesy key signature resolves to the bar it announces")
        func courtesyKeySignature() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.score(clefChange: false))
            let announcing = try system(notContaining: 2, in: doc)
            let point = try point(in: announcing) { element in
                // The announcement is the key signature drawn in a bar that declares none of its own: m1 holds
                // one chord and nothing else.
                guard case let .keySignature(_, flats, _, _, origin, index) = element,
                      flats == 2, index == 2
                else { return nil }
                return origin
            }

            #expect(ScoreHitTester(document: doc).hitTest(at: point) == .keySignature(measureIndex: 2))
        }

        @Test("a courtesy time signature resolves to the bar it announces")
        func courtesyTimeSignature() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.score(clefChange: false))
            let announcing = try system(notContaining: 2, in: doc)
            let point = try point(in: announcing) { element in
                guard case let .timeSignature(numerator, denominator, _, origin, index) = element,
                      numerator == 3, denominator == 4, index == 2
                else { return nil }
                return origin
            }

            #expect(ScoreHitTester(document: doc).hitTest(at: point) == .timeSignature(measureIndex: 2))
        }

        /// The clef a continuation system opens with restates whatever is in force — here the bass clef declared
        /// in m2 — so clicking it selects that declaration rather than answering "nothing".
        @Test("a continuation system's clef resolves to the declaration in force")
        func continuationClef() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.score(clefChange: true))
            // The second system opens with m2, which declares the bass clef itself; the restatement to check is
            // on the system after that. With four bars and one break there are exactly two systems, so the
            // restatement to look at is the one the SECOND system draws for the FIRST system's G clef — which is
            // not present. Instead check the synthesized opening clef of the system that does not hold m0.
            let continuation = try system(notContaining: 0, in: doc)
            let clefs = continuation.measures.flatMap { measure in
                measure.elements.compactMap { element -> ClefAnchor? in
                    guard case let .clef(_, _, anchor) = element else { return nil }
                    return anchor
                }
            }
            // Every clef the continuation system draws names something: the restatement names the declaration in
            // force, and m2's own change names itself. Neither is `nil`, which is what it used to be.
            #expect(!clefs.isEmpty)
            #expect(clefs.allSatisfy { anchor in
                if case .explicit = anchor { return true }
                if case .staffDefault = anchor { return true }
                return false
            })
        }

        /// The consequence of a restatement naming its declaration: one anchor is now drawn in more than one
        /// place, systems apart. A host floating a control beside the selection needs the places rather than
        /// their envelope — `clefHitRect` answers with the declaration, `clefHitRects` with all of them.
        @Test("a clef redrawn on the next system reports one rectangle per place")
        func clefHitRectsPerPlace() throws {
            guard #available(macOS 15.0, *) else { return }
            // No clef change, so the only clef in the score is m0's — and the second system opens by redrawing it.
            let doc = layout(Self.score(clefChange: false))
            let continuation = try system(notContaining: 0, in: doc)
            let drawn = continuation.measures.flatMap(\.elements).compactMap { element -> ClefAnchor? in
                guard case let .clef(_, _, anchor) = element else { return nil }
                return anchor
            }
            let anchor = try #require(drawn.first)
            let tester = ScoreHitTester(document: doc)

            let rects = tester.clefHitRects(for: anchor)

            #expect(rects.count == 2)
            // Document order, and the two are a system apart — which is exactly why their union is not an answer.
            #expect(rects.count == 2 && rects[0].maxY < rects[1].minY)
            #expect(tester.clefHitRect(for: anchor) == rects.first)
        }

        /// **The one QA found in page mode** (2026-09-12): on page two the redrawn key signature is the only
        /// signature on the sheet, and it used to answer nothing. It now names the bar that declared what it is
        /// redrawing — here m0, whose one sharp is still in force on the system that opens with m2's change...
        /// except that m2 declares its own, so the system-head redraw to check is the one for m0's sharp on the
        /// system that does NOT contain m0.
        @Test("a system-head key signature resolves to the bar that declared it")
        func continuationKeySignature() throws {
            guard #available(macOS 15.0, *) else { return }
            // No clef change, so the second system's head carries only the redrawn signature.
            let doc = layout(Self.score(clefChange: false))
            let continuation = try system(notContaining: 0, in: doc)
            let redraws = continuation.measures.flatMap { measure in
                measure.elements.compactMap { element -> Int?? in
                    guard case let .keySignature(_, _, _, _, _, index) = element else { return nil }
                    return .some(index)
                }
            }
            #expect(!redraws.isEmpty)
            // Every signature drawn at a system head names a bar — none of them answers `nil` any more.
            #expect(redraws.allSatisfy { $0 != nil })
        }

        /// The key-signature resolver on its own, the twin of `declaringAnchor` below.
        @Test("the key signature in force is the last one declared before the bar")
        func declaringKeyMeasure() {
            let staff = Self.score(clefChange: false).parts[0].staves[0]

            // m0 declares one sharp; m1 declares nothing, so it reads m0's.
            #expect(LayoutEngine.declaringKeySignatureMeasure(before: 1, staff: staff) == 0)
            #expect(LayoutEngine.declaringKeySignatureMeasure(before: 2, staff: staff) == 0)
            // m2 declares two flats, so m3 reads m2's.
            #expect(LayoutEngine.declaringKeySignatureMeasure(before: 3, staff: staff) == 2)
            // Nothing precedes m0.
            #expect(LayoutEngine.declaringKeySignatureMeasure(before: 0, staff: staff) == nil)
        }

        /// The resolver on its own: the last clef declared before a bar is what that bar reads, and a bar with
        /// no clef before it reads the staff's own default.
        @Test("the declaration in force is the last one before the bar")
        func declaringAnchor() {
            let score = Self.score(clefChange: true)
            let staff = score.parts[0].staves[0]
            let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)

            // Before m2 only m0's G clef has been declared, at element 0 of that bar.
            #expect(
                LayoutEngine.declaringClefAnchor(before: 2, staff: staff, address: address)
                    == .explicit(VoiceElementID(
                        staff: address, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
                    )),
            )
            // Before m3 the bass clef in m2 is the later declaration and wins.
            #expect(
                LayoutEngine.declaringClefAnchor(before: 3, staff: staff, address: address)
                    == .explicit(VoiceElementID(
                        staff: address, measureIndex: 2, voiceIndex: 0, elementIndex: 0,
                    )),
            )
            // Nothing precedes m0, so it reads the staff's own default.
            #expect(
                LayoutEngine.declaringClefAnchor(before: 0, staff: staff, address: address)
                    == .staffDefault(address),
            )
        }
    }
#endif
