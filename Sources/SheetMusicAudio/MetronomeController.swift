import AVFoundation
import Foundation
import SheetMusicCore
import SheetMusicMIDI

/// Owns the metronome's `AVAudioUnitSampler` and the index of the
/// sequencer track scheduling its events. Mirrors MuseScore's
/// metronome track:
///
///   * Strong (downbeat) → MIDI note 76 (Hi Wood Block)
///   * Other beat → MIDI note 77 (Low Wood Block)
///
/// Hi/Low Wood Block are GM percussion notes 76 / 77 — the same
/// drum-kit slots MuseScore's `buildMetronomeEvent` writes into when
/// it emits E5 / F5 on the metronome track
/// (`src/engraving/playback/playbackeventsrenderer.cpp`). They are
/// loaded from the same SF2 the host already supplies via
/// `SoundfontResolver.defaultGMSoundfontURL` — there is no separate
/// metronome SoundFont in MuseScore either.
@MainActor
final class MetronomeController {
    private let engine: AVAudioEngine
    private var sampler: AVAudioUnitSampler?
    /// The sequencer track scheduling our note-ons. We hold a weak
    /// reference so the next `buildSequencer` rebuild doesn't keep
    /// the old sequencer alive; we track its index in `tracks` to
    /// resolve the live track on each toggle.
    private weak var track: AVMusicTrack?
    private var loadedSoundfontURL: URL?

    /// User-facing toggle. Defaults to `true` to match MuseScore
    /// (metronome is enabled out of the box; the user mutes it from
    /// the mixer). When flipped at runtime, the live track's mute
    /// state is updated so changes take effect mid-playback.
    var isEnabled = true {
        didSet { track?.isMuted = !isEnabled }
    }

    /// Linear gain. Mutates the live AU so a slider moved during
    /// playback is heard immediately.
    var volume: Float = 1.0 {
        didSet { sampler?.volume = volume }
    }

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    /// Idempotent: attaches a sampler to the audio engine the first
    /// time, then reloads its preset from `soundfontURL` whenever
    /// that URL changes between scores. Failure to load the GM bank
    /// is non-fatal — we leave the sampler attached so the audio
    /// graph stays intact and just click silently.
    func prepare(soundfontURL: URL?) {
        let sampler = sampler ?? {
            let s = AVAudioUnitSampler()
            engine.attach(s)
            engine.connect(s, to: engine.mainMixerNode, format: nil)
            s.volume = volume
            self.sampler = s
            return s
        }()
        guard let url = soundfontURL else {
            loadedSoundfontURL = nil
            return
        }
        if loadedSoundfontURL == url { return }
        do {
            try sampler.loadSoundBankInstrument(
                at: url,
                program: 0,
                bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB),
                bankLSB: 0,
            )
            loadedSoundfontURL = url
        } catch {
            loadedSoundfontURL = nil
        }
    }

    /// Build a one-track `MidiFile` patch that the engine appends to
    /// the rendered score. Each beat emits a NoteOn / NoteOff pair
    /// on MIDI channel 9 (GM percussion convention). The note-off
    /// lands a half-beat later so back-to-back ticks at fast tempi
    /// don't choke each other on samplers that respect note-off.
    func metronomeTrack(
        beats: [MetronomeBeat], division: Int,
    ) -> MidiTrack {
        var events: [TimedMidiEvent] = []
        events.reserveCapacity(beats.count * 2 + 1)
        let halfBeat = max(1, division / 4)
        for beat in beats {
            let pitch = beat.isDownbeat ? 76 : 77
            let velocity = beat.isDownbeat ? 100 : 80
            events.append(TimedMidiEvent(
                tick: beat.tick,
                event: .noteOn(
                    channel: 9, pitch: pitch, velocity: velocity,
                ),
            ))
            events.append(TimedMidiEvent(
                tick: beat.tick + halfBeat,
                event: .noteOff(
                    channel: 9, pitch: pitch, velocity: 0,
                ),
            ))
        }
        let lastTick = events.map(\.tick).max() ?? 0
        events.append(TimedMidiEvent(
            tick: lastTick + 1, event: .endOfTrack,
        ))
        return MidiTrack(events: events)
    }

    /// Hook the freshly built sequencer up: route the last track
    /// (= our metronome track, appended in MIDI byte order) to the
    /// metronome sampler and apply the current mute state.
    func attach(to sequencer: AVAudioSequencer) {
        guard let sampler, let last = sequencer.tracks.last else {
            track = nil
            return
        }
        last.destinationAudioUnit = sampler
        last.isMuted = !isEnabled
        track = last
    }

    func teardown() {
        if let sampler {
            engine.disconnectNodeOutput(sampler)
            engine.detach(sampler)
        }
        sampler = nil
        loadedSoundfontURL = nil
        track = nil
    }
}
