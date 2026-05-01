@testable import SheetMusicCore
import Testing

@Suite("PasteVoiceElements")
struct PasteVoiceElementsTests {
    private static let restID = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1)

    @Test("paste a same-total-duration sequence does a clean splice")
    func sameDurationSplice() throws {
        // 4× quarter rests in 4/4. Replace idx 1 (one quarter) with
        // [eighth chord, eighth chord] — 2 eighths == 1 quarter.
        var score = EditingFixtures.fourQuarterRests()
        let payload: [VoiceElement] = [
            .chord(Chord(
                duration: .eighth, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(
                duration: .eighth, notes: [Note(pitch: 62, tpc: 16)])),
        ]
        let cmd = PasteVoiceElements(
            at: Self.restID, elements: payload)
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        // [timeSig, eighth, eighth, rest(q), rest(q), rest(q)] — 6.
        #expect(voice.elements.count == 6)
        guard case .chord(let c1) = voice.elements[1],
              case .chord(let c2) = voice.elements[2] else {
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
                duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
        ]
        let cmd = PasteVoiceElements(
            at: Self.restID, elements: payload)
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        // [timeSig, c, c, c, rest(q)] — 5.
        #expect(voice.elements.count == 5)
        guard case .chord(let c0) = voice.elements[1],
              case .chord(let c1) = voice.elements[2],
              case .chord(let c2) = voice.elements[3],
              case .rest = voice.elements[4]
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
            .rest(Rest(duration: .half)),
            .rest(Rest(duration: .quarter)),
            .rest(Rest(duration: .quarter)),
        ]
        score.staves[0].measures[0].voices[0] = v
        let halfRestID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1)
        // Paste two eighth chords (= 1 quarter) onto the half rest:
        // 2-quarter target, 1-quarter payload → leftover = 1 quarter.
        let payload: [VoiceElement] = [
            .chord(Chord(
                duration: .eighth, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(
                duration: .eighth, notes: [Note(pitch: 62, tpc: 16)])),
        ]
        let cmd = PasteVoiceElements(
            at: halfRestID, elements: payload)
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        // [timeSig, eighth, eighth, rest(q leftover), rest(q), rest(q)]
        #expect(voice.elements.count == 6)
        guard case .rest(let leftover) = voice.elements[3] else {
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
                duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
        ]
        let cmd = PasteVoiceElements(
            at: Self.restID, elements: payload)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("refuses an empty payload")
    func refusesEmpty() {
        var score = EditingFixtures.fourQuarterRests()
        let cmd = PasteVoiceElements(
            at: Self.restID, elements: [])
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
            voiceIndex: 0, elementIndex: 4)
        let payload: [VoiceElement] = [
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
        ]
        let cmd = PasteVoiceElements(
            at: lastID, elements: payload)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
