import SheetMusicFoundation

/// One bar of a drum staff as `RevoiceBarPlanner` reads it before deciding anything: every chord and rest with its
/// onset, resolved length and tuplet, every note as a hit (design §4: a note, where it starts, and the chord it came
/// from), and every other stream element at its tick. Read the way `FormatRhythmsBarContext` reads a voice — a
/// `.locationShift` moves the cursor, a `.measure` rest resolves against the bar — but across all of the bar's voices
/// at once, because re-voicing moves notes between them. Ticks are bar-relative, counted from the bar's first element.
struct RevoiceBar {
    /// Where a chord or rest sits in the source bar.
    struct ChordRef: Hashable, Sendable {
        let voiceIndex: Int
        let elementIndex: Int
    }

    /// A chord or rest of the source bar.
    struct SourceChord: Equatable {
        let ref: ChordRef
        let eid: EID
        let chord: Chord
        let onset: Int
        /// The resolved length in ticks: a `.measure` rest is the bar's length, a tuplet member its scaled value.
        let length: Int
        /// The innermost tuplet holding it, as an index into `tuplets`; nil outside every tuplet.
        let tuplet: Int?
    }

    /// One note of the bar, with the chord it came from.
    struct Hit: Equatable {
        let onset: Int
        let note: Note
        /// The note's identifier inside its chord.
        let noteEID: EID
        let source: ChordRef

        var pitch: Int {
            note.pitch
        }
    }

    /// A stream element that is neither a chord nor a measure repeat — a dynamic, a sticking, a clef, a staff-anchored
    /// spanner, a signature, preserved XML, a location shift — at the tick the voice's cursor stands on when it is
    /// reached. `elementIndex` is its place in its voice, which is what orders it against a chord at the same tick.
    struct Annotation: Equatable {
        let voiceIndex: Int
        let elementIndex: Int
        let eid: EID
        let tick: Int
        let element: VoiceElement
    }

    /// A tuplet of the source bar, with the members it spans and the ticks they cover.
    struct TupletRun: Equatable {
        let voiceIndex: Int
        let eid: EID
        let tuplet: Tuplet
        let startIndex: Int
        let endIndex: Int
        let onset: Int
        let length: Int
    }

    let measureIndex: Int
    let voices: [Voice]
    let meter: BarMeter
    /// False for a bar of no length or a meter no splitter can read (a file's 4/0 or 3/7).
    let isMeterReadable: Bool
    /// The bar is part of a measure repeat: it holds a `.measureRepeat`, or is numbered in a repeat group.
    let isMeasureRepeat: Bool
    /// Every chord and rest, voice by voice, each voice in stream order.
    let chords: [SourceChord]
    /// Every note, in the order of `chords`.
    let hits: [Hit]
    let annotations: [Annotation]
    let tuplets: [TupletRun]
    /// Some chord or rest sits inside more than one tuplet.
    let hasNestedTuplets: Bool

    /// Bar `measureIndex` of `staff`. This reads the whole staff for the bar's length and meter; a walk over every bar
    /// builds `FormatRhythmsBars` once and uses `init(staff:measureIndex:bars:)` instead.
    init(staff: Staff, measureIndex: Int, division: Int) {
        self.init(staff: staff, measureIndex: measureIndex, bars: FormatRhythmsBars(staff: staff, division: division))
    }

