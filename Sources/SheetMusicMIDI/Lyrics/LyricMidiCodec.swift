import Foundation
import SheetMusicCore

/// Packs and unpacks `Lyric` information into standard SMF Lyric
/// (`0xFF 0x05`) meta events so lyrics round-trip through MIDI without a
/// non-standard sidecar. Four pieces of information survive:
///
///   - **text** — verbatim, UTF-8.
///   - **syllabic** — a trailing `"-"` marks a `.begin`/`.middle`
///     syllable (the de-facto hyphenation convention); on decode the
///     hyphen plus the previous syllable's hyphen state reconstructs
///     `.begin`/`.middle`/`.end`/`.single`.
///   - **verse** — one event per verse at the chord tick, emitted in
///     ascending verse order. Silent lower verses are held with a
///     zero-length sentinel so a reader can map ordinal position back to
///     verse number. Trailing empty verses are dropped.
///   - **melisma** (`ticks`) — a syllable held across following chords
///     emits `"_"` continuation events at each covered chord tick; the
///     melisma span is recovered on decode as the gap to the next event
///     in that verse.
///
/// Limitations (documented, not silently lossy): a verse that is
/// genuinely empty *and* not under a melisma at a chord where a higher
/// verse sings is held by a sentinel (lossless); but a syllable whose
/// own text is literally `"_"` or ends in `"-"` collides with the
/// conventions and is not round-tripped. Melisma extent is recovered as
/// "until the next syllable in that verse", which matches MuseScore's
/// melisma semantics in the common case.
enum LyricMidiCodec {
    /// One chord's lyrics anchored at its absolute playback tick. Pass
    /// **every** non-rest chord of a voice (even lyric-free ones) so
    /// melisma continuations can be placed on the covered chords.
    struct Anchor: Equatable {
        var tick: Int
        var lyrics: [Lyric]
    }

    /// A single SMF Lyric meta event: UTF-8 text at an absolute tick.
    struct LyricEvent: Equatable {
        var tick: Int
        var text: String
    }

    /// Marks a `.begin` / `.middle` syllable that joins the next.
    private static let hyphen = "-"
    /// Melisma continuation: the prior syllable is still being sung.
    private static let melismaMarker = "_"

    // MARK: - Encode

    static func encode(_ anchors: [Anchor]) -> [LyricEvent] {
        // cell[tick][verse] = the text emitted for that verse slot.
        var cell: [Int: [Int: String]] = [:]
        // Melismas to expand in pass B: (startTick, verse, span).
        var melismas: [(tick: Int, verse: Int, span: Int)] = []

        // Pass A — syllables + sparse-verse sentinels.
        for anchor in anchors {
            let nonEmpty = anchor.lyrics.filter { !$0.text.isEmpty }
            guard let maxVerse = nonEmpty.map(\.verse).max() else { continue }
            var byVerse: [Int: Lyric] = [:]
            for lyric in nonEmpty {
                byVerse[lyric.verse] = lyric
            }
            for verse in 0 ... maxVerse {
                if let lyric = byVerse[verse] {
                    cell[anchor.tick, default: [:]][verse] = syllableText(lyric)
                    if lyric.ticks > 0 {
                        melismas.append((anchor.tick, verse, lyric.ticks))
                    }
                } else {
                    cell[anchor.tick, default: [:]][verse] = ""
                }
            }
        }

        // Pass B — melisma continuations on the covered chord ticks.
        let gridTicks = Set(anchors.map(\.tick)).sorted()
        for melisma in melismas {
            let end = melisma.tick + melisma.span
            for tick in gridTicks where tick > melisma.tick && tick < end {
                let existing = cell[tick]?[melisma.verse]
                if existing?.isEmpty ?? true {
                    cell[tick, default: [:]][melisma.verse] = melismaMarker
                }
            }
        }

        // Pass C — flatten per tick, verse 0…max ascending, sentinel-fill.
        var events: [LyricEvent] = []
        for tick in cell.keys.sorted() {
            let verses = cell[tick] ?? [:]
            guard let maxVerse = verses.keys.max() else { continue }
            for verse in 0 ... maxVerse {
                events.append(LyricEvent(tick: tick, text: verses[verse] ?? ""))
            }
        }
        return events
    }

