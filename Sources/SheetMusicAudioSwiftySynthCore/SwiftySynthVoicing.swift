import SheetMusicMIDI
import SwiftySynth

/// The two synths a SwiftySynth host builds — the score's and the metronome's — and the dispatch both sequencers use.
///
/// One definition for every platform, so a SoundFont sounds the same on a Mac and on a Pixel: the Apple
/// `SwiftySynthBackend` and Android's `HostedSynth` both build through here.
public enum SwiftySynthVoicing: Sendable {
    /// The score: 256 voices with reverb and chorus.
    case score
    /// The click: eight dry voices. A click needs neither a deep pool nor the effects bus, and leaving both out keeps
    /// the second synth cheap on the render thread.
    case metronome

    public var maximumPolyphony: Int {
        switch self {
        case .score: 256
        case .metronome: 8
        }
    }

    public var enablesReverbAndChorus: Bool {
        switch self {
        case .score: true
        case .metronome: false
        }
    }

    /// A synthesizer over `soundFont` rendering at `sampleRate`, or nil when SwiftySynth refuses the settings.
    ///
    /// SF2 note-on modulators are enabled (swiftysynth 0.2.0+): fonts that voice a preset via velocity→attenuation or
    /// filter modulators (MuseScore_General's Acoustic Grand Piano among them) render at their intended level instead
    /// of near-silent.
    ///
    /// `masterVolume` is set to 1. SwiftySynth inherits MeltySynth's C# field initializer of 0.5 there, which is a
    /// porting artifact rather than a considered default — it costs a flat 6 dB against the host's own gain stage for
    /// no reason. The host owns level control, so the synth hands back unity and lets that stage decide. Measured: 0.5
    /// → 1.0 recovers exactly 6.02 dB on a single voice. This does not close the whole gap against Apple's old
    /// AUMIDISynth path, which measured ~20 dB louder — but that path peaked at +2.17 dBFS on one note, i.e. it was
    /// clipping and leaning on the master limiter, and matching it would mean reproducing distortion.
    public func makeSynthesizer(soundFont: SoundFont, sampleRate: Int) -> Synthesizer? {
        guard let settings = try? SynthesizerSettings(
            sampleRate: sampleRate,
            maximumPolyphony: maximumPolyphony,
            enableReverbAndChorus: enablesReverbAndChorus,
            enableModulators: true,
        ),
            let synth = try? Synthesizer(soundFont: soundFont, settings: settings)
        else { return nil }
        synth.masterVolume = 1.0
        return synth
    }

    /// A sequencer driving `synthesizer` through `sendTurningChokesIntoChokes`.
    public static func makeSequencer(driving synthesizer: Synthesizer) -> MidiFileSequencer {
        let sequencer = MidiFileSequencer(synthesizer: synthesizer)
        sequencer.onSend = sendTurningChokesIntoChokes
        return sequencer
    }

    /// The sequencer's dispatch: every message goes to the synthesizer as before, except the choke marker the playback
    /// render puts at the end of a choked tie chain (`ChokeMarker`), which chokes that key on that channel. Set once
    /// per sequencer and capturing nothing, so the render thread calls it without allocating. A seek's chase bypasses
    /// `onSend`, and the synthesizer ignores the undefined controller anyway, so a choke behind a seek point is never
    /// replayed.
    public static func sendTurningChokesIntoChokes(
        _ synth: Synthesizer, channel: Int, command: Int, data1: Int, data2: Int,
    ) {
        if command == 0xB0, data1 == ChokeMarker.controller {
            synth.choke(key: data2, on: channel)
        } else {
            synth.processMidiMessage(channel: channel, command: command, data1: data1, data2: data2)
        }
    }
}
