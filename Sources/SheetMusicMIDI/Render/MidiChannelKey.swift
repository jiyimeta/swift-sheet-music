import Foundation

/// Identity of one rendered SMF channel.
///
/// MuseScore allocates channels per **(port, channel)** pair, not per
/// channel number: a score with mid-piece instrument changes routinely
/// spills onto `midiPort 1`, where channel 0 is a different destination
/// from port 0's channel 0. A port-blind identity makes those collide —
/// exactly the failure the driving fixture exhibits (22 channels across
/// 2 ports, port 1's channels 0-6 aliasing the part-level channels 0-4).
public struct MidiChannelKey: Sendable, Hashable {
    public let port: Int
    public let channel: Int

    public init(port: Int, channel: Int) {
        self.port = port
        self.channel = channel
    }
}

/// Collapse a rendered multi-port `MidiFile` onto a single-port channel
/// set for live synthesis.
///
/// Sibling of `MidiSynthPostProcess`: run this FIRST (so the post-process
/// sees live channel numbers), then `MidiSynthPostProcess.apply` with
/// `plan.managedChannels`. SwiftySynth, FluidSynth, the `SynthBackend`
/// protocol and track topology are all untouched.
public enum MidiChannelRemap {
    public static func apply(midi: inout MidiFile, plan: LiveChannelPlan) {
        for trackIdx in midi.tracks.indices {
            // Port is positional within a track: the last `portChange`
            // seen governs the events that follow it.
            var port = 0
            var out: [TimedMidiEvent] = []
            out.reserveCapacity(midi.tracks[trackIdx].events.count)
            for event in midi.tracks[trackIdx].events {
                if case let .meta(.portChange(newPort)) = event.event {
                    port = newPort
                    // A live synth has ONE port; the meta would only
                    // confuse a downstream sequencer.
                    continue
                }
                func live(_ channel: Int) -> Int {
                    plan.remap[MidiChannelKey(port: port, channel: channel)]
                        ?? channel
                }
                let remapped: MidiEvent
                switch event.event {
                case let .noteOn(channel, pitch, velocity):
                    remapped = .noteOn(
                        channel: live(channel), pitch: pitch, velocity: velocity,
                    )
                case let .noteOff(channel, pitch, velocity):
                    remapped = .noteOff(
                        channel: live(channel), pitch: pitch, velocity: velocity,
                    )
                case let .controlChange(channel, controller, value):
                    remapped = .controlChange(
                        channel: live(channel), controller: controller, value: value,
                    )
                case let .programChange(channel, program):
                    remapped = .programChange(
                        channel: live(channel), program: program,
                    )
                case let .pitchBend(channel, value):
                    remapped = .pitchBend(channel: live(channel), value: value)
                default:
                    remapped = event.event
                }
                out.append(TimedMidiEvent(tick: event.tick, event: remapped))
            }
            midi.tracks[trackIdx] = MidiTrack(events: out)
        }
    }
}
