import SheetMusicCore
import SheetMusicFoundation

extension Note {
    /// How far this note sounds from its stored pitch, in cents: its accidental's `centOffset`, zero without one.
    var playbackCents: Double {
        accidental?.centOffset ?? 0
    }
}

/// Sounds the microtonal accidentals of one rendered track as pitch-wheel traffic.
///
/// A MIDI key is a semitone, so the cents a quarter-tone flat adds can only travel as a pitch bend — which is a
/// CHANNEL's state, not a note's. MuseScore renders it the same way: `CompatMidiRender`'s `playNote` adds a constant
/// pitch-wheel function over the note's span for `Accidental::subtype2centOffset`, summed with whatever bend, slide or
/// vibrato the channel carries. This pass is that sum, done after the emit so every path that strikes a note —
/// plain, grace, tremolo, glissando, either kind of bend — takes part without carrying wheel state of its own:
///
/// - **The base.** Each note-on whose note is microtonal (`TimedMidiEvent.tuningCents`) moves the channel's base to
///   its offset, and a plain note-on moves it back to zero. One wheel serves every sounding key, so notes of
///   different offsets that overlap on one channel share the last struck one's — a limit of MIDI 1.0 that
///   MuseScore's own MIDI rendering has too.
/// - **The effect.** A bend or slide's wheel events keep their shape and ride on the base, the way MuseScore sums
///   its wheel functions: a portamento from a quarter-flat starts a quarter-tone low and stays that far below.
/// - **The release.** When the channel falls silent the base returns to zero `releaseTicks` later, or at the next
///   note-on if that comes first — late enough that a note's release tail does not jump in pitch, early enough
///   that another staff sharing the channel is not left detuned through a rest.
///
/// Only a channel that strikes a microtonal note is touched, so a score without one renders exactly as before.
enum MicrotonalPitchWheel {
    /// - Parameters:
    ///   - events: one track's events, sorted by tick.
    ///   - releaseTicks: how long a silent channel keeps its base before it returns to zero.
    ///   - exemptChannels: channels that are never retuned (the GM drum channel).
    static func apply(_ events: [TimedMidiEvent], releaseTicks: Int, exemptChannels: Set<Int>) -> [TimedMidiEvent] {
        let tuned = tunedChannels(in: events, exempt: exemptChannels)
        guard !tuned.isEmpty else { return events.map(\.untuned) }
        var pass = Pass(tuned: tuned, releaseTicks: releaseTicks)
        for event in events {
            pass.process(event)
        }
        return pass.output
    }

    /// The `(port, channel)`s that strike at least one microtonal note.
    private static func tunedChannels(in events: [TimedMidiEvent], exempt: Set<Int>) -> Set<MidiChannelKey> {
        var port = 0
        var tuned: Set<MidiChannelKey> = []
        for event in events {
            switch event.event {
            case let .meta(.portChange(newPort)):
                port = newPort
            case let .noteOn(channel, _, velocity) where velocity > 0 && event.tuningCents != 0:
                if !exempt.contains(channel) { tuned.insert(MidiChannelKey(port: port, channel: channel)) }
            default:
                break
            }
        }
        return tuned
    }

    /// Wheel value for `effect` (a bend's own offset from center) riding on `cents` of base.
    static func wheel(effect: Int, cents: Double) -> Int {
        let base = MidiEvent.pitchBendValue(cents: cents) - MidiEvent.pitchBendCenter
        return max(0, min(16383, MidiEvent.pitchBendCenter + effect + base))
    }

    private struct Channel {
        /// Cents the wheel currently adds to every key on the channel.
        var base: Double = 0
        /// The last bend / slide value the emit wrote, as an offset from center.
        var effect = 0
        /// Sounding keys in strike order, with the cents each was struck for.
        var sounding: [(pitch: Int, cents: Double)] = []
        /// When the silent channel's base returns to zero, if it is waiting to.
        var resetTick: Int?
    }

    private struct Pass {
        let tuned: Set<MidiChannelKey>
        let releaseTicks: Int
        var channels: [MidiChannelKey: Channel] = [:]
        var port = 0
        var output: [TimedMidiEvent] = []

        init(tuned: Set<MidiChannelKey>, releaseTicks: Int) {
            self.tuned = tuned
            self.releaseTicks = releaseTicks
        }

