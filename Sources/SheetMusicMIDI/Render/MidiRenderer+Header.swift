import Foundation
import SheetMusicCore

extension MidiRenderer {
    static func headerEvents(
        staff: Staff,
        part: Part,
        channels: [ChannelAssignment],
        port: Int,
        isFirstTrack: Bool,
        isTopOfPart: Bool,
    ) -> [TimedMidiEvent] {
        var events: [TimedMidiEvent] = []

        let trackName = part.trackName ?? part.instrument.longName ?? "Track"
        events.append(TimedMidiEvent(tick: 0, event: .meta(.trackName(trackName))))

        // TimeSig and Tempo go only on track 0 (matches MuseScore exportmidi.cpp).
        if isFirstTrack {
            let initialTimeSig = firstTimeSignature(in: staff) ?? TimeSignature(numerator: 4, denominator: 4)
            events.append(TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: initialTimeSig.numerator,
                denominator: initialTimeSig.denominator,
                clocksPerClick: 24,
                thirtySecondsPerQuarter: 8,
            ))))
        }

        let initialKey = firstKeySignature(in: staff) ?? KeySignature(concertKey: 0)
        events.append(TimedMidiEvent(tick: 0, event: .meta(.keySignature(
            sharpsFlats: initialKey.concertKey, isMinor: false,
        ))))

        if isFirstTrack {
            events.append(TimedMidiEvent(tick: 0, event: .meta(.tempo(
                microsecondsPerQuarter: defaultMicrosPerQuarter,
            ))))
        }

        // Per-channel-flavour CC headers + portChange. MuseScore loops over every
        // `<Channel>` of the part's instrument inside this track and emits a full
        // header block per flavour. The program / vol / pan / reverb / chorus
        // block is only on the top staff of the part; portChange is unconditional.
        for assignment in channels {
            let channel = assignment.channel
            if isTopOfPart {
                func cc(_ controller: Int, _ value: Int) {
                    let event = MidiEvent.controlChange(channel: channel, controller: controller, value: value)
                    events.append(TimedMidiEvent(tick: 0, event: event))
                }

                cc(121, 0)
                if channel != 9 {
                    cc(100, 0)
                    cc(101, 0)
                    cc(6, 12)
                    cc(100, 127)
                    cc(101, 127)
                }

                let flavour = assignment.flavour
                let programEvent = MidiEvent.programChange(channel: channel, program: flavour.program)
                events.append(TimedMidiEvent(tick: 0, event: programEvent))
                cc(7, flavour.volume)
                cc(10, flavour.pan)
                cc(91, flavour.reverb)
                cc(93, flavour.chorus)
            }

            if (0 ... 127).contains(port) {
                events.append(TimedMidiEvent(tick: 0, event: .meta(.portChange(port: port))))
            }
        }
        return events
    }

    /// Look only inside the first measure: only that measure's signature counts as
    /// the initial header value. A signature appearing later is a mid-piece change.
    static func firstTimeSignature(in staff: Staff) -> TimeSignature? {
        guard let firstMeasure = staff.measures.first else { return nil }
        for voice in firstMeasure.voices {
            for element in voice.elements {
                if case let .timeSignature(t) = element { return t }
            }
        }
        return nil
    }

    static func firstKeySignature(in staff: Staff) -> KeySignature? {
        guard let firstMeasure = staff.measures.first else { return nil }
        for voice in firstMeasure.voices {
            for element in voice.elements {
                if case let .keySignature(k) = element { return k }
            }
        }
        return nil
    }
}
