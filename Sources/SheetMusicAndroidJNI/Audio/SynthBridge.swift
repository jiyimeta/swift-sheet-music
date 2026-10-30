import Dispatch
import Foundation
import SheetMusicAudioSwiftySynthCore
import SwiftySynth

// The SwiftySynth playback the Kotlin audio module drives (`SwiftySynthDriver`, `PlayerDriver`): a `HostedSynth` per
// role and a `HostedSequence` per loaded SMF, handed to Kotlin as opaque handles.
//
// Control calls go through swift-java below — primitives in, primitives out, called from the engine's own threads. The
// render call does not: it is `SynthRenderJNI.swift`'s hand-written JNI function, which renders straight into the
// Kotlin arrays.

/// Handles, and the work behind the entry points that is not JNI glue.
///
/// **A handle is a retained object's address**, not a key in a table: the render looks its synth up every output block,
/// and a `HandleTable` lookup is a `DispatchQueue.sync` there. The Kotlin drivers make every call under their own lock
/// and stop using a handle once they release it, as they did with FluidSynth's pointers. A sequence handle retains its
/// synth, so a sequence released after its synth still points at live memory.
enum SynthBridge {
    static func retain(_ object: AnyObject) -> Int64 {
        Int64(Int(bitPattern: Unmanaged.passRetained(object).toOpaque()))
    }

    static func object<T: AnyObject>(_: T.Type, _ handle: Int64) -> T? {
        guard handle != 0, let pointer = UnsafeRawPointer(bitPattern: Int(handle)) else { return nil }
        return Unmanaged<T>.fromOpaque(pointer).takeUnretainedValue()
    }

    static func release<T: AnyObject>(_: T.Type, _ handle: Int64) {
        guard handle != 0, let pointer = UnsafeRawPointer(bitPattern: Int(handle)) else { return }
        Unmanaged<T>.fromOpaque(pointer).release()
    }

    static func synth(_ handle: Int64) -> HostedSynth? {
        object(HostedSynth.self, handle)
    }

    static func sequence(_ handle: Int64) -> HostedSequence? {
        object(HostedSequence.self, handle)
    }

    /// The parsed font at `path`, through `SoundFontCache` so the score and metronome synths share one mapping of the
    /// same file. Blocks the calling thread for the parse — Kotlin calls it from its IO dispatcher, never from a Swift
    /// cooperative thread, so waiting on the cache's task cannot starve the pool it runs on.
    static func soundFont(atPath path: String) -> SoundFont? {
        let box = LoadedFontBox()
        let done = DispatchSemaphore(value: 0)
        let url = URL(fileURLWithPath: path)
        Task.detached(priority: .userInitiated) {
            box.loaded = await SoundFontCache.shared.soundFont(at: url)
            done.signal()
        }
        done.wait()
        return box.loaded?.font
    }

    /// `HostedSynth.render` by handle, for a host test. Kotlin renders through `SynthRenderJNI.swift`.
    static func render(
        handle: Int64, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
    ) -> Int {
        guard let synth = synth(handle), frames > 0 else { return 0 }
        synth.render(left: left, right: right, frames: frames)
        return frames
    }
}

/// Carries the cache's answer out of the detached task; read only after the semaphore says it was written.
private final class LoadedFontBox: @unchecked Sendable {
    var loaded: SoundFontCache.Loaded?
}

// MARK: - swift-java entry points: synth

/// A synth rendering at `sampleRate` — `voicing` 0 for the score's (256 voices, reverb and chorus), 1 for the
/// metronome's (8 dry voices) — silent until a SoundFont loads. 0 for a sample rate SwiftySynth refuses.
public func nativeSynthCreate(sampleRate: Int32, voicing: Int32) -> Int64 {
    guard let synth = HostedSynth(sampleRate: Int(sampleRate), voicing: voicing == 1 ? .metronome : .score) else {
        return 0
    }
    return SynthBridge.retain(synth)
}

