import AVFoundation
import Foundation

/// Wraps the `SoftClip` curve in a v3 Audio Unit so it can sit in the
/// master chain as an ordinary effect node.
///
/// Apple ships no stock effect that does plain, predictable saturation —
/// `AUPeakLimiter` reduces gain (which is what makes the master control
/// run backwards above unity) and `AUDistortion` is a multi-stage
/// character effect. So this is a minimal in-place effect of our own:
/// pull the upstream audio into the output buffers, shape each sample,
/// done.
final class SoftClipAudioUnit: AUAudioUnit {
    /// Our own component identity. Registered in-process only, which is all
    /// `AVAudioUnitEffect` needs to instantiate it.
    ///
    /// `sandboxSafe` is not decoration. A locally registered component that does
    /// not declare it is refused by the component manager inside an App Sandbox,
    /// and `AVAudioUnitEffect(audioComponentDescription:)` then throws an
    /// Objective-C exception (`com.apple.coreaudio.avfaudio`, error -3000) that
    /// Swift cannot catch — the host process dies. Since `PlaybackEngine.init`
    /// builds the master chain eagerly, that is a launch crash for any sandboxed
    /// app, not merely a playback failure. Measured on a 2×2 bench (sandbox
    /// entitlement × flag): the crash appears in exactly one cell, sandboxed with
    /// no flag. The claim the flag makes is true of this unit — it reads and
    /// writes its own buffers and touches nothing else.
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x736D_7363, // 'smsc'
        componentManufacturer: 0x536D_7473, // 'Smts'
        componentFlags: AudioComponentFlags.sandboxSafe.rawValue,
        componentFlagsMask: 0,
    )

    /// Registration is process-wide and must happen exactly once, so it
    /// hangs off a `let` the runtime initializes lazily and atomically.
    private static let registration: Void = {
        AUAudioUnit.registerSubclass(
            SoftClipAudioUnit.self,
            as: componentDescription,
            name: "SheetMusic Soft Clip",
            version: 1,
        )
    }()

    /// Instantiate the node, registering the subclass on first use.
    static func makeNode() -> AVAudioUnitEffect {
        _ = registration
        return AVAudioUnitEffect(audioComponentDescription: componentDescription)
    }

    /// Implicitly unwrapped because `AUAudioUnitBusArray` needs the
    /// `AUAudioUnit` that owns it, which does not exist until after
    /// `super.init`.
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    /// Bypass state, held behind a pointer so the render block can read
    /// it without capturing `self`. The base class's stored property is
    /// not visible to the render thread, and a host that sets
    /// `AVAudioUnitEffect.bypass` expects the effect to honor it — an
    /// unhonored bypass would strand the master stage permanently on.
    private let bypassed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = [],
    ) throws {
        // Rate and channel count are renegotiated by the engine when it
        // connects the node; this is only a starting point.
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 44100, channels: 2,
        ) else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(kAudioUnitErr_FormatNotSupported),
            )
        }
        let input = try AUAudioUnitBus(format: format)
        let output = try AUAudioUnitBus(format: format)
        input.maximumChannelCount = 8
        output.maximumChannelCount = 8
        bypassed.initialize(to: false)

        try super.init(componentDescription: componentDescription, options: options)

        inputBusArray = AUAudioUnitBusArray(
            audioUnit: self, busType: .input, busses: [input],
        )
        outputBusArray = AUAudioUnitBusArray(
            audioUnit: self, busType: .output, busses: [output],
        )
        maximumFramesToRender = 4096
    }

    deinit {
        bypassed.deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray {
        inputBusArray
    }

    override var outputBusses: AUAudioUnitBusArray {
        outputBusArray
    }

    override var shouldBypassEffect: Bool {
        get { bypassed.pointee }
        set { bypassed.pointee = newValue }
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        // Capture by value: the render block runs on the audio thread and
        // must not reach back into `self`.
        let knee = SoftClip.defaultKnee
        let bypassed = bypassed
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInput = pullInputBlock else {
                return kAudioUnitErr_NoConnection
            }
            // Process in place: pull upstream audio straight into the
            // output buffers, then shape them.
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInput(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }
            // Bypassed: the pull already left the untouched audio in the
            // output buffers, so there is nothing more to do.
            guard !bypassed.pointee else { return noErr }

            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                guard let samples = buffer.mData?
                    .assumingMemoryBound(to: Float.self)
                else { continue }
                for frame in 0 ..< Int(frameCount) {
                    samples[frame] = SoftClip.apply(samples[frame], knee: knee)
                }
            }
            return noErr
        }
    }
}