        mutating func process(_ event: TimedMidiEvent) {
            let key = channelKey(of: event.event)
            // A reset waiting for a tick the stream has reached lands first — except one due at this very tick on
            // the channel this event strikes, which sets its own base. The end of the track flushes every waiting
            // one, at the latest at its own tick, so the wheel is left centred without the track growing longer.
            flushResets(
                through: event.tick, flushingAll: event.event == .endOfTrack,
                sparing: Self.strikes(event.event) ? key : nil,
            )
            if case let .meta(.portChange(newPort)) = event.event { port = newPort }
            guard let key, tuned.contains(key) else {
                output.append(event.untuned)
                return
            }
            var state = channels[key] ?? Channel()
            switch event.event {
            case let .noteOn(channel, pitch, velocity) where velocity > 0:
                state.resetTick = nil
                state.sounding.append((pitch, event.tuningCents))
                if state.base != event.tuningCents {
                    state.base = event.tuningCents
                    output.append(wheelEvent(at: event.tick, channel: channel, state))
                }
                output.append(event.untuned)
            case let .noteOn(channel, pitch, _), let .noteOff(channel, pitch, _):
                output.append(event.untuned)
                if let index = state.sounding.firstIndex(where: { $0.pitch == pitch }) {
                    state.sounding.remove(at: index)
                }
                if let latest = state.sounding.last {
                    // A key still sounds: the wheel goes back to what the most recent of them was struck for.
                    if latest.cents != state.base {
                        state.base = latest.cents
                        output.append(wheelEvent(at: event.tick, channel: channel, state))
                    }
                } else if state.base != 0 {
                    state.resetTick = event.tick + releaseTicks
                }
            case let .pitchBend(channel, value):
                state.effect = value - MidiEvent.pitchBendCenter
                output.append(wheelEvent(at: event.tick, channel: channel, state))
            default:
                output.append(event.untuned)
            }
            channels[key] = state
        }

        private mutating func flushResets(through tick: Int, flushingAll: Bool, sparing spared: MidiChannelKey?) {
            let due = channels.filter { key, state in
                guard let resetTick = state.resetTick, !(key == spared && resetTick == tick) else { return false }
                return flushingAll || resetTick <= tick
            }
            // Earliest first, so the stream stays sorted when two channels fall due together.
            for (key, var state) in due.sorted(by: { ($0.value.resetTick ?? 0) < ($1.value.resetTick ?? 0) }) {
                let resetTick = min(state.resetTick ?? tick, tick)
                state.resetTick = nil
                state.base = 0
                // The port meta is positional, so a reset for another port's channel steps over and back.
                let crossesPort = key.port != port
                if crossesPort { output.append(portChange(key.port, at: resetTick)) }
                output.append(wheelEvent(at: resetTick, channel: key.channel, state))
                if crossesPort { output.append(portChange(port, at: resetTick)) }
                channels[key] = state
            }
        }

        private static func strikes(_ event: MidiEvent) -> Bool {
            if case let .noteOn(_, _, velocity) = event { velocity > 0 } else { false }
        }

        private func portChange(_ port: Int, at tick: Int) -> TimedMidiEvent {
            TimedMidiEvent(tick: tick, event: .meta(.portChange(port: port)))
        }

        private func channelKey(of event: MidiEvent) -> MidiChannelKey? {
            switch event {
            case let .noteOn(channel, _, _), let .noteOff(channel, _, _), let .pitchBend(channel, _):
                MidiChannelKey(port: port, channel: channel)
            default:
                nil
            }
        }

        private func wheelEvent(at tick: Int, channel: Int, _ state: Channel) -> TimedMidiEvent {
            let value = MicrotonalPitchWheel.wheel(effect: state.effect, cents: state.base)
            return TimedMidiEvent(tick: tick, event: .pitchBend(channel: channel, value: value))
        }
    }
}

extension TimedMidiEvent {
    /// A note-on that carries `note`'s microtonal offset to `MicrotonalPitchWheel`.
    static func noteOn(tick: Int, channel: Int, pitch: Int, velocity: Int, cents: Double) -> TimedMidiEvent {
        TimedMidiEvent(
            tick: tick, event: .noteOn(channel: channel, pitch: pitch, velocity: velocity), tuningCents: cents,
        )
    }

    /// The event without its renderer-internal annotation.
    fileprivate var untuned: TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: event)
    }
}
