import SheetMusicFoundation

/// The two halves of re-barring one voice: FLATTEN turns a run's bars into one tick-addressed stream, EMIT
/// pours that stream back into bars of the new nominal length. Everything between them is absolute ticks
/// from the run's start, which is what makes the new barring a pure re-partition rather than a rewrite.
extension RebarPlanner {
    // MARK: - Geometry

    /// The tick grid a run is re-barred against: where each OLD bar sits, and where the NEW barlines fall.
    struct Geometry {
        let run: Range<Int>
        let division: Int
        let newTicks: Int
        let columnCount: Int
        let totalTicks: Int
        /// Run-relative start tick of each old bar, indexed by offset within `run`.
        let measureStarts: [Int]
        /// Nominal duration of each old bar — what a `.measure` rest there resolves against.
        let measureDurations: [Fraction]
        let measureTicks: [Int]

        var newDuration: Fraction {
            fraction(ofTicks: newTicks)
        }

        func columnStart(_ column: Int) -> Int {
            column * newTicks
        }

        func columnEnd(_ column: Int) -> Int {
            (column + 1) * newTicks
        }

        /// The column holding `tick`, clamped — the padded tail of the last column is still that column.
        func column(containing tick: Int) -> Int {
            min(max(tick / newTicks, 0), columnCount - 1)
        }

        /// Ticks as the fraction-of-a-whole-note every position field in the model is written in.
        func fraction(ofTicks ticks: Int) -> Fraction {
            Fraction(numerator: ticks, denominator: 4 * division)
        }

        /// A timed span cut at every new barline it crosses.
        func segments(from start: Int, ticks: Int) -> [(column: Int, tick: Int, ticks: Int)] {
            var result: [(column: Int, tick: Int, ticks: Int)] = []
            var tick = start
            var remaining = ticks
            while remaining > 0 {
                let column = column(containing: tick)
                let end = min(tick + remaining, columnEnd(column))
                guard end > tick else { break }
                result.append((column, tick, end - tick))
                remaining -= end - tick
                tick = end
            }
            return result
        }
    }

    // MARK: - Flatten

    /// One item of a voice's stream, addressed by its run-relative start tick.
    struct StreamItem {
        enum Kind {
            /// A chord or a rest: the one thing a new barline may cut.
            case timed
            /// A clef, key, dynamic, harmony, spanner … — carried at its tick, occupying none.
            case untimed
            /// A whole tuplet span, indivisible (rule 4).
            case tuplet(normalNotes: Int, actualNotes: Int)
        }

        var kind: Kind
        var tick: Int
        var ticks: Int
        var elements: [VoiceElement]
        /// The PRE-EDIT bar this came from — what a refusal points the host at.
        var measureIndex: Int
    }

    struct BarLineMarker {
        var tick: Int
        var element: VoiceElement
        var measureIndex: Int
    }

    struct FlatVoice {
        var items: [StreamItem] = []
        var barLines: [BarLineMarker] = []
    }

    static func flatten(voiceIndex: Int, in staff: Staff, geometry: Geometry) -> FlatVoice {
        var flat = FlatVoice()
        for (offset, measureIndex) in geometry.run.enumerated() {
            guard staff.measures.indices.contains(measureIndex) else { continue }
            let measure = staff.measures[measureIndex]
            // A voice absent from a bar contributes nothing at all — that whole span is gap for it.
            guard measure.voices.indices.contains(voiceIndex) else { continue }
            append(
                measure.voices[voiceIndex],
                measureIndex: measureIndex,
                base: geometry.measureStarts[offset],
                measureDuration: geometry.measureDurations[offset],
                division: geometry.division,
                into: &flat,
            )
        }
        return flat
    }

    private static func append(
        _ voice: Voice, measureIndex: Int, base: Int, measureDuration: Fraction, division: Int,
        into flat: inout FlatVoice,
    ) {
        var cursor = base
        var index = 0
        while index < voice.elements.count {
            if let tuplet = voice.tuplets.first(where: { $0.startIndex <= index && index <= $0.endIndex }),
               voice.elements.indices.contains(tuplet.startIndex),
               voice.elements.indices.contains(tuplet.endIndex),
               tuplet.startIndex <= tuplet.endIndex
            {
                let members = Array(voice.elements[tuplet.startIndex ... tuplet.endIndex])
                let ticks = members.reduce(0) {
                    $0 + ($1.tickCount(division: division, in: measureDuration) ?? 0)
                }
                flat.items.append(StreamItem(
                    kind: .tuplet(normalNotes: tuplet.normalNotes, actualNotes: tuplet.actualNotes),
                    tick: cursor, ticks: ticks, elements: members, measureIndex: measureIndex,
                ))
                cursor += ticks
                index = tuplet.endIndex + 1
                continue
            }
            let element = voice.elements[index]
            index += 1
            switch element {
            case .timeSignature:
                // The region's meter is the caller's to declare; every old declaration inside it goes.
                continue
            case .barLine:
                flat.barLines.append(BarLineMarker(
                    tick: cursor, element: element, measureIndex: measureIndex,
                ))
                continue
            case let .locationShift(delta):
                // A jog, not an item: the elements after it are simply addressed from the moved cursor,
                // and the emitter re-derives whatever jog the new barring needs to reach them.
                cursor += delta.ticks(division: division)
                continue
            default:
                break
            }
            if let ticks = element.tickCount(division: division, in: measureDuration) {
                flat.items.append(StreamItem(
                    kind: .timed, tick: cursor, ticks: ticks,
                    elements: [element], measureIndex: measureIndex,
                ))
                cursor += ticks
            } else {
                flat.items.append(StreamItem(
                    kind: .untimed, tick: cursor, ticks: 0,
                    elements: [element], measureIndex: measureIndex,
                ))
            }
        }
    }

