import Foundation
import SheetMusicMIDI
import SwiftySynth

/// A preset a synthesizer channel plays, keyed the way SwiftySynth resolves it: the channel's effective bank — its
/// bank select, plus 128 on the percussion channel — and its patch.
struct PlayedPreset: Hashable, Sendable {
    let bank: Int
    let patch: Int

    /// What a channel holding bank select `bank` and program `program` plays.
    init(channel: Int, bank: Int, program: Int) {
        self.bank = channel == Synthesizer.percussionChannel ? bank + 128 : bank
        patch = program
    }
}

/// Reading a score's instruments in before playback reaches them.
///
/// The score font's samples are read in place from its file (`SoundFont(url:)`), so a sample no voice has played yet
/// may not be in memory, and the first note of an instrument would read it from disk on the audio render thread — a
/// page fault the render deadline does not budget for. So every preset the loaded sequence sounds, and every program
/// the mixer sets, is read in on a utility thread first. Prefetching is only a hint: a preset it misses still plays,
/// it just pays for its first page faults on the render thread.
extension SwiftySynthBackend {
    /// Every preset a note in `midi` sounds on. Walks the tracks merged in tick order with each channel's bank select
    /// and program as they stand at each note-on (both start at 0), so a program a channel is switched to but never
    /// plays is left out, and so is the initial piano of a channel that sets its program before its first note. At
    /// one tick, bank selects and program changes count before note-ons.
    nonisolated static func playedPresets(in midi: SheetMusicMIDI.MidiFile) -> Set<PlayedPreset> {
        var events: [(tick: Int, isNoteOn: Bool, order: Int, event: MidiEvent)] = []
        for track in midi.tracks {
            for timed in track.events {
                let isNoteOn = if case .noteOn = timed.event { true } else { false }
                events.append((timed.tick, isNoteOn, events.count, timed.event))
            }
        }
        events.sort { lhs, rhs in
            (lhs.tick, lhs.isNoteOn ? 1 : 0, lhs.order) < (rhs.tick, rhs.isNoteOn ? 1 : 0, rhs.order)
        }
        var banks = [Int](repeating: 0, count: 16)
        var programs = [Int](repeating: 0, count: 16)
        var presets = Set<PlayedPreset>()
        for entry in events {
            switch entry.event {
            // Controller 0 is bank select.
            case let .controlChange(channel, 0, value) where banks.indices.contains(channel):
                banks[channel] = value
            case let .programChange(channel, program) where programs.indices.contains(channel):
                programs[channel] = program
            case let .noteOn(channel, _, velocity) where velocity > 0 && programs.indices.contains(channel):
                presets.insert(PlayedPreset(channel: channel, bank: banks[channel], program: programs[channel]))
            default:
                break
            }
        }
        return presets
    }

    /// Works out which presets `midi` sounds — off the main actor, since a long score is a lot of events — records
    /// them for the next score font, and reads them in.
    func prefetchPresets(of midi: SheetMusicMIDI.MidiFile) {
        sequencePresetGeneration += 1
        let generation = sequencePresetGeneration
        Task.detached(priority: .utility) { [weak self] in
            let presets = Self.playedPresets(in: midi)
            await self?.recordSequencePresets(presets, generation: generation)
        }
    }

    private func recordSequencePresets(_ presets: Set<PlayedPreset>, generation: Int) {
        guard generation == sequencePresetGeneration else { return }
        sequencePresets = presets
        prefetchInBackground(presets)
    }

    /// Reads `presets` of the score font in on a utility thread — off the main actor and off the render thread.
    /// Nothing to do before a font has loaded; `applyLoaded` calls this again with the sequence's presets when it does.
    func prefetchInBackground(_ presets: Set<PlayedPreset>) {
        guard let font = scoreSoundFont, !presets.isEmpty else { return }
        Task.detached(priority: .utility) {
            for preset in presets {
                font.font.prefetchSamples(bank: preset.bank, patch: preset.patch)
            }
        }
    }
}
