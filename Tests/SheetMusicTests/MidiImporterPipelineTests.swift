import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct MidiImporterPipelineTests {
    /// Smoke test: a Format 1 SMF with one piano track + one drum
    /// track produces a Score with two Parts (one drumset).
    @Test func parsesTwoTrackFormat1WithDrumset() throws {
        // Build via MidiRenderer → MidiWriter to avoid hand-rolling SMF bytes.
        let pianoNote = Note(pitch: 60, tpc: 14)
        let pianoChord = Chord(duration: .quarter, notes: ChordNotes([pianoNote]))
        let pianoVoice = Voice(elements: [.chord(pianoChord)])
        let pianoMeasure = Measure(voices: [pianoVoice])
        let pianoStaff = Staff(measures: [pianoMeasure])
        let pianoPart = Part(
            id: "P1",
            instrument: Instrument(id: "piano", longName: "Piano"),
            staves: [pianoStaff],
        )
        let drumNote = Note(pitch: 36, tpc: 0, headType: "normal")
        let drumChord = Chord(duration: .quarter, notes: ChordNotes([drumNote]))
        let drumVoice = Voice(elements: [.chord(drumChord)])
        let drumMeasure = Measure(voices: [drumVoice])
        let drumStaff = Staff(measures: [drumMeasure])
        let drumPart = Part(
            id: "P2",
            instrument: Instrument(
                id: "drumset", longName: "Drumset", useDrumset: true,
            ),
            staves: [drumStaff],
        )
        let score = Score(
            division: 480,
            parts: [pianoPart, drumPart],
        )
        let smfBytes = try MidiWriter.write(MidiRenderer.render(score: score))
        let imported = try MidiImporter.parse(smfBytes)
        #expect(imported.parts.count >= 2)
        let hasDrumset = imported.parts.contains(where: \.instrument.useDrumset)
        #expect(hasDrumset)
        #expect(imported.totalStaffCount >= 2)
    }

    @Test func parsesEmptyFormat0PreservingDivision() throws {
        let bytes = Data([
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x04,
            0x00, 0xFF, 0x2F, 0x00,
        ])
        let imported = try MidiImporter.parse(bytes)
        #expect(imported.division == 480)
    }

    @Test func resolveSwingAsyncIsCalledWhenSet() async throws {
        // Build a swung-eighths SMF (front=160, back=320) over 16 beats.
        var events: [TimedMidiEvent] = []
        for b in 0 ..< 16 {
            let beatStart = b * 480
            events.append(TimedMidiEvent(
                tick: beatStart,
                event: .noteOn(channel: 0, pitch: 60, velocity: 80),
            ))
            events.append(TimedMidiEvent(
                tick: beatStart + 160,
                event: .noteOff(channel: 0, pitch: 60, velocity: 0),
            ))
            events.append(TimedMidiEvent(
                tick: beatStart + 160,
                event: .noteOn(channel: 0, pitch: 62, velocity: 80),
            ))
            events.append(TimedMidiEvent(
                tick: beatStart + 480,
                event: .noteOff(channel: 0, pitch: 62, velocity: 0),
            ))
        }
        let track = MidiTrack(
            events: events
                + [TimedMidiEvent(tick: 16 * 480, event: .endOfTrack)],
        )
        let file = MidiFile(division: 480, format: 0, tracks: [track])
        let bytes = try MidiWriter.write(file)

        actor Counter { var count = 0; func incr() {
            count += 1
        } }
        let counter = Counter()

        let opts = MidiImportOptions(
            resolveSwingAsync: { _ in
                await counter.incr()
                return .treatAsWritten
            },
        )
        _ = try await MidiImporter.parse(bytes, options: opts)
        let calls = await counter.count
        #expect(calls >= 1)
    }

    @Test func keySignatureAppliesToAllNonDrumStaves() throws {
        // Format 1 file: piano + bass + drums, with a key signature
        // (3 sharps = A major) and tempo on Track 0. Both non-drum
        // staves carry the key signature; the drum staff does not.
        // Tempo lives only on staff 1.
        let division = 480
        let track0 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Conductor"))),
            TimedMidiEvent(tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 500_000))),
            TimedMidiEvent(tick: 0, event: .meta(.keySignature(sharpsFlats: 3, isMinor: false))),
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8,
            ))),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let track1 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Piano"))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let track2 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Bass"))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 1, pitch: 36, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 1, pitch: 36, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let track3 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Drums"))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 9, pitch: 36, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 9, pitch: 36, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let file = MidiFile(division: division, format: 1, tracks: [track0, track1, track2, track3])
        let bytes = try MidiWriter.write(file)
        let score = try MidiImporter.parse(bytes)

        func keySigSharpsFlats(in staff: Staff) -> Int? {
            for measure in staff.measures {
                for v in measure.voices {
                    for el in v.elements {
                        if case let .keySignature(k) = el { return k.concertKey }
                    }
                }
            }
            return nil
        }
        // With the system-element refactor, tempo events live on
        // `Score.systemMeasures` and carry the originating staff as
        // `originalStaff` (set to the conductor track's staff
        // address — part 0, staff 0 in this fixture). Aggregate
        // which parts contribute tempo entries by walking the
        // score-level system measures.
        func partsWithTempo(in score: Score) -> [Int] {
            var indices: Set<Int> = []
            for systemMeasure in score.systemMeasures {
                for positioned in systemMeasure.elements {
                    if case .tempo = positioned.element,
                       let staff = positioned.originalStaff
                    {
                        indices.insert(staff.partIndex)
                    }
                }
            }
            return indices.sorted()
        }

        let pianoIdx = score.parts.firstIndex(where: { $0.trackName == "Piano" })
        let bassIdx = score.parts.firstIndex(where: { $0.trackName == "Bass" })
        let drumsIdx = score.parts.firstIndex(where: { $0.instrument.useDrumset })
        guard let pi = pianoIdx, let bi = bassIdx, let di = drumsIdx else {
            Issue.record("expected piano + bass + drums parts; got \(score.parts.map(\.trackName))")
            return
        }
        #expect(keySigSharpsFlats(in: score.parts[pi].staves[0]) == 3)
        #expect(keySigSharpsFlats(in: score.parts[bi].staves[0]) == 3)
        #expect(keySigSharpsFlats(in: score.parts[di].staves[0]) == nil)
        #expect(partsWithTempo(in: score) == [0])
    }

    @Test func tupletInFirstMeasureKeepsBracketAfterMetaInjection() throws {
        // Reproduce the user-reported issue: a triplet in the first
        // measure of staff 1 had its `Voice.tuplets` indices shifted
        // out of alignment when `injectMetaEvents` inserted tempo /
        // key sig / time sig at index 0 of the voice. Result: bracket
        // missing on that single tuplet (subsequent measures fine
        // because no meta is injected after measure 0).
        //
        // Build: 4/4 measure with quarter at 0/480/960, then a
        // (3,2) eighth-triplet over the last beat 1440..<1920.
        let track0 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 500_000))),
            TimedMidiEvent(tick: 0, event: .meta(.keySignature(sharpsFlats: 0, isMinor: false))),
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8,
            ))),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let track1 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Piano"))),
            // First three quarters.
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
            TimedMidiEvent(tick: 480, event: .noteOn(channel: 0, pitch: 62, velocity: 80)),
            TimedMidiEvent(tick: 960, event: .noteOff(channel: 0, pitch: 62, velocity: 0)),
            TimedMidiEvent(tick: 960, event: .noteOn(channel: 0, pitch: 64, velocity: 80)),
            TimedMidiEvent(tick: 1440, event: .noteOff(channel: 0, pitch: 64, velocity: 0)),
            // Triplet over the fourth beat: 3 evenly-spaced eighths.
            TimedMidiEvent(tick: 1440, event: .noteOn(channel: 0, pitch: 65, velocity: 80)),
            TimedMidiEvent(tick: 1600, event: .noteOff(channel: 0, pitch: 65, velocity: 0)),
            TimedMidiEvent(tick: 1600, event: .noteOn(channel: 0, pitch: 67, velocity: 80)),
            TimedMidiEvent(tick: 1760, event: .noteOff(channel: 0, pitch: 67, velocity: 0)),
            TimedMidiEvent(tick: 1760, event: .noteOn(channel: 0, pitch: 69, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 0, pitch: 69, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track0, track1])
        let bytes = try MidiWriter.write(file)
        let score = try MidiImporter.parse(bytes)

        guard let pi = score.parts.firstIndex(where: { $0.trackName == "Piano" }) else {
            Issue.record("expected piano part"); return
        }
        let firstMeasure = score.parts[pi].staves[0].measures[0]
        guard let voice = firstMeasure.voices.first else {
            Issue.record("expected voice 0"); return
        }
        // The tuplet must still point at three actual chord
        // elements (not at the meta `.tempo` / `.keySignature` /
        // `.timeSignature` we just inserted at the front).
        #expect(voice.tuplets.count == 1)
        guard let tuplet = voice.tuplets.first else { return }
        for i in tuplet.startIndex ... tuplet.endIndex {
            guard i < voice.elements.count else {
                Issue.record("tuplet index \(i) out of bounds"); return
            }
            if case .chord = voice.elements[i] {
                continue
            }
            Issue.record("tuplet index \(i) points at non-chord: \(voice.elements[i])")
        }
    }

    @Test func flatKeySignatureChoosesFlatTpcSpellings() throws {
        // Bb major (concertKey = -2). Pitch 70 (Bb) and pitch 63
        // (Eb) should appear with flat TPCs (10 and 11), not the
        // sharp enharmonics (24 and 23).
        let track0 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Conductor"))),
            TimedMidiEvent(tick: 0, event: .meta(.keySignature(sharpsFlats: -2, isMinor: false))),
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8,
            ))),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let track1 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Piano"))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 70, velocity: 80)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 70, velocity: 0)),
            TimedMidiEvent(tick: 480, event: .noteOn(channel: 0, pitch: 63, velocity: 80)),
            TimedMidiEvent(tick: 960, event: .noteOff(channel: 0, pitch: 63, velocity: 0)),
            TimedMidiEvent(tick: 960, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track0, track1])
        let bytes = try MidiWriter.write(file)
        let score = try MidiImporter.parse(bytes)

        let pianoIdx = score.parts.firstIndex(where: { $0.trackName == "Piano" })
        guard let pi = pianoIdx else {
            Issue.record("expected piano part")
            return
        }
        let allTpcs: [Int] = score.parts[pi].staves[0].measures.flatMap { measure in
            measure.voices.flatMap { v in
                v.elements.flatMap { e -> [Int] in
                    if case let .chord(c) = e { return c.notes.map(\.tpc) }
                    return []
                }
            }
        }
        // Bb (12) and Eb (11), not A# (24) and D# (23).
        #expect(allTpcs.contains(12))
        #expect(allTpcs.contains(11))
        #expect(!allTpcs.contains(24))
        #expect(!allTpcs.contains(23))
    }
}
