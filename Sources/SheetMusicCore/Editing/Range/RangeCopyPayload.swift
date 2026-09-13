import SheetMusicFoundation

/// Builds the ⌘C payload for a range selection: a small, self-contained `Score` holding exactly the copied
/// material. `MSCXEncoder.encode(_:)` and `MSCXParser.parse(_:)` already round-trip a `Score` in memory, so the
/// payload needs no format of its own — this type only carves the source score down to what the range covers.
///
/// The region is the same one every other range command reads, and it is read from the same place:
/// `RangeCopySource.Extent.init?(range:in:)` states the staff span and the `[earlier onset, later end)` tick
/// span once, and this type carves against that rather than re-deriving it. An earlier version derived its own
/// copy here, which is how it came to miss a fact the resolution already had — the boundary measure's new
/// length once the trim has cut material off its front.
///
/// This is deliberately much smaller than `RangeCopySource`, which builds the material `DuplicateRange` inserts
/// back into the SAME score: there is no tuplet-boundary refusal, no spanner re-anchoring, no outer-tie
/// clearing. A payload is landed by the paste engine those types already serve, so the shaping this type does
/// not do here is done once, downstream, for both a duplicate and a paste.
///
/// Internal on purpose: a host reaches this through `Score.clipboardDocument(for:)` below, under a name that
/// says what the result IS rather than how this type built it.
enum RangeCopyPayload {
    /// The copied range as a self-contained score: the covered staves, the covered measures, each voice
    /// trimmed to the range's tick span. `nil` when the range resolves to nothing.
    static func score(for range: VoiceElementRange, in score: Score) -> Score? {
        guard let extent = RangeCopySource.Extent(range: range, in: score) else { return nil }
        return self.score(for: extent, in: score)
    }

    /// The same, from an extent already stated. `nil` when the extent selects no chord or rest.
    static func score(for extent: RangeCopySource.Extent, in score: Score) -> Score? {
        guard !score.voiceElements(staves: extent.staves, from: extent.lower, to: extent.upper).isEmpty
        else { return nil }

        let low = extent.lower
        let high = extent.upper
        guard low < high else { return nil }
        let measureRange = low.measure ... high.measure

        var parts: [Part] = []
        for partIndex in score.parts.indices {
            let part = score.parts[partIndex]
            var staves: [Staff] = []
            for staffIndex in part.staves.indices {
                let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
                guard extent.staves.contains(address),
                      let copied = copiedStaff(
                          part.staves[staffIndex], measureRange: measureRange, low: low, high: high,
                          division: score.division,
                      )
                else { continue }
                staves.append(copied)
            }
            guard !staves.isEmpty else { continue }
            parts.append(Part(
                id: part.id, trackName: part.trackName, instrument: part.instrument,
                staves: IdentifiedArray(staves), isVisibleInScore: part.isVisibleInScore,
            ))
        }
        guard !parts.isEmpty else { return nil }
        return Score(division: score.division, parts: IdentifiedArray(parts))
    }

    /// One staff reduced to the copied measures, renumbered from zero: the boundary measures (first and last)
    /// trimmed of the chords and rests the tick span does not cover, every other kept measure carried whole,
    /// and the time signature in force at the range's start made explicit if the kept measures do not already
    /// declare one of their own. `nil` when this staff does not have the whole measure range the tick span
    /// touches.
    private static func copiedStaff(
        _ staff: Staff, measureRange: ClosedRange<Int>, low: ScoreTickPosition, high: ScoreTickPosition,
        division: Int,
    ) -> Staff? {
        guard staff.measures.indices.contains(measureRange.lowerBound),
              staff.measures.indices.contains(measureRange.upperBound)
        else { return nil }

        let durations = staff.measures.effectiveMeasureDurations()
        var measures = measureRange.map { measureIndex in
            trimmedMeasure(
                staff.measures[measureIndex], measureIndex: measureIndex, measureDuration: durations[measureIndex],
                low: low, high: high, division: division,
            )
        }
        shortenFirstMeasure(in: &measures, nominal: durations[measureRange.lowerBound], by: low, division: division)
        ensureLeadingTimeSignature(
            in: &measures, prevailing: prevailingTimeSignature(in: staff, upTo: measureRange.lowerBound),
        )

        var copied = staff
        copied.measures = measures
        // A bracket spans downward from this staff into siblings the payload may not carry, so it names a staff
        // this self-contained score no longer has.
        copied.brackets = []
        return copied
    }

    /// A kept measure, unchanged except at the range's own boundary: `measureIndex == low.measure` or
    /// `== high.measure` trims every voice to the span. A measure this function never touches (not
    /// `low.measure`/`high.measure`) is returned as-is, since nothing around it was cut.
    private static func trimmedMeasure(
        _ measure: Measure, measureIndex: Int, measureDuration: Fraction,
        low: ScoreTickPosition, high: ScoreTickPosition, division: Int,
    ) -> Measure {
        guard measureIndex == low.measure || measureIndex == high.measure else { return measure }
        var trimmed = measure
        trimmed.voices = measure.voices.map { voice in
            trimmedVoice(
                voice, measureIndex: measureIndex, measureDuration: measureDuration,
                low: low, high: high, division: division,
            )
        }
        return trimmed
    }