    // MARK: - Emit

    /// Fills one voice's share of every new column. Each column carries its own cursor — the absolute tick
    /// its written content reaches — so a gap and a jog are the same computation from opposite signs.
    struct VoiceEmitter {
        let geometry: Geometry
        let voiceIndex: Int
        private var elements: [[VoiceElement]]
        private var tuplets: [[Tuplet]]
        private var cursors: [Int]
        private var present: [Bool]

        init(geometry: Geometry, voiceIndex: Int) {
            self.geometry = geometry
            self.voiceIndex = voiceIndex
            elements = Array(repeating: [], count: geometry.columnCount)
            tuplets = Array(repeating: [], count: geometry.columnCount)
            cursors = (0 ..< geometry.columnCount).map { $0 * geometry.newTicks }
            present = Array(repeating: false, count: geometry.columnCount)
        }

        mutating func place(_ items: [StreamItem]) throws {
            for item in items {
                switch item.kind {
                case .untimed:
                    placeUntimed(item)
                case let .tuplet(normalNotes, actualNotes):
                    try placeTuplet(item, normalNotes: normalNotes, actualNotes: actualNotes)
                case .timed:
                    placeTimed(item)
                }
            }
        }

        /// Rule 6: every voice-0 column ends up nominal length. A higher voice keeps its trailing gap — that
        /// is what a voice that stops before the barline looks like, and filling it would invent rests.
        mutating func pad() {
            guard voiceIndex == 0 else { return }
            for column in elements.indices where cursors[column] < geometry.columnEnd(column) {
                elements[column].append(contentsOf: DurationChangeAlgorithm.alignedRests(
                    forTicks: geometry.columnEnd(column) - cursors[column],
                    rtickStart: cursors[column] - geometry.columnStart(column),
                    division: geometry.division,
                ))
                cursors[column] = geometry.columnEnd(column)
                present[column] = true
            }
        }

        func voice(forColumn column: Int) -> Voice? {
            guard voiceIndex == 0 || present[column] else { return nil }
            let built = promotedToMeasureRest(column: column) ?? elements[column]
            return Voice(elements: built, tuplets: tuplets[column])
        }

        // MARK: Placement

        private mutating func placeTimed(_ item: StreamItem) {
            let segments = geometry.segments(from: item.tick, ticks: item.ticks)
            guard let first = segments.first else { return }
            // A note the new barring leaves alone is left alone. Only a note the new grid actually cuts is
            // re-spelled, so re-barring never re-writes rhythms it didn't have to touch — the exception is
            // a `.measure` rest, whose length is the BAR's and so has to be restated against the new one.
            if segments.count == 1, !RebarPlanner.hasMeasureDuration(item.elements[0]) {
                _ = append(item.elements, at: item.tick, ticks: item.ticks, in: first.column)
                return
            }
            let perSegment = segments.map { segment in
                DurationChangeAlgorithm.alignedDurations(
                    forTicks: segment.ticks,
                    rtickStart: segment.tick - geometry.columnStart(segment.column),
                    division: geometry.division,
                )
            }
            // ONE chain over every piece, not one per column: the ties at the interior joints are the
            // chain's, and re-starting it at each barline would clear the head's incoming tie each time.
            let pieces = RebarPlanner.pieces(of: item.elements[0], durations: perSegment.flatMap(\.self))
            var written = 0
            for (index, segment) in segments.enumerated() {
                let count = perSegment[index].count
                guard count > 0, written + count <= pieces.count else { continue }
                _ = append(
                    Array(pieces[written ..< written + count]),
                    at: segment.tick, ticks: segment.ticks, in: segment.column,
                )
                written += count
            }
        }

        private mutating func placeTuplet(
            _ item: StreamItem, normalNotes: Int, actualNotes: Int,
        ) throws {
            let column = geometry.column(containing: item.tick)
            guard item.tick + item.ticks <= geometry.columnEnd(column) else {
                throw RebarPlanner.refused(.rebarWouldSplitTuplet(measureIndex: item.measureIndex))
            }
            let range = append(item.elements, at: item.tick, ticks: item.ticks, in: column)
            guard !range.isEmpty else { return }
            tuplets[column].append(Tuplet(
                normalNotes: normalNotes, actualNotes: actualNotes,
                startIndex: range.lowerBound, endIndex: range.upperBound - 1,
            ))
        }