    /// Bar `measureIndex` of `staff`, with the staff's per-bar meters, lengths and pickups already read.
    init(staff: Staff, measureIndex: Int, bars: FormatRhythmsBars) {
        let measure = staff.measures[measureIndex]
        let barTicks = bars.barTicks[measureIndex]
        let signature = bars.meters[measureIndex]
        self.measureIndex = measureIndex
        voices = measure.voices
        meter = BarMeter(
            numerator: signature.numerator, denominator: signature.denominator, barTicks: barTicks,
            isPickup: bars.isPickup[measureIndex], division: bars.division,
        )
        isMeterReadable = barTicks > 0 && RhythmMeter.isReadable(
            numerator: signature.numerator, denominator: signature.denominator, division: bars.division,
        )
        var reading = Reading(
            measureDuration: Fraction(ticks: barTicks, division: bars.division), division: bars.division,
        )
        for (voiceIndex, voice) in measure.voices.enumerated() {
            reading.read(voice, voiceIndex: voiceIndex)
        }
        isMeasureRepeat = measure.measureRepeatCount != nil || reading.hasMeasureRepeat
        chords = reading.chords
        hits = reading.hits
        annotations = reading.annotations
        tuplets = reading.tuplets
        hasNestedTuplets = reading.hasNestedTuplets
    }
}

/// The accumulator `RevoiceBar.init` reads each voice into.
private struct Reading {
    let measureDuration: Fraction
    let division: Int
    var chords: [RevoiceBar.SourceChord] = []
    var hits: [RevoiceBar.Hit] = []
    var annotations: [RevoiceBar.Annotation] = []
    var tuplets: [RevoiceBar.TupletRun] = []
    var hasMeasureRepeat = false
    var hasNestedTuplets = false

    mutating func read(_ voice: Voice, voiceIndex: Int) {
        let elements = voice.elements.values
        let advances = elements.map { $0.cursorAdvance(division: division, in: measureDuration) }
        var onsets: [Int] = []
        var cursor = 0
        for advance in advances {
            onsets.append(cursor)
            cursor += advance
        }
        let containing = readTuplets(of: voice, voiceIndex: voiceIndex, onsets: onsets, advances: advances)
        for (index, element) in elements.enumerated() {
            let eid = voice.elements.eid(at: index)
            switch element {
            case let .chord(chord):
                let ref = RevoiceBar.ChordRef(voiceIndex: voiceIndex, elementIndex: index)
                chords.append(RevoiceBar.SourceChord(
                    ref: ref, eid: eid, chord: chord, onset: onsets[index], length: advances[index],
                    tuplet: innermost(containing[index]),
                ))
                for position in chord.notes.indices {
                    hits.append(RevoiceBar.Hit(
                        onset: onsets[index], note: chord.notes[position], noteEID: chord.notes.eid(at: position),
                        source: ref,
                    ))
                }
            case .measureRepeat:
                hasMeasureRepeat = true
            default:
                annotations.append(RevoiceBar.Annotation(
                    voiceIndex: voiceIndex, elementIndex: index, eid: eid, tick: onsets[index], element: element,
                ))
            }
        }
    }

    /// Records the voice's resolved tuplets and answers, per element, the indices into `tuplets` of every tuplet
    /// holding it. A dangling span (an endpoint that names no member) holds nothing.
    private mutating func readTuplets(
        of voice: Voice, voiceIndex: Int, onsets: [Int], advances: [Int],
    ) -> [[Int]] {
        var containing = [[Int]](repeating: [], count: onsets.count)
        for (position, span) in voice.tupletSpans.enumerated() where span.isResolved && span.endIndex < onsets.count {
            for index in span.startIndex ... span.endIndex {
                containing[index].append(tuplets.count)
            }
            tuplets.append(RevoiceBar.TupletRun(
                voiceIndex: voiceIndex, eid: voice.tuplets.eid(at: position), tuplet: voice.tuplets[position],
                startIndex: span.startIndex, endIndex: span.endIndex, onset: onsets[span.startIndex],
                length: onsets[span.endIndex] + advances[span.endIndex] - onsets[span.startIndex],
            ))
        }
        if containing.contains(where: { $0.count > 1 }) { hasNestedTuplets = true }
        return containing
    }

    /// The narrowest of `runs`: the innermost tuplet when they nest.
    private func innermost(_ runs: [Int]) -> Int? {
        runs.min { tuplets[$0].endIndex - tuplets[$0].startIndex < tuplets[$1].endIndex - tuplets[$1].startIndex }
    }
}
