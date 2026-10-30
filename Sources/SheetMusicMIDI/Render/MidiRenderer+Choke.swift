import SheetMusicCore

/// How a playback render asks the synthesizer to choke a note: a control change on the note's channel, with a
/// controller MIDI 1.0 leaves undefined and the key as its value, at the tick the note's tie chain releases.
///
/// A backend that understands it (`SwiftySynthBackend`) stops every voice on that channel and key fast; every other
/// synthesizer ignores an undefined controller, so the note plays as written there. Only `renderForPlayback` and the
/// audio-export render emit it — an SMF a user exports never carries a controller nobody else knows.
public enum ChokeMarker {
    /// CC 110, in the 102–119 range MIDI 1.0 leaves undefined.
    public static let controller = 110

    /// The keys a choke stops on a drum staff (`ChordArticulation.Kind.chokedCymbalKeys`).
    public static let cymbalKeys: Set<Int> = ChordArticulation.Kind.chokedCymbalKeys
}

extension MidiRenderer {
    /// The open tie chains of one voice walk that carry a choke, keyed by sounding key, and whether the walk emits
    /// the marker at all.
    ///
    /// The mark is chord-level and judged per tie chain: a choke on any note of a chain stops it at the end of the
    /// chain's last note, at the note-off the renderer already computes (so a staccato choke stops at the staccato's
    /// length). Voice-wide for the same reason as the tie chain's channel: a chain routinely crosses a bar line.
    struct ChokeChains {
        let isEmitted: Bool
        /// Whether the walk plays a drum kit (`Instrument.useDrumset`), judged on the instrument rather than the
        /// channel: a kit routed to another `<midiChannel>` is still a kit, and live playback moves it to channel 9.
        let isDrumset: Bool
        private var open: Set<Int> = []

        init(isEmitted: Bool, isDrumset: Bool) {
            self.isEmitted = isEmitted
            self.isDrumset = isDrumset
        }

        /// Whether `chord` carries the choke.
        static func marks(_ chord: Chord) -> Bool {
            chord.articulations.contains { $0.kind == .chokeCymbal }
        }

        /// Follows one note of a chain through the walk. A note that ties on records whether its chain is choked so
        /// far; the note that ends the chain answers the marker to append at `offTick` — on a drum kit only for a
        /// cymbal key, on any other staff for every key — or nil.
        mutating func release(
            key: Int, tiesBack: Bool, tiesForward: Bool, marked: Bool, channel: Int, offTick: Int,
        ) -> TimedMidiEvent? {
            let choked = marked || (tiesBack && open.contains(key))
            if tiesForward {
                if choked { open.insert(key) } else { open.remove(key) }
                return nil
            }
            open.remove(key)
            guard isEmitted, choked, !isDrumset || ChokeMarker.cymbalKeys.contains(key)
            else { return nil }
            return TimedMidiEvent(
                tick: offTick,
                event: .controlChange(channel: channel, controller: ChokeMarker.controller, value: key),
            )
        }

        /// A note that releases on its own curve (a bend, a slide) ends its chain unchoked.
        mutating func drop(key: Int) {
            open.remove(key)
        }
    }
}