    /// One voice at the boundary: drops the chords, rests and `.spanner`s whose own tick falls outside
    /// `low ..< high`, and the `.locationShift`/`.measureRepeat` kinds outright.
    ///
    /// Those two are the kinds a cut boundary genuinely invalidates, and neither can be restated from what
    /// survives: a jog moves the voice's ONE cursor past ticks this trim may have just cut away, so it would
    /// re-date everything after it in the bar, and a measure repeat stands for a whole bar's content while a
    /// boundary measure is precisely the bar the trim can partially remove.
    ///
    /// A `.spanner` is not one of them. Its hazard is positional and it is the hazard the chords already have:
    /// the trim slides the survivors to the front of the boundary measure, so a spanner anchored AHEAD of the
    /// range would arrive at the payload's first tick and claim material the range never asked for. Testing its
    /// own tick removes that and keeps the rest — which matters because both boundaries of a one-bar copy are
    /// that one bar, so excluding the kind cost every hairpin, pedal, ottava, trill, vibrato, text line, palm
    /// mute and let ring a one-bar ⌘C could carry, while slurs (riding on `Chord.spanners`, untouched here)
    /// survived and made the loss look arbitrary. A spanner reaching PAST the payload is not this function's
    /// problem: `RangeCopySpanners.lineSpanners(for:…)` is all-or-nothing against the payload's own extent and
    /// drops it there, exactly as it does for a duplicate.
    ///
    /// Every other non-timed element — clef, key/time signature, annotations — is kept regardless of its tick,
    /// which is what "leaving everything else" means.
    ///
    /// `Voice.tuplets` rides through the same removal `Voice.removeElements(at:)` gives any other edit: a
    /// tuplet whose members are all cut drops with them, and one whose members all survive keeps its bracket,
    /// endpoints pulled inward for whatever the trim removed ahead of it.
    ///
    /// A tuplet only PARTLY covered — some members inside the span, some outside it — is the case a range's
    /// own boundary can create even though `removeElements(at:)` alone would still keep it, ratio unchanged,
    /// endpoints merely shrunk to the survivors. That is "carried half-formed" in the sense the earlier
    /// `.spanner` exclusion already established: a bracket claiming a note count the payload no longer has.
    /// Nothing is lost musically either way — a tuplet member's stored duration is already its resolved
    /// sounding length, not a plain fraction resolved against the bracket at read time — so this drops only
    /// the BRACKET for such a tuplet, not its surviving members: they stay as plain, untupleted material,
    /// which is what the user's own range legitimately asked for. `partlyCoveredPositions` below is computed
    /// against `voice.tupletSpans`'s ORIGINAL order before any removal, and reused as an index into
    /// `trimmed.tuplets` afterward: `removeElements(at:)` only ever drops entries (never reorders or inserts),
    /// so the k-th surviving span is exactly `trimmed.tuplets[k]`.
    private static func trimmedVoice(
        _ voice: Voice, measureIndex: Int, measureDuration: Fraction,
        low: ScoreTickPosition, high: ScoreTickPosition, division: Int,
    ) -> Voice {
        var tick = 0
        var removed: Set<Int> = []
        for index in voice.elements.indices {
            let element = voice.elements[index]
            defer { tick += element.cursorAdvance(division: division, in: measureDuration) }
            switch element {
            case .chord, .spanner:
                let position = ScoreTickPosition(measure: measureIndex, tick: tick)
                if !(position >= low && position < high) { removed.insert(index) }
            case .locationShift, .measureRepeat:
                removed.insert(index)
            default:
                break
            }
        }

        var partlyCoveredPositions: [Int] = []
        var survivorPosition = 0
        for span in voice.tupletSpans {
            let members = Array(span.startIndex ... span.endIndex)
            let survivorCount = members.filter { !removed.contains($0) }.count
            guard survivorCount > 0 else { continue } // Fully removed: dropped below, no position to reserve.
            if survivorCount < members.count { partlyCoveredPositions.append(survivorPosition) }
            survivorPosition += 1
        }

        var trimmed = voice
        trimmed.removeElements(at: removed)
        for position in partlyCoveredPositions.sorted(by: >) {
            trimmed.tuplets.removeSubrange(position ..< (position + 1))
        }
        return trimmed
    }

