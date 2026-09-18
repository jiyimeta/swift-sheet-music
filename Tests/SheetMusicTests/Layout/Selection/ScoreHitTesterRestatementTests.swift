#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

/// The staff a single-staff fixture's clef, key and time signature glyphs are drawn on, which their identity
/// names.
private let signatureStaff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    /// Restatements — the glyphs a page draws again without declaring anything: a courtesy key or time signature
    /// at the trailing edge of a system, and the clef and key every continuation system opens with.
    ///
    /// **A restatement names the bar it is DRAWN in.** It declares nothing, but it is the only clef (or key) on
    /// that system's screen, so a click on it has to answer something — and the something MuseScore answers with
    /// is a change that starts there (`EditClef::undoChangeClef`'s `moveClef`, `KeySig::drop`). Naming the
    /// declaration it redraws, which these did until 2026-09-18, meant editing the clef on system four rewrote
    /// bar 0 and repainted every earlier system, and one identity tinted every restatement at once.
    ///
    /// The end-of-system COURTESY announcement is the exception and still names the bar it announces: that bar
    /// really does declare the change, and the announcement is it seen early.
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

        /// Three bars, one per system (a line break ends m0 and m1), where only m0 declares anything: G clef
        /// (unless `declaresClef` is false, leaving the staff's default to be synthesized), one sharp, 4/4. So
        /// m1 and m2 each open a system by restating both the clef and the key, and nothing else on those
        /// systems can be mistaken for one.
        private static func plainScore(declaresClef: Bool = true) -> Score {
            var opening: [VoiceElement] = declaresClef ? [.clef(Clef(concertClefType: "G"))] : []
            opening.append(contentsOf: [
                .keySignature(KeySignature(concertKey: 1)),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                chord(),
            ])
            let staff = Staff(measures: [
                Measure(voices: [Voice(elements: opening)], lineBreak: true),
                Measure(voices: [Voice(elements: [chord()])], lineBreak: true),
                Measure(voices: [Voice(elements: [chord()])]),
            ])
            return Score(division: 480, parts: [
                Part(id: "P0", instrument: Instrument(id: "voice"), staves: [staff]),
            ])
        }

        /// `plainScore`'s shape on a DRUM staff: three bars, one per system, with bar 0 declaring a key so that
        /// every continuation system has one to redraw. A drumset part is unpitched, which is the condition the
        /// identity gate reads — a real drum staff rarely carries a key, and the point here is that even when one
        /// is written, no glyph on it is addressable.
        private static func drumScore() -> Score {
            let staff = Staff(measures: [
                Measure(voices: [Voice(elements: [
                    .clef(Clef(concertClefType: "PERC")),
                    .keySignature(KeySignature(concertKey: 1)),
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    chord(),
                ])], lineBreak: true),
                Measure(voices: [Voice(elements: [chord()])], lineBreak: true),
                Measure(voices: [Voice(elements: [chord()])]),
            ])
            return Score(division: 480, parts: [
                Part(
                    id: "P0", instrument: Instrument(id: "drumset", longName: "Drumset", useDrumset: true),
                    staves: [staff],
                ),
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

        /// Every clef anchor `system` draws, in document order.
        private func clefAnchors(in system: LayoutSystem) -> [ClefAnchor] {
            system.measures.flatMap(\.elements).compactMap { element in
                guard case let .clef(_, _, anchor) = element else { return nil }
                return anchor
            }
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
                guard case let .keySignature(_, flats, _, _, origin, identity) = element,
                      flats == 2, identity?.measureIndexIfAddressedByBar == 2
                else { return nil }
                return origin
            }

            let hit = ScoreHitTester(document: doc).hitTest(at: point)
            #expect(hit == .keySignature(measureIndex: 2, staff: signatureStaff))
        }

        @Test("a courtesy time signature resolves to the bar it announces")
        func courtesyTimeSignature() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.score(clefChange: false))
            let announcing = try system(notContaining: 2, in: doc)
            let point = try point(in: announcing) { element in
                guard case let .timeSignature(numerator, denominator, _, origin, identity) = element,
                      numerator == 3, denominator == 4, identity?.measureIndexIfAddressedByBar == 2
                else { return nil }
                return origin
            }

            let hit = ScoreHitTester(document: doc).hitTest(at: point)
            #expect(hit == .timeSignature(measureIndex: 2, staff: signatureStaff))
        }

        /// The clef a continuation system opens with names the bar it opens — here m2, whose own voice declares
        /// no clef — rather than m0's G clef, which is what it is a redraw of.
        @Test("a continuation system's clef names the bar it opens")
        func continuationClef() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.score(clefChange: false))
            let continuation = try system(notContaining: 0, in: doc)

            #expect(clefAnchors(in: continuation) == [.restatement(staff: signatureStaff, measureIndex: 2)])
        }

        /// The first system's synthesized clef is NOT a restatement: nothing precedes m0, so that glyph IS the
        /// staff's opening clef and keeps `.staffDefault` — the identity `SetStaffDefaultClef` addresses.
        @Test("the first system's synthesized clef stays the staff default")
        func firstSystemClefIsStaffDefault() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.plainScore(declaresClef: false))
            let opening = try #require(doc.systems.first)

            #expect(clefAnchors(in: opening) == [.staffDefault(signatureStaff)])
        }

        /// **Each restatement is an identity of its own.** Three systems, three head clefs: m0's declaration and
        /// one restatement per continuation system, each naming the bar it opens. They used to be one anchor
        /// drawn three times, which is why selecting one tinted all of them.
        @Test("restatements on different systems have different identities")
        func restatementsAreDistinctPerSystem() {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.plainScore())
            #expect(doc.systems.count == 3)

            #expect(doc.systems.map { clefAnchors(in: $0) } == [
                [.explicit(VoiceElementID(
                    staff: signatureStaff, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
                ))],
                [.restatement(staff: signatureStaff, measureIndex: 1)],
                [.restatement(staff: signatureStaff, measureIndex: 2)],
            ])
        }

        /// **The one QA found in page mode** (2026-09-12): on page two the redrawn key signature is the only
        /// signature on the sheet, and it used to answer nothing. It names a bar now — its own, so an edit
        /// through it declares the key there rather than rewriting m0's.
        @Test("a system-head key signature names the bar it is drawn in")
        func continuationKeySignature() {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.plainScore())
            let identities = doc.systems.map { system in
                system.measures.flatMap(\.elements).compactMap { element -> ScoreElementID? in
                    guard case let .keySignature(_, _, _, _, _, identity) = element else { return nil }
                    return identity
                }
            }

            #expect(identities == [
                [.keySignature(measureIndex: 0, staff: signatureStaff)],
                [.keySignature(measureIndex: 1, staff: signatureStaff)],
                [.keySignature(measureIndex: 2, staff: signatureStaff)],
            ])
        }

        /// An unpitched staff's key signatures carry no identity at all — `SetKeySignature` writes only pitched
        /// staves, so an address on a drum staff would name a bar the command will not touch. The rule held for
        /// explicit declarations already; a system-head redraw has to follow it, and the gate that makes it do so
        /// is new. Both halves are checked here: the clef restatement on the same staff still carries one, so a
        /// failure cannot be read as "nothing is identified on a drum staff".
        @Test("a system-head key redraw on an unpitched staff names nothing")
        func continuationKeySignatureOnDrumStaff() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.drumScore())
            let continuation = try system(notContaining: 0, in: doc)
            let keys = continuation.measures.flatMap(\.elements).compactMap { element -> ScoreElementID?? in
                guard case let .keySignature(_, _, _, _, _, identity) = element else { return nil }
                return identity
            }

            #expect(!keys.isEmpty)
            #expect(keys.allSatisfy { $0 == nil })
            #expect(clefAnchors(in: continuation).contains { anchor in
                if case .restatement = anchor { return true }
                return false
            })
        }

        /// A click on a restated clef answers with that restatement, and the identity it answers with is drawn in
        /// exactly one place — the point of naming the bar rather than the declaration. `clefHitRects` used to
        /// return one rectangle per system for the same anchor.
        @Test("a click on a restated clef round-trips to its own single rectangle")
        func restatedClefHitRoundTrip() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.plainScore())
            let continuation = try system(notContaining: 0, in: doc)
            let sp = doc.metrics.sp
            let point = try point(in: continuation) { element in
                guard case let .clef(rawType, origin, _) = element else { return nil }
                // The hit box is centred on the glyph's reference line, which is not where it is drawn.
                return CGPoint(
                    x: origin.x, y: origin.y + ScoreHitTester.clefYOffset(rawType: rawType, sp: sp),
                )
            }
            let tester = ScoreHitTester(document: doc)
            let expected = ClefAnchor.restatement(staff: signatureStaff, measureIndex: 1)

            #expect(tester.hitTest(at: point) == .clef(expected))
            #expect(tester.clefHitRects(for: expected).count == 1)
            #expect(tester.clefHitRect(for: expected) == tester.clefHitRects(for: expected).first)
        }

        /// **The edit the identity exists for.** A host turning a click on system two's restatement into an edit
        /// sends `SetClef(before:)` at voice 0's first chord of that bar — MuseScore's `moveClef` — so the clef
        /// changes from there on and m0 keeps the one it declared.
        @Test("editing through a restated clef starts a clef at that bar, leaving bar 0 alone")
        func editingARestatementStartsAClefThere() {
            let session = ScoreEditSession(score: Self.plainScore())
            let head = VoiceElementID(staff: signatureStaff, measureIndex: 1, voiceIndex: 0, elementIndex: 0)

            #expect(session.apply(.setClef(before: head, clef: .bass)))

            #expect(Self.declaredClefs(in: session.score, measureIndex: 1) == ["F"])
            // m0 still declares its own G, and still reads it at its last element.
            #expect(Self.declaredClefs(in: session.score, measureIndex: 0) == ["G"])
            #expect(session.score.clefInForce(at: VoiceElementID(
                staff: signatureStaff, measureIndex: 0, voiceIndex: 0, elementIndex: 3,
            )) == .treble)
            // m2 declares no clef, so it reads the new one: the change runs from m1 onward.
            #expect(session.score.clefInForce(at: VoiceElementID(
                staff: signatureStaff, measureIndex: 2, voiceIndex: 0, elementIndex: 0,
            )) == .bass)
        }

        /// The key-signature half. The bar a restatement names declares no key, so `SetKeySignature` there ADDS
        /// one — and `RemoveKeySignature` on it finds nothing to take away. m0's declaration is left alone.
        @Test("editing through a restated key signature declares a key at that bar")
        func editingARestatedKeyDeclaresItThere() {
            let session = ScoreEditSession(score: Self.plainScore())

            #expect(!session.apply(.removeKeySignature(measureIndex: 1)))
            #expect(session.lastRefusal?.reason == .nothingToApply)
            #expect(session.apply(.setKeySignature(measureIndex: 1, concertKey: -2)))

            #expect(Self.declaredKey(in: session.score, measureIndex: 1) == -2)
            #expect(Self.declaredKey(in: session.score, measureIndex: 0) == 1)
            // m2 declares nothing of its own and inherits the new key: the change runs from m1 onward.
            #expect(Self.declaredKey(in: session.score, measureIndex: 2) == nil)
            #expect(session.score.activeKey(staff: signatureStaff, measureIndex: 0) == 1)
            #expect(session.score.activeKey(staff: signatureStaff, measureIndex: 2) == -2)
        }

        /// The raw clef types bar `measureIndex` declares in voice 0, in order.
        private static func declaredClefs(in score: Score, measureIndex: Int) -> [String] {
            score.parts[0].staves[0].measures[measureIndex].voices[0].elements.values.compactMap { element in
                guard case let .clef(clef) = element else { return nil }
                return clef.concertClefType
            }
        }

        /// The concert key bar `measureIndex` declares in voice 0, or `nil` when it declares none.
        private static func declaredKey(in score: Score, measureIndex: Int) -> Int? {
            for element in score.parts[0].staves[0].measures[measureIndex].voices[0].elements.values {
                if case let .keySignature(key) = element { return key.concertKey }
            }
            return nil
        }
    }
#endif
