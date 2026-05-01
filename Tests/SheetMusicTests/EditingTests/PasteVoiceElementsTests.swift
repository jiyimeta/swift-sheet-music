@testable import SheetMusicCore
import Testing

@Suite("PasteVoiceElements")
struct PasteVoiceElementsTests {
    private static let restID = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1
    )

    @Test("paste a same-total-duration sequence does a clean splice")
    func sameDurationSplice() throws {
        // 4× quarter rests in 4/4. Replace idx 1 (one quarter) with
        // [eighth chord, eighth chord] — 2 eighths == 1 quarter.
        var score = EditingFixtures.fourQuarterRests()
        let payload: [VoiceElement] = [
            .chord(Chord(
                duration: .eighth, notes: [Note(pitch: 60, tpc: 14)]
            )),
            .chord(Chord(
                duration: .eighth, notes: [Note(pitch: 62, tpc: 16)]
            )),
        ]
        let cmd = PasteVoiceElements(
            at: Self.restID, elements: payload
        )
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        // [timeSig, eighth, eighth, rest(q), rest(q), rest(q)] — 6.
        #expect(voice.elements.count == 6)
        guard case let .chord(c1) = voice.elements[1],
              case let .chord(c2) = voice.elements[2]
        else {
            Issue.record("expected two chords"); return
        }
        #expect(c1.notes.first?.pitch == 60)
        #expect(c2.notes.first?.pitch == 62)
    }

    @Test("paste a longer sequence consumes following elements")
    func longerSequence() throws {
        // 4× quarter rests. Replace idx 1 with three quarters of
        // chords. Two following rests get consumed (idx 2, idx 3).
        var score = EditingFixtures.fourQuarterRests()
        let payload: [VoiceElement] = [
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]
            )),
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 62, tpc: 16)]
            )),
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 64, tpc: 18)]
            )),
        ]
        let cmd = PasteVoiceElements(
            at: Self.restID, elements: payload
        )
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        // [timeSig, c, c, c, rest(q)] — 5.
        #expect(voice.elements.count == 5)
        guard case let .chord(c0) = voice.elements[1],
              case let .chord(c1) = voice.elements[2],
              case let .chord(c2) = voice.elements[3],
              case let .chord(r4) = voice.elements[4],
              r4.notes.isEmpty
        else { Issue.record("layout off"); return }
        #expect(c0.notes.first?.pitch == 60)
        #expect(c1.notes.first?.pitch == 62)
        #expect(c2.notes.first?.pitch == 64)
    }

    @Test("paste a shorter sequence fills leftover with rests")
    func shorterSequence() throws {
        // Shape voice as [timeSig, half-rest, q-rest, q-rest].
        var score = EditingFixtures.fourQuarterRests()
        var v = score.staves[0].measures[0].voices[0]
        v.elements = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .half),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ]
        score.staves[0].measures[0].voices[0] = v
        let halfRestID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1
        )
        // Paste two eighth chords (= 1 quarter) onto the half rest:
        // 2-quarter target, 1-quarter payload → leftover = 1 quarter.
        let payload: [VoiceElement] = [
            .chord(Chord(
                duration: .eighth, notes: [Note(pitch: 60, tpc: 14)]
            )),
            .chord(Chord(
                duration: .eighth, notes: [Note(pitch: 62, tpc: 16)]
            )),
        ]
        let cmd = PasteVoiceElements(
            at: halfRestID, elements: payload
        )
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        // [timeSig, eighth, eighth, rest(q leftover), rest(q), rest(q)]
        #expect(voice.elements.count == 6)
        guard case let .chord(leftover) = voice.elements[3], leftover.notes.isEmpty else {
            Issue.record("expected leftover rest at idx 3"); return
        }
        #expect(leftover.duration == .quarter)
    }

    @Test("inverse round-trips a multi-element paste")
    func inverseRestores() throws {
        var score = EditingFixtures.fourQuarterRests()
        let snapshot = score
        let payload: [VoiceElement] = [
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]
            )),
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 62, tpc: 16)]
            )),
        ]
        let cmd = PasteVoiceElements(
            at: Self.restID, elements: payload
        )
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("refuses an empty payload")
    func refusesEmpty() {
        var score = EditingFixtures.fourQuarterRests()
        let cmd = PasteVoiceElements(
            at: Self.restID, elements: []
        )
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }

    @Test("paste before a tuplet leaves it untouched (just shifts indices)")
    func tupletAfterPasteIsKept() throws {
        // [timeSig, rest(q), rest(q), <tuplet of 3 eighths>, rest(q)]
        // Paste a half-chord at idx 1 (rest q). Half = 2 quarters →
        // consumes idx 2 (rest q) but stops before the tuplet at
        // idx 3..5. Tuplet should survive with shifted indices.
        var score = EditingFixtures.fourQuarterRests()
        var v = score.staves[0].measures[0].voices[0]
        v.elements = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            // Triplet: 3 eighths in a quarter (3:2).
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 60, tpc: 14)]
            )),
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 62, tpc: 16)]
            )),
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 64, tpc: 18)]
            )),
            .rest(duration: .quarter),
        ]
        v.tuplets = [Tuplet(
            normalNotes: 2, actualNotes: 3,
            startIndex: 3, endIndex: 5
        )]
        score.staves[0].measures[0].voices[0] = v
        let restID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1
        )
        let halfChord = Chord(
            duration: .half, notes: [Note(pitch: 67, tpc: 15)]
        )
        let cmd = PasteVoiceElements(
            at: restID, elements: [.chord(halfChord)]
        )
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        // [timeSig, half-chord, <tuplet at 2..4>, rest q]
        #expect(voice.elements.count == 6)
        #expect(voice.tuplets.count == 1)
        #expect(voice.tuplets[0].startIndex == 2)
        #expect(voice.tuplets[0].endIndex == 4)
    }

    @Test("paste fully containing a tuplet drops it")
    func pasteFullyContainsTupletDropsIt() throws {
        // Same setup as above, but paste a whole-chord at idx 1.
        // Whole = 4 quarters → consumes idx 2 (rest q) + tuplet
        // (= 1 quarter total) + idx 6 (rest q) = full bar gap.
        // Tuplet fully contained in paste range → dropped.
        var score = EditingFixtures.fourQuarterRests()
        var v = score.staves[0].measures[0].voices[0]
        v.elements = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 60, tpc: 14)]
            )),
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 62, tpc: 16)]
            )),
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 64, tpc: 18)]
            )),
            .rest(duration: .quarter),
        ]
        v.tuplets = [Tuplet(
            normalNotes: 2, actualNotes: 3,
            startIndex: 3, endIndex: 5
        )]
        score.staves[0].measures[0].voices[0] = v
        let restID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1
        )
        let wholeChord = Chord(
            duration: .whole, notes: [Note(pitch: 67, tpc: 15)]
        )
        let cmd = PasteVoiceElements(
            at: restID, elements: [.chord(wholeChord)]
        )
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        #expect(voice.tuplets.isEmpty)
    }

    @Test("paste partially overlapping a tuplet refuses")
    func partialOverlapRefuses() {
        // Setup: [timeSig, rest(q), rest(q), <tuplet 3 eighths>, rest(q)]
        // Paste a dotted-half chord at idx 1. Dotted half = 1440
        // ticks = 3 quarters → consumes idx 2 (q rest) + only PART
        // of the tuplet → partial overlap → refuse.
        var score = EditingFixtures.fourQuarterRests()
        var v = score.staves[0].measures[0].voices[0]
        v.elements = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 60, tpc: 14)]
            )),
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 62, tpc: 16)]
            )),
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 64, tpc: 18)]
            )),
            .rest(duration: .quarter),
        ]
        v.tuplets = [Tuplet(
            normalNotes: 2, actualNotes: 3,
            startIndex: 3, endIndex: 5
        )]
        score.staves[0].measures[0].voices[0] = v
        let restID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1
        )
        // 3-quarters worth of payload — eats first quarter rest +
        // second quarter rest + part of the triplet.
        let payload: [VoiceElement] = [
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 67, tpc: 15)]
            )),
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 69, tpc: 17)]
            )),
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 71, tpc: 19)]
            )),
        ]
        let cmd = PasteVoiceElements(
            at: restID, elements: payload
        )
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }

    @Test("paste onto an element inside a tuplet refuses")
    func targetInsideTupletRefuses() {
        var score = EditingFixtures.fourQuarterRests()
        var v = score.staves[0].measures[0].voices[0]
        v.elements = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 60, tpc: 14)]
            )),
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 62, tpc: 16)]
            )),
            .chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 64, tpc: 18)]
            )),
            .rest(duration: .half),
            .rest(duration: .quarter),
        ]
        v.tuplets = [Tuplet(
            normalNotes: 2, actualNotes: 3,
            startIndex: 1, endIndex: 3
        )]
        score.staves[0].measures[0].voices[0] = v
        // Target idx 2 = middle of the triplet.
        let middleID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 2
        )
        let cmd = PasteVoiceElements(
            at: middleID,
            elements: [.chord(Chord(
                duration: .eighth,
                notes: [Note(pitch: 67, tpc: 15)]
            ))]
        )
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }

    @Test("refuses when payload won't fit in the measure")
    func refusesOverflow() {
        // Last quarter rest + payload of two quarter chords = 2
        // quarters worth, but only 1 quarter remains in the measure.
        var score = EditingFixtures.fourQuarterRests()
        let lastID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 4
        )
        let payload: [VoiceElement] = [
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]
            )),
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 62, tpc: 16)]
            )),
        ]
        let cmd = PasteVoiceElements(
            at: lastID, elements: payload
        )
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