        /// An untimed element is anchored, not timed: it lands at its own tick and leaves the cursor where
        /// it was, so a displaced one is written as a jog out and straight back — MuseScore's own shape for
        /// a mark that doesn't sit on the natural cursor.
        private mutating func placeUntimed(_ item: StreamItem) {
            let column = geometry.column(containing: item.tick)
            let delta = item.tick - cursors[column]
            if delta != 0 {
                elements[column].append(.locationShift(delta: geometry.fraction(ofTicks: delta)))
            }
            elements[column].append(contentsOf: item.elements)
            if delta != 0 {
                elements[column].append(.locationShift(delta: geometry.fraction(ofTicks: -delta)))
            }
            present[column] = true
        }

        /// Appends timed content at `tick`, closing whatever distance separates it from the column's cursor
        /// first. Returns where the content landed, so a tuplet can name its own members.
        private mutating func append(
            _ pieces: [VoiceElement], at tick: Int, ticks: Int, in column: Int,
        ) -> Range<Int> {
            closeGap(to: tick, in: column)
            let start = elements[column].count
            elements[column].append(contentsOf: pieces)
            cursors[column] = tick + ticks
            present[column] = true
            return start ..< elements[column].count
        }

        /// A gap ahead of the main voice reads as rests; anywhere else — a higher voice that simply isn't
        /// sounding yet, or a jog backwards — it is a `.locationShift`, which is how the model spells a
        /// cursor that moves without time passing.
        private mutating func closeGap(to tick: Int, in column: Int) {
            let cursor = cursors[column]
            guard tick != cursor else { return }
            if tick > cursor, voiceIndex == 0 {
                elements[column].append(contentsOf: DurationChangeAlgorithm.alignedRests(
                    forTicks: tick - cursor,
                    rtickStart: cursor - geometry.columnStart(column),
                    division: geometry.division,
                ))
            } else {
                elements[column].append(.locationShift(delta: geometry.fraction(ofTicks: tick - cursor)))
            }
            cursors[column] = tick
        }

        /// Rule 5's tail: a new bar covered end to end by rests is one measure rest, whatever the rests
        /// beat-alignment produced. Signatures at the head stay; anything else in the bar blocks it.
        private func promotedToMeasureRest(column: Int) -> [VoiceElement]? {
            guard tuplets[column].isEmpty else { return nil }
            let prefix = elements[column].prefix(while: MeasureStructure.isLeadingSignature).count
            let body = elements[column].dropFirst(prefix)
            guard !body.isEmpty, body.allSatisfy(\.isRest) else { return nil }
            let ticks = body.reduce(0) {
                $0 + ($1.tickCount(division: geometry.division, in: geometry.newDuration) ?? 0)
            }
            guard ticks == geometry.newTicks else { return nil }
            return Array(elements[column].prefix(prefix)) + [.rest(duration: .measure)]
        }
    }

    // MARK: - Pieces

    /// A chord or rest whose length is "however long this bar is" — the one duration that cannot be carried
    /// across a re-bar unchanged, because the bar it names is not the bar it will land in.
    static func hasMeasureDuration(_ element: VoiceElement) -> Bool {
        if case let .chord(chord) = element, case .measure = chord.duration { return true }
        return false
    }

    /// One source chord or rest spelled as `durations`.
    ///
    /// `makeChordChain` builds every piece from scratch and so clears the head's `tieBack` — right for a
    /// duration change, wrong here: a chord tied IN from before the region is still tied in after it is
    /// re-barred. The head is rebuilt from the source chord the way `CrossBarInputPlanner.piece` does, so
    /// its incoming tie — and everything else hanging off the sound — survives.
    static func pieces(of element: VoiceElement, durations: [NoteDuration]) -> [VoiceElement] {
        guard case let .chord(chord) = element, !chord.notes.isEmpty else {
            return durations.map { .rest(duration: $0) }
        }
        var chain = DurationChangeAlgorithm.makeChordChain(from: chord, durations: durations)
        guard case let .chord(head) = chain.first, let first = durations.first else { return chain }
        var restored = chord
        restored.duration = first
        restored.notes = head.notes
        for index in restored.notes.indices where chord.notes.indices.contains(index) {
            restored.notes[index].tieBack = chord.notes[index].tieBack
        }
        // Grace notes AFTER the chord lead into whatever follows the sound, so they belong on its last
        // piece — the one thing the head gives up when the chain is longer than one. `makeChordChain`
        // carries them nowhere, so the tail has to be given them here.
        restored.graceNotesAfter = durations.count == 1 ? chord.graceNotesAfter : []
        chain[0] = .chord(restored)
        if durations.count > 1, !chord.graceNotesAfter.isEmpty,
           case var .chord(tail) = chain[chain.count - 1]
        {
            tail.graceNotesAfter = chord.graceNotesAfter
            chain[chain.count - 1] = .chord(tail)
        }
        return chain
    }
}
