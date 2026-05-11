import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct MidiImporterGlissandoTests {
    @Test func vibratoPitchBendIgnored() {
        // Ramp up to 9000, back to 0, down to 7000, back to 0 within
        // a held note. Not monotonic → no glissando.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
                TimedMidiEvent(tick: 60, event: .pitchBend(channel: 0, value: 9000)),
                TimedMidiEvent(tick: 120, event: .pitchBend(channel: 0, value: 8192)),
                TimedMidiEvent(tick: 180, event: .pitchBend(channel: 0, value: 7000)),
                TimedMidiEvent(tick: 240, event: .pitchBend(channel: 0, value: 8192)),
                TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
            ],
            carryIns: [], carryOuts: [],
        )
        let attachments = MidiImporter.detectGlissandos(
            measure: measure, division: 480,
        )
        #expect(attachments.isEmpty)
    }

    @Test func monotonicBendToMatchingNextPitchAttachesGlissando() {
        // 12-semitone bend range. To bend up 2 semitones, final
        // pitch-bend value = 8192 + (2 × 8192/12) = 8192 + 1365 = 9557.
        // Source pitch 60, monotonic ramp up, next note at pitch 62.
        let bendStep = 8192 / 12
        let target = 8192 + 2 * bendStep // 9557
        let measure = ImportMeasure(
            startTick: 0, endTick: 960, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 2, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
                TimedMidiEvent(tick: 100, event: .pitchBend(channel: 0, value: 8192 + bendStep / 4)),
                TimedMidiEvent(tick: 200, event: .pitchBend(channel: 0, value: 8192 + bendStep)),
                TimedMidiEvent(tick: 300, event: .pitchBend(channel: 0, value: 8192 + bendStep * 3 / 2)),
                TimedMidiEvent(tick: 400, event: .pitchBend(channel: 0, value: target)),
                TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
                TimedMidiEvent(tick: 480, event: .noteOn(channel: 0, pitch: 62, velocity: 80)),
                TimedMidiEvent(tick: 960, event: .noteOff(channel: 0, pitch: 62, velocity: 0)),
            ],
            carryIns: [], carryOuts: [],
        )
        let attachments = MidiImporter.detectGlissandos(
            measure: measure, division: 480,
        )
        #expect(attachments.count == 1)
        #expect(attachments.first?.pitch == 60)
        #expect(attachments.first?.glissando.style == .portamento)
    }

    @Test func mismatchedNextPitchIgnored() {
        let bendStep = 8192 / 12
        let target = 8192 + 2 * bendStep
        let measure = ImportMeasure(
            startTick: 0, endTick: 960, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 2, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
                TimedMidiEvent(tick: 200, event: .pitchBend(channel: 0, value: 8192 + bendStep)),
                TimedMidiEvent(tick: 400, event: .pitchBend(channel: 0, value: target)),
                TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
                // Next note pitches up 5 semitones, not 2 — mismatch.
                TimedMidiEvent(tick: 480, event: .noteOn(channel: 0, pitch: 65, velocity: 80)),
                TimedMidiEvent(tick: 960, event: .noteOff(channel: 0, pitch: 65, velocity: 0)),
            ],
            carryIns: [], carryOuts: [],
        )
        let attachments = MidiImporter.detectGlissandos(
            measure: measure, division: 480,
        )
        #expect(attachments.isEmpty)
    }
}
