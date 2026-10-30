import SwiftySynth

/// The transport of an SMF attached to a `HostedSynth`, in the SMF's own ticks — the shape a FluidSynth player had:
/// play, stop where it is, seek to a tick, report the tick, scale the tempo.
///
/// Holds its synth strongly, so a host that releases the synth first and the sequence after never reaches freed
/// memory. Inert — every call a no-op, the tick 0 — once another sequence is attached in its place, it is detached, or
/// the synth is closed.
public final class HostedSequence: @unchecked Sendable {
    public let synth: HostedSynth
    let id: Int

    /// How far before the requested tick a seek parks, in ticks. `MidiFileSequencer.seek` chases — and drops — every
    /// note-on strictly before its target, and `SequenceTempoMap`'s integration of the tempo map and SwiftySynth's own
    /// differ by a few ULPs whose sign varies per note, so parking exactly on the tick would skip the note there about
    /// half the time. A quarter tick is far above that rounding and far below the one tick to any earlier onset, and
    /// `currentTick` rounds it back to the tick asked for. (The Apple backend parks half a tick early for the same
    /// reason; it pins its displayed position separately, which this transport has no room for.)
    static let parkTicks = 0.25

    init(synth: HostedSynth, id: Int) {
        self.synth = synth
        self.id = id
    }

    /// Runs from where it stands.
    public func play() {
        synth.withSequence(id, fallback: ()) { attached, _ in attached.isPlaying = true }
    }

    /// Holds the position, and cuts the synth's voices at once: the host stops its output right after, so a release
    /// tail would only sound under the next play — what the Apple backend's pause avoids the same way.
    public func stop() {
        synth.withSequence(id, fallback: ()) { attached, synthesizer in
            attached.isPlaying = false
            synthesizer.noteOffAll(immediate: true)
        }
    }

    /// Parks the transport at `tick` (a quarter tick early, see `parkTicks`); playing or not, it carries on from there.
    /// The synth is reset by the seek's chase, and the host's channel state is sent to it again.
    ///
    /// Unlike a FluidSynth player, which refused a seek before its first play and applied one only on its next render,
    /// this takes effect at once and `currentTick` reflects it immediately.
    public func seek(toTick tick: Int) {
        let synth = synth
        synth.withSequence(id, fallback: ()) { attached, _ in
            let seconds = max(0, attached.tempoMap.seconds(atTick: Double(tick) - Self.parkTicks))
            attached.sequencer.seek(to: .seconds(seconds))
            // In the same critical section, so no block renders between the reset and the state coming back.
            synth.replayHostStateHoldingLock()
        }
    }

    /// Where the transport stands, in the SMF's ticks, rounded to the nearest. 0 once inert.
    public var currentTick: Int {
        synth.withSequence(id, fallback: 0) { attached, _ in
            let components = attached.sequencer.position.components
            let seconds = Double(components.seconds) + Double(components.attoseconds) * 1e-18
            return Int(attached.tempoMap.tick(atSeconds: seconds).rounded())
        }
    }

    /// Scales the tempo: 1 is the SMF's own, 2 twice as fast. Clamped to 0.01 and up.
    public func setSpeed(_ speed: Double) {
        synth.withSequence(id, fallback: ()) { attached, _ in
            attached.sequencer.speed = max(0.01, speed.isFinite ? speed : 1)
        }
    }

    /// Lets go of the synth's transport; the synth keeps playing previews.
    public func detach() {
        synth.detach(id)
    }
}
