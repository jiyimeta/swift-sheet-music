import SheetMusicCore
import SheetMusicFoundation

extension MidiImporter {
    // MARK: - Lyric attachment

    /// Decode this track's SMF Lyric (0x05) meta events and attach the
    /// reconstructed `[Lyric]` to the voice-0 chord at each matching
    /// absolute onset tick. Runs before `injectMetaEvents` so element
    /// indices are still pure chords/rests; multi-voice lyrics are out
    /// of scope (voice 0 only). Drum tracks are skipped.
    static func attachLyrics(
        track: ImportTrack,
        measures: [ImportMeasure],
        into scoreMeasures: inout [Measure],
        division: Int,
    ) {
        guard !track.isDrums else { return }
        let lyricEvents: [LyricMidiCodec.LyricEvent] = track.events.compactMap { event in
            if case let .meta(.lyric(text)) = event.event {
                return LyricMidiCodec.LyricEvent(tick: event.tick, text: text)
            }
            return nil
        }
        guard !lyricEvents.isEmpty else { return }
        let lyricsByTick = LyricMidiCodec.decode(lyricEvents)
        guard !lyricsByTick.isEmpty else { return }

        for (index, measure) in measures.enumerated() where index < scoreMeasures.count {
            attachLyrics(
                lyricsByTick: lyricsByTick,
                measure: measure,
                into: &scoreMeasures[index],
                division: division,
            )
        }
    }

    private static func attachLyrics(
        lyricsByTick: [Int: [Lyric]],
        measure: ImportMeasure,
        into scoreMeasure: inout Measure,
        division: Int,
    ) {
        guard var voice = scoreMeasure.voices.first else { return }
        let measureFraction = Fraction(
            numerator: measure.timeSignature.numerator,
            denominator: measure.timeSignature.denominator,
        )
        var cursor = measure.startTick
        var changed = false
        for (elementIndex, element) in voice.elements.enumerated() {
            guard case let .chord(chord) = element else { continue }
            if !chord.notes.isEmpty, let lyrics = lyricsByTick[cursor] {
                var updated = chord
                updated.lyrics = lyrics
                voice.elements[elementIndex] = .chord(updated)
                changed = true
            }
            cursor += chord.duration
                .resolved(in: measureFraction)
                .ticks(division: division)
        }
        if changed { scoreMeasure.voices[0] = voice }
    }
}
