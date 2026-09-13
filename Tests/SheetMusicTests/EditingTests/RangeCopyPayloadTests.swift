@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

@Suite("RangeCopyPayload")
struct RangeCopyPayloadTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    /// One bar, 4/4: `[timeSignature, tripletA, tripletB, tripletC, restQ, restQ, restQ]` — a standard eighth
    /// triplet (2 in the time of 3, each member `1/12` of a whole note = 160 ticks at division 480, summing to
    /// one quarter beat) followed by three plain quarter rests filling the remaining three beats.
    private static func tripletFixture() -> Score {
        var source = EditingFixtures.parityFixture()
        let tripletMember = Fraction(numerator: 1, denominator: 12)
        source.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[0] = Voice(
                    elements: [
                        .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                        .chord(Chord(duration: .fraction(tripletMember), notes: [Note(pitch: 60, tpc: 14)])),
                        .chord(Chord(duration: .fraction(tripletMember), notes: [Note(pitch: 62, tpc: 16)])),
                        .chord(Chord(duration: .fraction(tripletMember), notes: [Note(pitch: 64, tpc: 18)])),
                        .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
                    ],
                    tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)],
                )
            }
        }
        return source
    }

    /// Three 4/4 bars on one staff: bar 0 `[4/4, q60 q62 q64 q65]`, bar 1 `[q67 q69 q71 q72]`, bar 2 four
    /// quarter rests. The shape a mid-bar, cross-barline copy needs — beat 3 of bar 0 through beat 2 of bar 1 is
    /// four contiguous quarters that no single bar contains.
    static func threeBarsOfQuarters() -> Score {
        func chord(_ pitch: Int, _ tpc: Int) -> VoiceElement {
            .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
        }
        let staff = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                chord(60, 14), chord(62, 16), chord(64, 18), chord(65, 13),
            ])]),
            Measure(voices: [Voice(elements: [chord(67, 15), chord(69, 17), chord(71, 19), chord(72, 14)])]),
            Measure(voices: [Voice(elements: [
                .rest(duration: .quarter), .rest(duration: .quarter),
                .rest(duration: .quarter), .rest(duration: .quarter),
            ])]),
        ])
        return Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    /// Two 4/4 bars: bar 0 `[4/4, r r r r]`, and bar 1 — carrying NO time signature of its own, the shape every
    /// non-first bar has — `[triplet ×3 at 1/12, r r r]` under a 2-in-the-time-of-3 bracket. `tripletFixture()`
    /// puts its triplet in measure 0, which already declares a meter, so only this shape reaches
    /// `ensureLeadingTimeSignature` with a tuplet to lose.
    private static func tripletInSecondBarFixture() -> Score {
        let tripletMember = Fraction(numerator: 1, denominator: 12)
        func member(_ pitch: Int, _ tpc: Int) -> VoiceElement {
            .chord(Chord(duration: .fraction(tripletMember), notes: [Note(pitch: pitch, tpc: tpc)]))
        }
        let staff = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .rest(duration: .quarter), .rest(duration: .quarter),
                .rest(duration: .quarter), .rest(duration: .quarter),
            ])]),
            Measure(voices: [Voice(
                elements: [
                    member(60, 14), member(62, 16), member(64, 18),
                    .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
                ],
                tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2)],
            )]),
        ])
        return Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    @Test("inheriting a time signature does not cost the copied bar its tuplet")
    func inheritedTimeSignatureKeepsTuplets() throws {
        let source = Self.tripletInSecondBarFixture()
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 5)), in: source,
        ))
        let voice = payload.parts[0].staves[0].measures[0].voices[0]
        #expect(voice.tuplets.count == 1)
        let span = try #require(voice.tupletSpans.first)
        #expect(span.normalNotes == 2)
        #expect(span.actualNotes == 3)
        // The inherited time signature took index 0, so the bracket's literal endpoints have to have moved with
        // the members they name: the triplet stands at 1...3 now, not at 0...2.
        #expect(span.startIndex == 1)
        #expect(span.endIndex == 3)
    }

    @Test("inheriting a time signature does not cost the copied bar its element identifiers")
    func inheritedTimeSignatureKeepsElementIDs() throws {
        var source = Self.tripletInSecondBarFixture()
        var ids = EIDAllocator()
        source.assignMissingIDs(using: &ids)
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 5)), in: source,
        ))
        let copied = payload.parts[0].staves[0].measures[0].voices[0].elements
        let original = try #require(source[Self.flute]).measures[1].voices[0].elements
        // `Score.clipboardDocument(for:)` is public, so a host sees these: the synthesized time signature is the
        // one slot with no identity, and every copied slot carries the source's.
        #expect(copied.eid(at: 0) == .invalid)
        #expect((1 ..< copied.count).map { copied.eid(at: $0) } == original.indices.map { original.eid(at: $0) })
    }

    @Test("a copy that starts mid-bar carries no hole at the end of its first bar")
    func midBarCopyLeavesNoHole() throws {
        // Beat 3 of bar 0 through beat 2 of bar 1: four contiguous quarters, 64 65 67 69.
        let source = Self.threeBarsOfQuarters()
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 3), end: Self.slot(1, 1)), in: source,
        ))
        // The trim slides bar 0's survivors to the front of a bar that still claims its nominal length, so the
        // payload's own bar 1 starts a beat-and-a-half too late unless the trimmed bar says how long it now is.
        #expect(payload.parts[0].staves[0].measures[0].actualLength == Fraction(numerator: 1, denominator: 2))

        let resolved = try #require(RangeCopySource(payload: payload))
        #expect(resolved.lengthTicks == 1920)
        #expect(resolved.streams.count == 1)
        #expect(try #require(resolved.streams.first).elements.map(\.absoluteTick) == [0, 480, 960, 1440])
    }

    @Test("a one-bar range becomes a one-bar score carrying that bar's notes")
    func oneBar() throws {
        let source = EditingFixtures.parityFixture()
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)), in: source,
        ))
        #expect(payload.division == source.division)
        #expect(payload.parts.count == 1)
        let voice = payload.parts[0].staves[0].measures[0].voices[0]
        let pitches = voice.elements.compactMap { element -> Int? in
            guard case let .chord(chord) = element, let note = chord.notes.first else { return nil }
            return note.pitch
        }
        #expect(pitches == [60, 62])
    }

    @Test("a two-staff range carries both staves")
    func twoStaves() throws {
        let source = EditingFixtures.parityFixture()
        let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(
                start: Self.slot(0, 1),
                end: VoiceElementID(staff: cello, measureIndex: 0, voiceIndex: 0, elementIndex: 1),
            ),
            in: source,
        ))
        #expect(payload.parts.count == 2)
    }

    @Test("the payload survives an encode and parse round trip")
    func roundTrips() throws {
        let source = EditingFixtures.parityFixture()
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)), in: source,
        ))
        let data = try MSCXEncoder.encode(payload)
        let parsed = try MSCXParser.parse(data)
        #expect(parsed.parts.count == payload.parts.count)
        let original = payload.parts[0].staves[0].measures[0].voices[0].elements.count
        #expect(parsed.parts[0].staves[0].measures[0].voices[0].elements.count == original)
    }

    @Test("a range starting on a measure with no time signature of its own inherits the prevailing one")
    func insertsPrevailingTimeSignature() throws {
        // Measure 0 carries the fixture's leading time signature; measure 1 has none of its own — the shape a
        // real second measure has (`EditingFixtures.twoMeasuresOfQuarterRests()`'s own doc comment).
        let source = EditingFixtures.twoMeasuresOfQuarterRests()
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 3)), in: source,
        ))
        let elements = payload.parts[0].staves[0].measures[0].voices[0].elements
        let first = try #require(elements.first)
        guard case let .timeSignature(timeSignature) = first else {
            Issue.record("expected the payload's first measure to open with the inherited time signature")
            return
        }
        #expect(timeSignature == TimeSignature(numerator: 4, denominator: 4))
    }

    /// A crescendo hairpin reaching three quarters forward from wherever it is anchored.
    private static func hairpin() -> VoiceElement {
        .spanner(Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextFractionsOffset: Fraction(numerator: 3, denominator: 4),
            hairpin: Spanner.HairpinPayload(subtype: .crescendo),
        ))
    }

    private static func spannerCount(_ elements: IdentifiedArray<VoiceElement>) -> Int {
        elements.filter { if case .spanner = $0 { true } else { false } }.count
    }

    @Test("a location shift and a measure repeat in a boundary measure are excluded; a spanner in span is not")
    func excludesCursorAndBarStandInsAtBoundary() throws {
        // The two kinds a cut boundary really does invalidate. A `.locationShift` moves the voice's ONE cursor,
        // and the trim may have taken away the chords it was jogging past, so it would re-date everything after
        // it; a `.measureRepeat` stands for a whole bar's content, and a boundary measure is exactly the bar the
        // trim can partially remove. Neither can be restated from what survives. A `.spanner` is not that: its
        // only hazard is positional, and it is the hazard the chords already have.
        var source = EditingFixtures.parityFixture()
        source.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[0] = Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .locationShift(delta: Fraction(numerator: 0, denominator: 4)),
                    Self.hairpin(),
                    .measureRepeat(MeasureRepeat(numMeasures: 1, duration: .quarter)),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
                    .rest(duration: .quarter), .rest(duration: .quarter),
                ])
            }
        }
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 4), end: Self.slot(0, 7)), in: source,
        ))
        let elements = payload.parts[0].staves[0].measures[0].voices[0].elements
        let hasUnsafeKind = elements.contains { element in
            switch element {
            case .locationShift, .measureRepeat: true
            default: false
            }
        }
        #expect(!hasUnsafeKind)
        #expect(Self.spannerCount(elements) == 1)
        let pitches = elements.compactMap { element -> Int? in
            guard case let .chord(chord) = element, let note = chord.notes.first else { return nil }
            return note.pitch
        }
        #expect(pitches == [60, 62])
    }

    @Test("a line spanner inside a one-bar copy reaches the resolved payload")
    func carriesALineSpannerAcrossAOneBarCopy() throws {
        // Both of a one-bar copy's boundaries are that one bar, so "drop it at a boundary measure" dropped every
        // line spanner a one-bar ⌘C could have carried. `R` over the identical range keeps it.
        var source = EditingFixtures.parityFixture()
        source.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[0] = Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    Self.hairpin(),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 13)])),
                ])
            }
        }
        let range = VoiceElementRange(start: Self.slot(0, 2), end: Self.slot(0, 5))
        let payload = try #require(RangeCopyPayload.score(for: range, in: source))
        let pasted = try #require(RangeCopySource(payload: payload))
        let duplicatedSource = try RangeCopySource(range: range, in: source, operation: "DuplicateRange")
        let duplicated = try #require(duplicatedSource)
        let pastedSpanners = try #require(pasted.streams.first).spanners
        let duplicatedSpanners = try #require(duplicated.streams.first).spanners
        #expect(pastedSpanners.count == 1)
        #expect(pastedSpanners.count == duplicatedSpanners.count)
    }

    @Test("a spanner anchored before the copied span goes with the material it named")
    func dropsASpannerAnchoredOutsideTheSpan() throws {
        // The positional hazard, and the reason a `.spanner` is tested for its own tick rather than kept
        // unconditionally: the trim slides the boundary measure's survivors to the front, so a spanner anchored
        // ahead of the range would arrive at the payload's very first tick and claim material the range never
        // asked for.
        var source = EditingFixtures.parityFixture()
        source.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[0] = Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    Self.hairpin(),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 13)])),
                ])
            }
        }
        // Starts on beat 3, leaving the hairpin's anchor outside the span.
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 4), end: Self.slot(0, 5)), in: source,
        ))
        let elements = payload.parts[0].staves[0].measures[0].voices[0].elements
        #expect(Self.spannerCount(elements) == 0)
        let resolved = try #require(RangeCopySource(payload: payload))
        #expect(try #require(resolved.streams.first).spanners.isEmpty)
    }

    @Test("a bar with a triplet copied whole keeps the tuplet, its ratio and its member count")
    func keepsWholeTuplet() throws {
        let source = Self.tripletFixture()
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 6)), in: source,
        ))
        let voice = payload.parts[0].staves[0].measures[0].voices[0]
        #expect(voice.tuplets.count == 1)
        let tuplet = try #require(voice.tuplets.first)
        #expect(tuplet.normalNotes == 2)
        #expect(tuplet.actualNotes == 3)
        let span = try #require(voice.tupletSpans.first)
        #expect(span.endIndex - span.startIndex + 1 == 3)
    }

    @Test("a tuplet the range only partly covers loses its bracket but keeps its surviving members")
    func dropsPartlyCoveredTupletBracket() throws {
        // Starts on the triplet's SECOND member, cutting the first one out of the copied span.
        let source = Self.tripletFixture()
        let payload = try #require(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 2), end: Self.slot(0, 6)), in: source,
        ))
        let voice = payload.parts[0].staves[0].measures[0].voices[0]
        #expect(voice.tuplets.isEmpty)
        let pitches = voice.elements.compactMap { element -> Int? in
            guard case let .chord(chord) = element, let note = chord.notes.first else { return nil }
            return note.pitch
        }
        #expect(pitches == [62, 64])
    }

    @Test("a range that resolves to nothing yields nil")
    func unresolvable() {
        let source = EditingFixtures.parityFixture()
        #expect(RangeCopyPayload.score(
            for: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(9, 0)), in: source,
        ) == nil)
    }
}
