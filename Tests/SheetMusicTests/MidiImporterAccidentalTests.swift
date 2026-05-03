import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterAccidentalTests {
    private func nOn(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOn(channel: 0, pitch: pitch, velocity: 80))
    }

    private func nOff(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOff(channel: 0, pitch: pitch, velocity: 0))
    }

    @Test func tpcMatchesMuseScoreLineOfFifthsForCMajor() {
        // No key context (= C major). Naturals on the line of fifths:
        // F=13, C=14, G=15, D=16, A=17, E=18, B=19. Black keys default
        // to sharp spellings: C#=21, D#=23, F#=20, G#=22, A#=24.
        #expect(MidiImporter.tpc(forMidiPitch: 60) == 14) // C4
        #expect(MidiImporter.tpc(forMidiPitch: 62) == 16) // D4
        #expect(MidiImporter.tpc(forMidiPitch: 64) == 18) // E4
        #expect(MidiImporter.tpc(forMidiPitch: 65) == 13) // F4
        #expect(MidiImporter.tpc(forMidiPitch: 67) == 15) // G4
        #expect(MidiImporter.tpc(forMidiPitch: 69) == 17) // A4
        #expect(MidiImporter.tpc(forMidiPitch: 71) == 19) // B4
        #expect(MidiImporter.tpc(forMidiPitch: 61) == 21) // C#4
        #expect(MidiImporter.tpc(forMidiPitch: 66) == 20) // F#4
        #expect(MidiImporter.tpc(forMidiPitch: 48) == 14) // C3
        #expect(MidiImporter.tpc(forMidiPitch: 72) == 14) // C5
    }

    @Test func tpcUsesFlatSpellingsInFlatKeys() {
        // Bb major (concertKey = -2). Flat spellings.
        #expect(MidiImporter.tpc(forMidiPitch: 61, concertKey: -2) == 9) // Db
        #expect(MidiImporter.tpc(forMidiPitch: 63, concertKey: -2) == 11) // Eb
        #expect(MidiImporter.tpc(forMidiPitch: 66, concertKey: -2) == 8) // Gb
        #expect(MidiImporter.tpc(forMidiPitch: 68, concertKey: -2) == 10) // Ab
        #expect(MidiImporter.tpc(forMidiPitch: 70, concertKey: -2) == 12) // Bb
        #expect(MidiImporter.tpc(forMidiPitch: 60, concertKey: -2) == 14) // C
        #expect(MidiImporter.tpc(forMidiPitch: 65, concertKey: -2) == 13) // F
    }

    @Test func tpcUsesSharpSpellingsInSharpKeys() {
        #expect(MidiImporter.tpc(forMidiPitch: 61, concertKey: 2) == 21) // C#
        #expect(MidiImporter.tpc(forMidiPitch: 63, concertKey: 2) == 23) // D#
        #expect(MidiImporter.tpc(forMidiPitch: 66, concertKey: 2) == 20) // F#
        #expect(MidiImporter.tpc(forMidiPitch: 68, concertKey: 2) == 22) // G#
        #expect(MidiImporter.tpc(forMidiPitch: 70, concertKey: 2) == 24) // A#
    }

    @Test func tpcStaffPositionForFlatKeysMatchesNaturalLetter() {
        // Cross-check via the layout's tpc-to-letter mapping: each
        // black-key flat must place its notehead on the higher
        // diatonic letter (Db on D, Ab on A, etc.).
        func letter(_ tpc: Int) -> String {
            let row = ((tpc + 1) % 7 + 7) % 7
            return ["F", "C", "G", "D", "A", "E", "B"][row]
        }
        let key = -4
        #expect(letter(MidiImporter.tpc(forMidiPitch: 61, concertKey: key)) == "D") // Db
        #expect(letter(MidiImporter.tpc(forMidiPitch: 68, concertKey: key)) == "A") // Ab
        #expect(letter(MidiImporter.tpc(forMidiPitch: 70, concertKey: key)) == "B") // Bb
        #expect(letter(MidiImporter.tpc(forMidiPitch: 63, concertKey: key)) == "E") // Eb
        #expect(letter(MidiImporter.tpc(forMidiPitch: 66, concertKey: key)) == "G") // Gb
    }

    @Test func voicedNotesCarryCorrectTpcNotZero() {
        // Regression: pre-fix every imported note had tpc=0 → all
        // pitches displayed as C. After the fix each pitch class gets
        // its natural-or-sharp TPC.
        let measure = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                nOn(0, 60), nOff(480, 60), // C
                nOn(480, 64), nOff(960, 64), // E
                nOn(960, 67), nOff(1440, 67), // G
                nOn(1440, 71), nOff(1920, 71), // B
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        let tpcs = voice.elements.compactMap { e -> Int? in
            if case let .chord(c) = e, let first = c.notes.first { return first.tpc }
            return nil
        }
        #expect(tpcs == [14, 18, 15, 19]) // C, E, G, B
    }

    @Test func keySigAlterReturnsExpectedDirectionForFlatAndSharpKeys() {
        // C (letter 0): in 7-flat key (Cb major), gets a flat.
        #expect(MidiImporter.keySigAlter(letter: 0, concertKey: -7) == -1)
        // F (letter 3): in 1-sharp key (G major), gets a sharp.
        #expect(MidiImporter.keySigAlter(letter: 3, concertKey: 1) == 1)
        // A (letter 5): in 4-flat key (Ab major), gets a flat.
        #expect(MidiImporter.keySigAlter(letter: 5, concertKey: -4) == -1)
        // E (letter 2): in 4-flat key, also gets a flat (B/E/A/D).
        #expect(MidiImporter.keySigAlter(letter: 2, concertKey: -4) == -1)
        // C (letter 0): in 4-flat key, NOT altered.
        #expect(MidiImporter.keySigAlter(letter: 0, concertKey: -4) == 0)
    }

    @Test func aNaturalInFlatKeyGetsExplicitNaturalAccidental() {
        // 4-flat key (Ab major). The key sig flatts B/E/A/D. An A
        // natural (MIDI 69, TPC 17 = A natural) is chromatic against
        // the key, so it must carry an explicit natural sign.
        let measure = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                nOn(0, 69), nOff(480, 69), // A natural
                nOn(480, 67), nOff(960, 67), // G natural — in key, nil
                nOn(960, 70), nOff(1440, 70), // Bb — in key, nil
                nOn(1440, 71), nOff(1920, 71), // B natural — chromatic
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(
            quantized: q, measure: measure, division: 480,
            concertKey: -4
        )
        let pitchesAndAccs: [(pitch: Int, acc: Accidental?)] = voice.elements.compactMap { el in
            if case let .chord(c) = el, let n = c.notes.first {
                return (n.pitch, n.accidental)
            }
            return nil
        }
        #expect(pitchesAndAccs.map(\.pitch) == [69, 67, 70, 71])
        let accFor: (Int) -> Accidental? = { pitch in
            pitchesAndAccs.first { $0.pitch == pitch }?.acc
        }
        #expect(accFor(69) == .natural)
        #expect(accFor(67) == nil)
        #expect(accFor(70) == nil)
        #expect(accFor(71) == .natural)
    }

    @Test func drumTrackKeySigZeroDoesNotOverrideConductorKey() throws {
        // Reproduce a real DAW pattern: every track (including
        // drums) emits its own key-sig meta at tick 0. Drums always
        // get `sf=0` because percussion has no key. If the importer
        // collected events from every track, the drum track's
        // `(0, 0)` would override the conductor's `(0, -4)` because
        // it sorts last among same-tick events. Ensure the
        // conductor's key wins for non-drum staves.
        let track0 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Conductor"))),
            TimedMidiEvent(tick: 0, event: .meta(.keySignature(sharpsFlats: -4, isMinor: false))),
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8
            ))),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        // Track 1: piano on channel 0 — key sig duplicated.
        let track1 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Piano"))),
            TimedMidiEvent(tick: 0, event: .meta(.keySignature(sharpsFlats: -4, isMinor: false))),
            // Pitch 61 — should be Db (TPC 9) under -4 key.
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 61, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 0, pitch: 61, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        // Track 2: drums on channel 9 — DAWs write sf=0 here.
        let track2 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Drums"))),
            TimedMidiEvent(tick: 0, event: .meta(.keySignature(sharpsFlats: 0, isMinor: false))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 9, pitch: 36, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 9, pitch: 36, velocity: 0)),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track0, track1, track2])
        let bytes = try MidiWriter.write(file)
        let score = try MidiImporter.parse(bytes)

        guard let pi = score.parts.firstIndex(where: { $0.trackName == "Piano" }) else {
            Issue.record("expected piano part"); return
        }
        let piano = score.staves[pi]
        // First note's TPC must be 9 (Db), not 21 (C#) which would
        // happen if concertKey were 0 instead of -4.
        let firstTpc: Int? = {
            for v in piano.measures[0].voices {
                for el in v.elements {
                    if case let .chord(c) = el, let n = c.notes.first {
                        return n.tpc
                    }
                }
            }
            return nil
        }()
        #expect(firstTpc == 9)
    }

    @Test func midSongKeyChangeUpdatesTpcSpellings() throws {
        // Two-measure file: measure 0 in 4 flats (Ab major),
        // measure 1 modulates to 3 sharps (A major). The same MIDI
        // pitch class — black key 1 (C#/Db) — should spell as Db
        // (flat) in measure 0 and C# (sharp) in measure 1.
        let track0 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Conductor"))),
            TimedMidiEvent(tick: 0, event: .meta(.keySignature(sharpsFlats: -4, isMinor: false))),
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8
            ))),
            // Key change at bar 1 (tick 1920).
            TimedMidiEvent(tick: 1920, event: .meta(.keySignature(sharpsFlats: 3, isMinor: false))),
            TimedMidiEvent(tick: 3840, event: .endOfTrack),
        ])
        let track1 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Piano"))),
            // Measure 0 — flat-key context. Pitch 61 should be Db (TPC 9).
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 61, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 0, pitch: 61, velocity: 0)),
            // Measure 1 — sharp-key context. Pitch 61 should be C# (TPC 21).
            TimedMidiEvent(tick: 1920, event: .noteOn(channel: 0, pitch: 61, velocity: 80)),
            TimedMidiEvent(tick: 3840, event: .noteOff(channel: 0, pitch: 61, velocity: 0)),
            TimedMidiEvent(tick: 3840, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track0, track1])
        let bytes = try MidiWriter.write(file)
        let score = try MidiImporter.parse(bytes)

        guard let pi = score.parts.firstIndex(where: { $0.trackName == "Piano" }) else {
            Issue.record("expected piano part"); return
        }
        let piano = score.staves[pi]
        // Helper: TPC of the first note in a measure.
        func firstNoteTpc(in measureIndex: Int) -> Int? {
            for v in piano.measures[measureIndex].voices {
                for el in v.elements {
                    if case let .chord(c) = el, let n = c.notes.first {
                        return n.tpc
                    }
                }
            }
            return nil
        }
        // Db in flat key (tpc 9), C# in sharp key (tpc 21).
        #expect(firstNoteTpc(in: 0) == 9)
        #expect(firstNoteTpc(in: 1) == 21)
    }

    @Test func accidentalPersistsWithinMeasureAndResetsAtBar() {
        // Within a measure, a written accidental persists for the
        // same letter+octave. C-major key sig.
        let measure = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                nOn(0, 66), nOff(480, 66), // F#
                nOn(480, 66), nOff(960, 66), // F# again
                nOn(960, 65), nOff(1440, 65), // F natural — needs cancellation
                nOn(1440, 65), nOff(1920, 65), // F natural again — already cancelled
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(
            quantized: q, measure: measure, division: 480,
            concertKey: 0
        )
        let accs = voice.elements.compactMap { el -> Accidental?? in
            if case let .chord(c) = el, let n = c.notes.first {
                return n.accidental
            }
            return nil
        }
        #expect(accs.count == 4)
        #expect(accs[0] == .sharp) // first F#
        #expect(accs[1] == nil) // second F# (carried over)
        #expect(accs[2] == .natural) // F natural cancels
        #expect(accs[3] == nil) // already natural
    }
}
