import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Regression guards for "音が継続" — hung notes after a portamento glissando.
/// A score that uses portamento followed by several normal chords must
/// terminate every pitch and reset the pitch wheel before the next chord.
@Suite struct PortamentoHungNoteTests {
    private static func makeScore(chords: [Chord]) -> Score {
        let instrument = Instrument(id: "test", articulations: [InstrumentArticulation()])
        let part = Part(id: "P1", instrument: instrument)
        let voice = Voice(elements: chords.map { .chord($0) })
        let staff = StaffContent(id: 1, measures: [Measure(voices: [voice])])
        return Score(division: 480, parts: [part], staves: [staff])
    }

    @Test func portamentoFollowedByMixedChords_releasesEveryPitch() throws {
        let chords: [Chord] = [
            Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14, glissando: Glissando(style: .portamento))]
            ),
            Chord(duration: .quarter, notes: [Note(pitch: 67, tpc: 15)]),
            Chord(duration: .half, notes: [Note(pitch: 70, tpc: 16)]),
            Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)]),
            Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])
        ]
        let file = try MidiRenderer.render(score: Self.makeScore(chords: chords))
        let track = try #require(file.tracks.first)

        let ons: [(tick: Int, pitch: Int)] = track.events.compactMap {
            if case let .noteOn(_, p, v) = $0.event, v > 0 { return ($0.tick, p) }
            return nil
        }
        let offs: [(tick: Int, pitch: Int)] = track.events.compactMap {
            if case let .noteOff(_, p, _) = $0.event { return ($0.tick, p) }
            if case let .noteOn(_, p, v) = $0.event, v == 0 { return ($0.tick, p) }
            return nil
        }
        // Every note-on must have a matching note-off at its own pitch.
        #expect(ons.count == offs.count, "ons=\(ons.count) offs=\(offs.count)")
        for on in ons {
            let firstOff = offs.first { $0.pitch == on.pitch && $0.tick >= on.tick }
            #expect(firstOff != nil, "no off for pitch \(on.pitch) on@\(on.tick)")
            // No pitch should outlast a whole note (1920 ticks at division=480).
            if let off = firstOff {
                #expect(off.tick - on.tick <= 1920, "pitch \(on.pitch) hung on=\(on.tick) off=\(off.tick)")
            }
        }
    }

    /// The pitch wheel must return to centre at or before the next chord
    /// starts so that subsequent notes don't inherit the bend.
    /// User-reported regression: previous chord ties pitch 68 forward into a
    /// dotted-quarter (tieBack+tieForward, no events of its own), which then
    /// ties into an eighth that carries a portamento glissando to pitch 71.
    /// Without tieBack-aware suppression in renderPortamento, the portamento
    /// would emit a duplicate note-on for pitch 68 — the synth then receives
    /// two note-ons but only one note-off, and pitch 68 hangs to end of song.
    @Test func tiedIntoPortamento_doesNotHangSourcePitch() throws {
        let chords: [Chord] = [
            // Predecessor: starts pitch 68 and ties forward.
            Chord(duration: .quarter, notes: [Note(pitch: 68, tpc: 22, tieForward: 1)]),
            // Middle of tie chain: receives + forwards the tie, no events.
            Chord(duration: .quarter, notes: [Note(pitch: 68, tpc: 22, tieForward: 1, tieBack: 1)]),
            // Glissando-bearing tied tail: tieBack + portamento → 71.
            Chord(
                duration: .eighth,
                notes: [Note(
                    pitch: 68, tpc: 22,
                    tieBack: 1,
                    glissando: Glissando(style: .portamento)
                )]
            ),
            // Glissando target.
            Chord(duration: .half, notes: [Note(pitch: 71, tpc: 19)]),
            // Continued music — these must not inherit a hung pitch 68.
            Chord(duration: .quarter, notes: [Note(pitch: 69, tpc: 17)]),
            Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])
        ]
        let file = try MidiRenderer.render(score: Self.makeScore(chords: chords))
        let track = try #require(file.tracks.first)

        let pitch68Ons = track.events.filter {
            if case let .noteOn(_, p, v) = $0.event, p == 68, v > 0 { return true }
            return false
        }
        let pitch68Offs = track.events.filter {
            if case let .noteOff(_, p, _) = $0.event, p == 68 { return true }
            if case let .noteOn(_, p, v) = $0.event, p == 68, v == 0 { return true }
            return false
        }
        // Pitch 68 must have exactly as many offs as ons (no hung note).
        #expect(pitch68Ons.count == pitch68Offs.count,
                "pitch 68 ons=\(pitch68Ons.count) offs=\(pitch68Offs.count) — hung note")
        // Pitch 68's last off must land at or before the portamento source's
        // chord ends (predecessor.tick=0 + .quarter*2 + .eighth = 1200 ticks).
        let last68Off = pitch68Offs.last
        let last68OffTick = last68Off.flatMap { ev -> Int? in
            if case .noteOff = ev.event { return ev.tick }
            if case .noteOn = ev.event { return ev.tick }
            return nil
        } ?? Int.max
        #expect(last68OffTick <= 1200, "pitch 68 release at \(last68OffTick) > 1200 — sustained past glissando")
    }

    /// User-reported regression: with peak pitch-bend and the centre-reset
    /// scheduled at the same tick, some synths reordered the simultaneous
    /// events and applied the reset BEFORE the peak — leaving the wheel
    /// stuck at peak for the remainder of the song. Peak must land strictly
    /// earlier than the reset so the reset is unambiguously the most-recent
    /// bend at the chord boundary.
    @Test func portamento_peakLandsStrictlyBeforeReset() throws {
        let chords: [Chord] = [
            Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18, tieForward: 1)]),
            Chord(
                duration: .eighth,
                notes: [Note(
                    pitch: 64, tpc: 18,
                    tieBack: 1,
                    glissando: Glissando(style: .portamento)
                )]
            ),
            Chord(duration: .half, notes: [Note(pitch: 68, tpc: 22)]),
            Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])
        ]
        let file = try MidiRenderer.render(score: Self.makeScore(chords: chords))
        let track = try #require(file.tracks.first)
        let bends: [(tick: Int, value: Int)] = track.events.compactMap {
            if case let .pitchBend(_, v) = $0.event { return ($0.tick, v) }
            return nil
        }
        // The very last pitch-bend in the entire track must be a centre reset.
        #expect(bends.last?.value == MidiEvent.pitchBendCenter,
                "last bend was \(bends.last?.value ?? -1), should be centre")
        // The peak (highest absolute deviation) must occur at a strictly
        // earlier tick than the reset that follows it.
        let resets = bends.filter { $0.value == MidiEvent.pitchBendCenter }
        let nonResets = bends.filter { $0.value != MidiEvent.pitchBendCenter }
        let peak = nonResets.max { abs($0.value - 8192) < abs($1.value - 8192) }
        let firstResetAfterPeak = resets.first { $0.tick > (peak?.tick ?? -1) }
        let peakTick = try #require(peak?.tick)
        let resetTick = try #require(firstResetAfterPeak?.tick)
        #expect(peakTick < resetTick,
                "peak@\(peakTick) must precede reset@\(resetTick)")
    }

    @Test func portamento_pitchWheelReturnsToCentreBeforeNextChord() throws {
        let chords: [Chord] = [
            Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14, glissando: Glissando(style: .portamento))]
            ),
            Chord(duration: .quarter, notes: [Note(pitch: 67, tpc: 15)])
        ]
        let file = try MidiRenderer.render(score: Self.makeScore(chords: chords))
        let track = try #require(file.tracks.first)

        // Find the next chord's first note-on tick.
        let secondChordOn = track.events.first(where: { ev in
            if case let .noteOn(_, p, v) = ev.event, p == 67, v > 0 { return true }
            return false
        })
        let nextChordTick = try #require(secondChordOn?.tick)
        // Find the most recent pitch-bend at or before that tick.
        let lastBendValue = track.events
            .filter { $0.tick <= nextChordTick }
            .compactMap { ev -> Int? in
                if case let .pitchBend(_, v) = ev.event { return v }
                return nil
            }
            .last
        #expect(lastBendValue == MidiEvent.pitchBendCenter,
                "wheel was \(lastBendValue ?? -1) at next chord's tick \(nextChordTick) — should be 8192")
    }
}
