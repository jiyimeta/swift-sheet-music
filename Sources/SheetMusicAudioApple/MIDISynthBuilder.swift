import AudioToolbox
import AVFoundation
import Foundation

/// Factory for `AVAudioUnitMIDIInstrument`s backed by Apple's
/// `kAudioUnitSubType_MIDISynth` ("AUMIDISynth"). Used in place of
/// `AVAudioUnitSampler` because AUSampler ignores RPN 0,0 (Pitch
/// Bend Sensitivity) — its bend range is hard-coded to ±2 semitones,
/// which truncates portamento glissandi that we render at ±12. The
/// MIDISynth AU honors the RPN that the renderer emits in each
/// track header.
///
/// API surface mirrors `AVAudioUnitSampler.loadSoundBankInstrument`
/// closely enough that call sites swap with minimal churn. Patch
/// selection differs in spirit though: AUSampler "pins" a single
/// (bank, program) and ignores subsequent program-change events;
/// MIDISynth responds to bank-select / program-change MIDI events at
/// runtime. Both behave the same in our pipeline because the rendered
/// SMF either matches the pinned program or doesn't emit a fresh
/// program change.
enum MIDISynthBuilder {
    /// Instantiate a fresh AUMIDISynth. The returned instrument has
    /// no SoundFont loaded yet — call `loadSoundFont(...)` before
    /// the audio engine starts (or accept the first-note load
    /// latency).
    static func make() -> AVAudioUnitMIDIInstrument {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: kAudioUnitSubType_MIDISynth,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0,
        )
        return AVAudioUnitMIDIInstrument(
            audioComponentDescription: description,
        )
    }

    /// Load a SoundFont (SF2 / DLS) into the instrument and pre-bind
    /// the given (bank, program) patch on `channel` so the first
    /// note isn't delayed by an on-thread patch load.
    ///
    /// `bankMSB` / `bankLSB` follow standard MIDI bank-select
    /// semantics (CC 0 / CC 32). Callers migrating from
    /// `AVAudioUnitSampler.loadSoundBankInstrument` must NOT pass
    /// AUSampler's `kAUSampler_DefaultMelodicBankMSB` (0x79) /
    /// `kAUSampler_DefaultPercussionBankMSB` (0x78): those are
    /// AUSampler magic values telling the sampler which side of a
    /// dual-purpose SF2 to use, not real MIDI bank numbers.
    /// MIDISynth resolves percussion via MIDI channel 9 (zero-indexed)
    /// at play time, not via the bank-MSB byte.
    static func loadSoundFont(
        into instrument: AVAudioUnitMIDIInstrument,
        url: URL,
        bankMSB: UInt8,
        bankLSB: UInt8,
        program: UInt8,
        channel: UInt8 = 0,
    ) throws {
        // `kMusicDeviceProperty_SoundBankURL` expects a CFURLRef-sized
        // buffer (= pointer to the CFURL). Going through
        // `Unmanaged.toOpaque()` keeps `&` off the managed CFURL itself,
        // which the compiler otherwise flags as "forming UnsafeRawPointer
        // to a variable containing an object reference". The CFURL value
        // stays alive via `cfURL` for the duration of the call; the AU
        // retains it internally on success.
        let cfURL = url as CFURL
        var opaque: UnsafeMutableRawPointer = Unmanaged
            .passUnretained(cfURL).toOpaque()
        let setURLStatus = AudioUnitSetProperty(
            instrument.audioUnit,
            AudioUnitPropertyID(kMusicDeviceProperty_SoundBankURL),
            AudioUnitScope(kAudioUnitScope_Global),
            0,
            &opaque,
            UInt32(MemoryLayout<UnsafeMutableRawPointer>.size),
        )
        guard setURLStatus == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(setURLStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "kMusicDeviceProperty_SoundBankURL failed (\(setURLStatus))",
                ],
            )
        }

        preloadPreset(
            into: instrument,
            bankMSB: bankMSB, bankLSB: bankLSB, program: program,
            onChannel: channel,
        )
    }

    /// Toggle `kAUMIDISynthProperty_EnablePreload` ON, send bank-select
    /// + program-change on `channel` via `MusicDeviceMIDIEvent`, then
    /// toggle preload OFF. Causes the AU to synchronously load the
    /// requested preset into its voice pool so the next noteOn on that
    /// channel doesn't trigger an async SF2 read on the render thread
    /// (which empirically silences the channel).
    ///
    /// Use this for *runtime* program switches on an AU whose SF2 is
    /// already loaded — it does NOT touch `kMusicDeviceProperty_SoundBankURL`.
    /// Re-setting that property would re-parse the SF2 and reset every
    /// channel's program back to the AU's default (GM piano on all
    /// channels), which is exactly the bug we hit in `.singleShared`
    /// when `loadSoundFont` was called per picker change.
    ///
    /// Critical: uses `MusicDeviceMIDIEvent` (C API, synchronous
    /// delivery) — NOT the high-level `sendController` /
    /// `sendProgramChange`, which queue events for the next render
    /// cycle and race against the `EnablePreload = 0` write. When the
    /// queued events finally fire, preload is already disabled, the AU
    /// silently skips the preset load, and the channel ends up silent
    /// on a full multi-preset SoundFont. Apple's TN2331 sample uses
    /// MusicDeviceMIDIEvent for this reason.
    static func preloadPreset(
        into instrument: AVAudioUnitMIDIInstrument,
        bankMSB: UInt8,
        bankLSB: UInt8,
        program: UInt8,
        onChannel channel: UInt8,
    ) {
        var enable: UInt32 = 1
        _ = AudioUnitSetProperty(
            instrument.audioUnit,
            AudioUnitPropertyID(kAUMIDISynthProperty_EnablePreload),
            AudioUnitScope(kAudioUnitScope_Global),
            0,
            &enable,
            UInt32(MemoryLayout<UInt32>.size),
        )
        let ccStatus = UInt32(0xB0) | UInt32(channel & 0x0F)
        let pcStatus = UInt32(0xC0) | UInt32(channel & 0x0F)
        _ = MusicDeviceMIDIEvent(
            instrument.audioUnit, ccStatus, 0, UInt32(bankMSB), 0,
        )
        _ = MusicDeviceMIDIEvent(
            instrument.audioUnit, ccStatus, 32, UInt32(bankLSB), 0,
        )
        _ = MusicDeviceMIDIEvent(
            instrument.audioUnit, pcStatus, UInt32(program), 0, 0,
        )
        enable = 0
        _ = AudioUnitSetProperty(
            instrument.audioUnit,
            AudioUnitPropertyID(kAUMIDISynthProperty_EnablePreload),
            AudioUnitScope(kAudioUnitScope_Global),
            0,
            &enable,
            UInt32(MemoryLayout<UInt32>.size),
        )
    }

    /// Pre-configure the AUMIDISynth's pitch-bend sensitivity on
    /// `channel` to `semitones` half-steps. Use this at engine setup
    /// time so the synth's channel state is correct BEFORE the
    /// sequencer starts emitting MIDI: a fresh AUMIDISynth defaults
    /// to GM's ±2 semitones, and the RPN-setup events the renderer
    /// places at tick 0 of each SMF track don't reliably get
    /// processed before pitch-bend events at later ticks on the
    /// very first play (subsequent plays inherit the previous
    /// channel state and work). Sending the RPN dance directly to
    /// the AU here sidesteps that race.
    ///
    /// MIDI spec: Pitch Bend Sensitivity = RPN 0,0. Sequence is
    /// CC 101=0, CC 100=0 (select RPN), CC 6=semitones (data entry
    /// MSB), CC 101=127, CC 100=127 (RPN null — deselect, so a
    /// later spurious data-entry doesn't clobber the value).
    ///
    /// Goes through `MusicDeviceMIDIEvent` rather than
    /// `AVAudioUnitMIDIInstrument.sendController`: the high-level
    /// `send*` calls appear to queue events for delivery during the
    /// next render cycle, which loses a race with the SMF's tick-0
    /// events on the very first play after engine.start(). The C
    /// API delivers immediately on the calling thread, so the
    /// channel state is settled before the sequencer fires.
    static func setPitchBendSensitivity(
        into instrument: AVAudioUnitMIDIInstrument,
        semitones: UInt8,
        onChannel channel: UInt8,
    ) {
        let audioUnit = instrument.audioUnit
        let ccStatus = UInt32(0xB0) | UInt32(channel & 0x0F)
        func send(_ controller: UInt8, _ value: UInt8) {
            _ = MusicDeviceMIDIEvent(
                audioUnit,
                ccStatus,
                UInt32(controller),
                UInt32(value),
                0,
            )
        }
        send(101, 0) // RPN MSB
        send(100, 0) // RPN LSB → RPN (0,0) = Pitch Bend Sensitivity
        send(6, semitones) // Data Entry MSB (semitones)
        send(38, 0) // Data Entry LSB (cents). AUMIDISynth ignores
        // the RPN update until BOTH data-entry bytes arrive — the
        // 14-bit value is `MSB << 7 | LSB`. Without this LSB,
        // sensitivity stays at the AU's ±2-semitone GM default,
        // which is exactly the symptom we were seeing on first play.
        send(101, 127) // RPN null (deselect, lock the value in)
        send(100, 127)
    }

    /// Send a MIDI Control Change to the AU directly via
    /// `MusicDeviceMIDIEvent`. Used by the playback engine to apply
    /// mixer state (CC 7 / CC 120) on a specific channel of a given
    /// instrument unit without going through the higher-level
    /// `sendController(...)` API — which queues for the next render
    /// cycle and is therefore racy against AVAudioSequencer's tick-0
    /// events on a freshly-built sequencer.
    static func sendControlChange(
        into instrument: AVAudioUnitMIDIInstrument,
        controller: UInt8,
        value: UInt8,
        onChannel channel: UInt8,
    ) {
        let status = UInt32(0xB0) | UInt32(channel & 0x0F)
        _ = MusicDeviceMIDIEvent(
            instrument.audioUnit,
            status,
            UInt32(controller),
            UInt32(value),
            0,
        )
    }
}
