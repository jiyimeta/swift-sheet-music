@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Unit tests for the pure lyric <-> SMF-0x05 conversion at the heart
/// of MIDI lyric round-trip. Covers the four pieces of information a
/// `Lyric` carries — text, syllabic, verse, melisma (`ticks`) — and the
/// conventions that pack them into standard Lyric meta events:
///   - syllabic  -> trailing "-" on begin/middle syllables
///   - verse     -> one event per verse at the chord tick, ordered by
///                  verse, lower verses filled with empty sentinels so
///                  ordinal position == verse number
///   - melisma   -> "_" continuation events at the covered chord ticks
struct MidiLyricCodecTests {
    private typealias Anchor = LyricMidiCodec.Anchor
    private typealias Event = LyricMidiCodec.LyricEvent

    private func lyric(
        _ text: String,
        _ syllabic: Syllabic = .single,
        ticks: Int = 0,
        verse: Int = 0,
    ) -> Lyric {
        Lyric(text: text, syllabic: syllabic, ticks: ticks, verse: verse)
    }

    // MARK: - encode

    @Test func encodesSingleStandaloneSyllable() {
        let events = LyricMidiCodec.encode([Anchor(tick: 0, lyrics: [lyric("star")])])
        #expect(events == [Event(tick: 0, text: "star")])
    }

    @Test func encodesHyphenatedWordWithTrailingHyphen() {
        let events = LyricMidiCodec.encode([
            Anchor(tick: 0, lyrics: [lyric("Twin", .begin)]),
            Anchor(tick: 480, lyrics: [lyric("kle", .end)]),
        ])
        #expect(events == [
            Event(tick: 0, text: "Twin-"),
            Event(tick: 480, text: "kle"),
        ])
    }

    @Test func encodesMiddleSyllableWithTrailingHyphen() {
        let events = LyricMidiCodec.encode([
            Anchor(tick: 0, lyrics: [lyric("ha", .begin)]),
            Anchor(tick: 240, lyrics: [lyric("le", .middle)]),
            Anchor(tick: 480, lyrics: [lyric("lu", .end)]),
        ])
        #expect(events == [
            Event(tick: 0, text: "ha-"),
            Event(tick: 240, text: "le-"),
            Event(tick: 480, text: "lu"),
        ])
    }

    @Test func encodesTwoDenseVersesAtSameTickOrderedByVerse() {
        let events = LyricMidiCodec.encode([
            Anchor(tick: 0, lyrics: [lyric("la", verse: 0), lyric("lo", verse: 1)]),
        ])
        #expect(events == [
            Event(tick: 0, text: "la"),
            Event(tick: 0, text: "lo"),
        ])
    }

    @Test func encodesSparseVerseWithEmptySentinelForSilentLowerVerse() {
        // Verse 0 silent, verse 1 sings -> a zero-length sentinel holds
        // verse 0's slot so ordinal position still maps to verse number.
        let events = LyricMidiCodec.encode([
            Anchor(tick: 0, lyrics: [lyric("lo", verse: 1)]),
        ])
        #expect(events == [
            Event(tick: 0, text: ""),
            Event(tick: 0, text: "lo"),
        ])
    }

    @Test func encodesNoEventsWhenChordHasNoLyrics() {
        let events = LyricMidiCodec.encode([Anchor(tick: 0, lyrics: [])])
        #expect(events.isEmpty)
    }

    @Test func dropsTrailingEmptyVerses() {
        let events = LyricMidiCodec.encode([
            Anchor(tick: 0, lyrics: [lyric("la", verse: 0), lyric("", verse: 1), lyric("", verse: 2)]),
        ])
        #expect(events == [Event(tick: 0, text: "la")])
    }

    @Test func encodesMelismaAsUnderscoreContinuationAtCoveredChords() {
        // "Glo" sung at tick 0 held over the chord at 480, next syllable
        // "ri" at 960. Melisma span = 960 ticks.
        let events = LyricMidiCodec.encode([
            Anchor(tick: 0, lyrics: [lyric("Glo", .begin, ticks: 960)]),
            Anchor(tick: 480, lyrics: []),
            Anchor(tick: 960, lyrics: [lyric("ri", .end)]),
        ])
        #expect(events == [
            Event(tick: 0, text: "Glo-"),
            Event(tick: 480, text: "_"),
            Event(tick: 960, text: "ri"),
        ])
    }

    // MARK: - decode

    @Test func decodesSingleStandaloneSyllable() {
        let map = LyricMidiCodec.decode([Event(tick: 0, text: "star")])
        #expect(map == [0: [lyric("star")]])
    }

    @Test func decodesHyphenConventionBackToSyllabic() {
        let map = LyricMidiCodec.decode([
            Event(tick: 0, text: "ha-"),
            Event(tick: 240, text: "le-"),
            Event(tick: 480, text: "lu"),
        ])
        #expect(map[0] == [lyric("ha", .begin)])
        #expect(map[240] == [lyric("le", .middle)])
        #expect(map[480] == [lyric("lu", .end)])
    }

    @Test func decodesDenseVersesByOrdinalPosition() {
        let map = LyricMidiCodec.decode([
            Event(tick: 0, text: "la"),
            Event(tick: 0, text: "lo"),
        ])
        #expect(map == [0: [lyric("la", verse: 0), lyric("lo", verse: 1)]])
    }

    @Test func decodesSparseVerseFromEmptySentinel() {
        let map = LyricMidiCodec.decode([
            Event(tick: 0, text: ""),
            Event(tick: 0, text: "lo"),
        ])
        #expect(map == [0: [lyric("", verse: 0), lyric("lo", verse: 1)]])
    }

    @Test func decodesMelismaRecoveringTicksAndLeavingCoveredChordEmpty() {
        let map = LyricMidiCodec.decode([
            Event(tick: 0, text: "Glo-"),
            Event(tick: 480, text: "_"),
            Event(tick: 960, text: "ri"),
        ])
        #expect(map[0] == [lyric("Glo", .begin, ticks: 960)])
        #expect(map[960] == [lyric("ri", .end)])
        // The covered chord at 480 carried only a continuation -> no lyric.
        #expect(map[480] == nil)
    }

    // MARK: - round trip

    @Test func roundTripsCombinedVersesSyllabicAndMelisma() {
        let anchors = [
            Anchor(tick: 0, lyrics: [lyric("A", .begin, ticks: 480, verse: 0), lyric("x", verse: 1)]),
            Anchor(tick: 240, lyrics: [lyric("y", verse: 1)]),
            Anchor(tick: 480, lyrics: [lyric("men", .end, verse: 0), lyric("z", verse: 1)]),
        ]
        let map = LyricMidiCodec.decode(LyricMidiCodec.encode(anchors))
        #expect(map[0] == [lyric("A", .begin, ticks: 480, verse: 0), lyric("x", verse: 1)])
        #expect(map[240] == [lyric("", verse: 0), lyric("y", verse: 1)])
        #expect(map[480] == [lyric("men", .end, verse: 0), lyric("z", verse: 1)])
    }
}
