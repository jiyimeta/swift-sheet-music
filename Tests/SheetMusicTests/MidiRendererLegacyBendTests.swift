@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Verifies legacy (`<Bend>`) playback: the note is struck once and its
/// pitch wheel follows the stored curve, per-segment, holding the last
/// point's pitch to the end and resetting at the release.
///
/// C++: `CompatMidiRender::collectBend`
/// (`engraving/compat/midi/compatmidirenderinternal.cpp:573`).
@Suite("MIDI legacy bends")
struct MidiRendererLegacyBendTests {
    private typealias Probe = GuitarBendMidiProbe

    private func bendNote(_ points: [LegacyBend.Point], play: Bool = true) -> Note {
        var note = Note(pitch: 62, tpc: 16)
        note.legacyBend = LegacyBend(points: points, play: play)
        return note
    }

    /// Plain bend {(0,0),(15,100),(60,100)}: one attack, wheel center at
    /// onset, +2 semitones (100 units / 50) by 25% of the span, held,
    /// reset at note-off.
    @Test func plainBendCurve() throws {
        let chord = Chord(duration: .quarter, notes: [bendNote([
            .init(time: 0, pitch: 0), .init(time: 15, pitch: 100),
            .init(time: 60, pitch: 100),
        ])])
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: [chord]))
        let track = try #require(file.tracks.first)
        #expect(Probe.noteOns(in: track).map(\.pitch) == [62])
        #expect(Probe.noteOffs(in: track).count == 1)
        let wheel = Probe.bends(in: track)
        let peak = Probe.wheel(semitones: 2)
        #expect(wheel.first?.value == MidiEvent.pitchBendCenter)
        #expect(wheel.map(\.value).max() == peak)
        // By 25% of the quarter (time 15/60 of 480 ticks = tick 120) the
        // ramp is complete; the closest sample at/after 120 is at peak.
        let atQuarterSpan = wheel.first { $0.tick >= 120 }?.value
        #expect(atQuarterSpan == peak)
        // Reset with the note-off (tick 479 = 0 + 480 − 1).
        #expect(wheel.last?.value == MidiEvent.pitchBendCenter)
        #expect(wheel.last?.tick == 479)
        #expect(Probe.noteOffs(in: track).first?.tick == 479)
    }

    /// Bend-release-bend: the wheel comes back to center mid-note and
    /// rises to peak again (fixture curve, one whole note).
    @Test func bendReleaseBendComesBackUp() throws {
        let chord = Chord(duration: .whole, notes: [bendNote([
            .init(time: 0, pitch: 0), .init(time: 10, pitch: 100),
            .init(time: 20, pitch: 100), .init(time: 30, pitch: 0),
            .init(time: 40, pitch: 0), .init(time: 50, pitch: 100),
            .init(time: 60, pitch: 100),
        ])])
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: [chord]))
        let track = try #require(file.tracks.first)
        let wheel = Probe.bends(in: track)
        let peak = Probe.wheel(semitones: 2)
        let firstPeak = try #require(wheel.firstIndex { $0.value == peak })
        let backToCenter = try #require(
            wheel[firstPeak...].firstIndex { $0.value == MidiEvent.pitchBendCenter },
        )
        // …and up again after the release (second bend leg).
        #expect(wheel[backToCenter...].contains { $0.value == peak })
    }

    /// Prebend {(0,100),(60,100)}: the wheel already carries +2
    /// semitones at the attack.
    @Test func prebendStartsHigh() throws {
        let chord = Chord(duration: .quarter, notes: [bendNote([
            .init(time: 0, pitch: 100), .init(time: 60, pitch: 100),
        ])])
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: [chord]))
        let track = try #require(file.tracks.first)
        let wheel = Probe.bends(in: track)
        #expect(wheel.first?.tick == 0)
        #expect(wheel.first?.value == Probe.wheel(semitones: 2))
    }

    /// `<play>0</play>` suppresses the curve entirely: plain note, no
    /// wheel traffic.
    @Test func playFlagSuppressesCurve() throws {
        let chord = Chord(duration: .quarter, notes: [bendNote(
            [.init(time: 0, pitch: 0), .init(time: 60, pitch: 100)],
            play: false,
        )])
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: [chord]))
        let track = try #require(file.tracks.first)
        #expect(Probe.noteOns(in: track).map(\.pitch) == [62])
        #expect(Probe.bends(in: track).isEmpty)
    }

    /// A degenerate decode (fewer than two points) has no curve to
    /// follow: the note plays plain rather than emitting a lone sample.
    @Test func singlePointBendPlaysPlain() throws {
        let chord = Chord(duration: .quarter, notes: [bendNote([
            .init(time: 0, pitch: 100),
        ])])
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: [chord]))
        let track = try #require(file.tracks.first)
        #expect(Probe.noteOns(in: track).map(\.pitch) == [62])
        #expect(Probe.bends(in: track).isEmpty)
    }

    /// Bend on a note tied to the next chord: the curve's time axis
    /// spans BOTH chords, the tail owns the note-off, the reset comes at
    /// the chain end.
    @Test func tiedBendSpansChain() throws {
        var head = bendNote([
            .init(time: 0, pitch: 0), .init(time: 15, pitch: 100),
            .init(time: 60, pitch: 100),
        ])
        head.tieForward = 1
        var tail = Note(pitch: 62, tpc: 16)
        tail.tieBack = 1
        let chords = [
            Chord(duration: .quarter, notes: [head]),
            Chord(duration: .quarter, notes: [tail]),
        ]
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: chords))
        let track = try #require(file.tracks.first)
        #expect(Probe.noteOns(in: track).count == 1)
        #expect(Probe.noteOffs(in: track).count == 1)
        let wheel = Probe.bends(in: track)
        // time 15/60 of the 960-tick chain = tick 240: ramp completes
        // inside the head chord but scaled to the CHAIN, not the chord.
        let peak = Probe.wheel(semitones: 2)
        let firstPeakTick = try #require(wheel.first { $0.value == peak }?.tick)
        #expect(firstPeakTick >= 200)
        // Reset lands at/after the chain end, not the head's off.
        let reset = try #require(wheel.last)
        #expect(reset.value == MidiEvent.pitchBendCenter)
        #expect(reset.tick >= 959)
    }

    /// A tie whose partner the walk cannot reach (no tied-back chord
    /// follows): the bend is refused and the note plays plain.
    @Test func unresolvableTiePlaysPlain() throws {
        var head = bendNote([
            .init(time: 0, pitch: 0), .init(time: 60, pitch: 100),
        ])
        head.tieForward = 1 // no partner chord follows
        let chord = Chord(duration: .quarter, notes: [head])
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: [chord]))
        let track = try #require(file.tracks.first)
        #expect(Probe.bends(in: track).isEmpty)
    }

    /// A note tied INTO carries no curve of its own: the key is already
    /// sounding, so the bend that matters is the head's.
    @Test func tiedIntoNoteCarriesNoCurve() throws {
        var head = Note(pitch: 62, tpc: 16)
        head.tieForward = 1
        var tail = bendNote([
            .init(time: 0, pitch: 0), .init(time: 60, pitch: 100),
        ])
        tail.tieBack = 1
        let chords = [
            Chord(duration: .quarter, notes: [head]),
            Chord(duration: .quarter, notes: [tail]),
        ]
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: chords))
        let track = try #require(file.tracks.first)
        #expect(Probe.bends(in: track).isEmpty)
        #expect(Probe.noteOns(in: track).count == 1)
        #expect(Probe.noteOffs(in: track).count == 1)
    }

    /// Where both encodings appear on one note the MS4 spanner wins
    /// (`Note.legacyBend`'s doc comment): the chain slot renders and the
    /// legacy curve is not emitted on top of it.
    @Test func guitarBendChainWinsOverLegacyBend() throws {
        var start = Probe.bendNote(pitch: 60)
        start.legacyBend = LegacyBend(points: [
            .init(time: 0, pitch: 0), .init(time: 60, pitch: 100),
        ])
        let end = Chord(
            duration: .quarter,
            notes: [Note(pitch: 62, tpc: 16, guitarBendBack: true)],
        )
        let chords = [Chord(duration: .quarter, notes: [start]), end]
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: chords))
        let track = try #require(file.tracks.first)
        // The chain strikes exactly one key and releases it once — the
        // legacy branch would have added a second on/off pair.
        #expect(Probe.noteOns(in: track).map(\.pitch) == [60])
        #expect(Probe.noteOffs(in: track).map(\.pitch) == [60])
        #expect(Probe.bends(in: track).last?.tick == 959)
    }
}