    private static func syllableText(_ lyric: Lyric) -> String {
        switch lyric.syllabic {
        case .begin, .middle: lyric.text + hyphen
        case .end, .single: lyric.text
        }
    }

    // MARK: - Decode

    /// Reconstruct per-chord lyrics keyed by absolute tick. Ticks that
    /// carry only melisma continuations produce no entry (the covered
    /// chord has no syllable). Each value is verse-indexed and padded
    /// with empty `Lyric`s, matching the parser's representation.
    static func decode(_ events: [LyricEvent]) -> [Int: [Lyric]] {
        // Group by tick, preserving same-tick order (== verse order)
        // via a stable sort.
        let sorted = events.enumerated().sorted {
            $0.element.tick != $1.element.tick
                ? $0.element.tick < $1.element.tick
                : $0.offset < $1.offset
        }.map(\.element)

        var groups: [(tick: Int, texts: [String])] = []
        for event in sorted {
            if groups.last?.tick == event.tick {
                groups[groups.count - 1].texts.append(event.text)
            } else {
                groups.append((event.tick, [event.text]))
            }
        }

        let verseCount = groups.map(\.texts.count).max() ?? 0
        // byTickVerse[tick][verse] = decoded Lyric for that slot.
        var byTickVerse: [Int: [Int: Lyric]] = [:]
        for verse in 0 ..< verseCount {
            decodeVerseStream(verse, groups: groups, into: &byTickVerse)
        }

        return byTickVerse.mapValues { verses in
            let maxVerse = verses.keys.max() ?? -1
            return maxVerse < 0
                ? []
                : (0 ... maxVerse).map { verses[$0] ?? Lyric(text: "", verse: $0) }
        }
    }

    /// Walk one verse's events across all ticks, turning hyphen markers
    /// into `syllabic` and `"_"` runs into melisma `ticks`.
    private static func decodeVerseStream(
        _ verse: Int,
        groups: [(tick: Int, texts: [String])],
        into byTickVerse: inout [Int: [Int: Lyric]],
    ) {
        // Project this verse's stream: (tick, text) where present.
        let stream: [(tick: Int, text: String)] = groups.compactMap { group in
            verse < group.texts.count ? (group.tick, group.texts[verse]) : nil
        }

        var previousHadHyphen = false
        var index = 0
        while index < stream.count {
            let (tick, text) = stream[index]
            if text == melismaMarker {
                // A continuation with no preceding syllable in-stream:
                // nothing to attach to; skip.
                index += 1
                continue
            }
            if text.isEmpty {
                byTickVerse[tick, default: [:]][verse] = Lyric(text: "", verse: verse)
                index += 1
                continue
            }
            let hadHyphen = text.hasSuffix(hyphen)
            let core = hadHyphen ? String(text.dropLast()) : text
            let syllabic = syllabicFor(hadHyphen: hadHyphen, previousHadHyphen: previousHadHyphen)

            // Absorb following "_" continuations to size the melisma.
            var next = index + 1
            var sawContinuation = false
            var lastContinuationTick = tick
            while next < stream.count, stream[next].text == melismaMarker {
                sawContinuation = true
                lastContinuationTick = stream[next].tick
                next += 1
            }
            var ticks = 0
            if sawContinuation {
                ticks = next < stream.count
                    ? stream[next].tick - tick
                    : lastContinuationTick - tick
            }

            byTickVerse[tick, default: [:]][verse] = Lyric(
                text: core, syllabic: syllabic, ticks: ticks, verse: verse,
            )
            previousHadHyphen = hadHyphen
            index = next
        }
    }

    private static func syllabicFor(hadHyphen: Bool, previousHadHyphen: Bool) -> Syllabic {
        switch (hadHyphen, previousHadHyphen) {
        case (true, false): .begin
        case (true, true): .middle
        case (false, true): .end
        case (false, false): .single
        }
    }
}