    /// Says how long the first payload measure now is, when the range's start cut material off its front.
    ///
    /// `trimmedVoice` drops the boundary measure's out-of-span chords, which slides the survivors to the FRONT
    /// of that measure — but the measure keeps its nominal length, so every later measure of the payload starts
    /// `low.tick` ticks too late and the payload carries a hole of exactly that size at the end of its first
    /// bar. A paste then reproduces the hole and, being that much longer than its own material, appends a bar
    /// that should not exist.
    ///
    /// MuseScore never writes a barline-padded fragment: `Selection::staffMimeData` (`dom/select.cpp:1090-1140`)
    /// writes `<StaffList tick="tickStart" len=…>` with a per-voice `<voiceOffset>` measured from the
    /// selection's own start, so the fragment is rebased rather than padded. This model already spells "a bar
    /// that is not its nominal length" as `Measure.actualLength` (`<Measure len>`), which
    /// `[Measure].effectiveMeasureDurations()` reads and `RangeCopyGeometry` builds `measureStarts` from — so
    /// stating the trimmed length here rebases the payload in the vocabulary it is already written in, and it
    /// survives the MSCX round trip the payload takes.
    ///
    /// The LAST measure is deliberately left at its nominal length. Nothing follows it to be displaced, and a
    /// chord whose onset is inside the span but whose sounding length runs past it survives the trim whole, so
    /// shortening that bar to the span's end could leave it overfull.
    private static func shortenFirstMeasure(
        in measures: inout [Measure], nominal: Fraction, by low: ScoreTickPosition, division: Int,
    ) {
        guard low.tick > 0, let first = measures.indices.first else { return }
        let remaining = nominal - Fraction(ticks: low.tick, division: division)
        guard remaining.numerator > 0 else { return }
        measures[first].actualLength = remaining
    }

    /// Inserts `.timeSignature(prevailing)` at the front of the first kept measure's first voice when no voice
    /// there already declares one. A range that starts mid-score inherits its meter from an earlier measure the
    /// payload does not carry, and a parser reading the payload alone — in another score, another window — has
    /// nothing else to resolve `.measure` durations against.
    ///
    /// Through `Voice.prependElement(_:)`, never by rebuilding the voice from its element array:
    /// `Voice.init(elements:)` defaults `tuplets` to `[]` and mints every slot unidentified, so a rebuild cost
    /// the bar both its brackets and its element ids — and the bar that reaches here is by definition one with
    /// no time signature of its own, which is the shape every non-first bar has.
    private static func ensureLeadingTimeSignature(in measures: inout [Measure], prevailing: TimeSignature) {
        guard let first = measures.indices.first, measures[first].voices.indices.contains(0) else { return }
        let alreadyDeclared = measures[first].voices.contains { voice in
            voice.elements.contains { if case .timeSignature = $0 { true } else { false } }
        }
        guard !alreadyDeclared else { return }
        measures[first].voices[0].prependElement(.timeSignature(prevailing))
    }

    /// The time signature carried forward to `measureIndex`, exactly the rule `[Measure].effectiveMeasureDurations()`
    /// uses to pick a prevailing `Fraction` — the first `.timeSignature` at or before `measureIndex`, defaulting to
    /// 4/4 when none has appeared yet.
    private static func prevailingTimeSignature(in staff: Staff, upTo measureIndex: Int) -> TimeSignature {
        var prevailing = TimeSignature(numerator: 4, denominator: 4)
        guard staff.measures.indices.contains(measureIndex) else { return prevailing }
        for measure in staff.measures[...measureIndex] {
            var found: TimeSignature?
            outer: for voice in measure.voices {
                for element in voice.elements {
                    if case let .timeSignature(timeSignature) = element {
                        found = timeSignature
                        break outer
                    }
                }
            }
            if let found { prevailing = found }
        }
        return prevailing
    }
}

extension Score {
    /// The document a ⌘C on `range` puts on the clipboard: a whole, self-contained `Score` — not a fragment
    /// addressed against this score — holding exactly the staves and measures `range` covers, with the range's
    /// own tick span made absolute (measure zero of the result is the range's first measure) and its prevailing
    /// time signature made explicit when the range starts mid-score.
    ///
    /// Encode the result with `MSCXEncoder.encode(_:)` before writing it to a pasteboard. That pairing —
    /// `clipboardDocument(for:)` to build the document, `MSCXEncoder`/`MSCXParser` to round-trip its bytes — is
    /// the whole design, and it does not show up by inspection alone: `SheetMusicMSCX` (where `MSCXEncoder`
    /// lives) depends on `SheetMusicCore`, so nothing in this package can encode the document itself, and a host
    /// linking both is the only place the pairing can be completed. The bytes this produces are exactly what
    /// `PasteRange`'s `payload` parameter expects back from a `PasteRange.PayloadReader` (in practice,
    /// `MSCXParser.parse`).
    ///
    /// `nil` when `range` resolves to nothing — an empty selection, or bounds that do not resolve in this score.
    public func clipboardDocument(for range: VoiceElementRange) -> Score? {
        RangeCopyPayload.score(for: range, in: self)
    }
}