/// Closes the synth (it renders silence from now on) and drops Kotlin's reference. The handle must not be used again.
public func nativeSynthRelease(handle: Int64) {
    SynthBridge.synth(handle)?.close()
    SynthBridge.release(HostedSynth.self, handle)
}

/// Loads the SF2 file at `path` (read in place, memory-mapped). 0 on success, -1 when the file is missing, does not
/// parse, or the handle is unknown.
public func nativeSynthLoadSoundFont(handle: Int64, path: String) -> Int32 {
    guard let synth = SynthBridge.synth(handle), let font = SynthBridge.soundFont(atPath: path) else { return -1 }
    return synth.loadSoundFont(font) ? 0 : -1
}

public func nativeSynthProgramSelect(handle: Int64, channel: Int32, bank: Int32, program: Int32) {
    SynthBridge.synth(handle)?.programSelect(channel: Int(channel), bank: Int(bank), program: Int(program))
}

public func nativeSynthControlChange(handle: Int64, channel: Int32, controller: Int32, value: Int32) {
    SynthBridge.synth(handle)?.controlChange(channel: Int(channel), controller: Int(controller), value: Int(value))
}

/// The value the host last set for `controller` on `channel`, else a reset channel's; -1 for an unknown handle.
public func nativeSynthControllerValue(handle: Int64, channel: Int32, controller: Int32) -> Int32 {
    guard let synth = SynthBridge.synth(handle) else { return -1 }
    return Int32(synth.controllerValue(channel: Int(channel), controller: Int(controller)))
}

public func nativeSynthSetGain(handle: Int64, gain: Double) {
    SynthBridge.synth(handle)?.setGain(Float(gain))
}

public func nativeSynthNoteOn(handle: Int64, channel: Int32, key: Int32, velocity: Int32) {
    SynthBridge.synth(handle)?.noteOn(channel: Int(channel), key: Int(key), velocity: Int(velocity))
}

public func nativeSynthNoteOff(handle: Int64, channel: Int32, key: Int32) {
    SynthBridge.synth(handle)?.noteOff(channel: Int(channel), key: Int(key))
}

public func nativeSynthAllNotesOff(handle: Int64, channel: Int32) {
    SynthBridge.synth(handle)?.allNotesOff(channel: Int(channel))
}

// MARK: - swift-java entry points: sequence

/// Attaches the SMF in `smf` to the synth behind `synthHandle`, parked at its start, replacing any sequence attached
/// before. 0 when the bytes are not an SMF or the synth handle is unknown.
public func nativeSequenceCreate(synthHandle: Int64, smf: Data) -> Int64 {
    guard let synth = SynthBridge.synth(synthHandle), let sequence = synth.attachSequence(smf: smf) else { return 0 }
    return SynthBridge.retain(sequence)
}

/// Detaches the sequence from its synth and drops Kotlin's reference. The handle must not be used again.
public func nativeSequenceRelease(handle: Int64) {
    SynthBridge.sequence(handle)?.detach()
    SynthBridge.release(HostedSequence.self, handle)
}

public func nativeSequencePlay(handle: Int64) {
    SynthBridge.sequence(handle)?.play()
}

public func nativeSequenceStop(handle: Int64) {
    SynthBridge.sequence(handle)?.stop()
}

public func nativeSequenceSeek(handle: Int64, tick: Int64) {
    SynthBridge.sequence(handle)?.seek(toTick: Int(clamping: tick))
}

/// The transport's position in the SMF's ticks; 0 for an unknown or replaced sequence.
public func nativeSequenceCurrentTick(handle: Int64) -> Int64 {
    Int64(SynthBridge.sequence(handle)?.currentTick ?? 0)
}

public func nativeSequenceSetSpeed(handle: Int64, speed: Double) {
    SynthBridge.sequence(handle)?.setSpeed(speed)
}
