import SheetMusicFoundation

/// The machinery both meter commands share: which bars a declaration governs, what that span looked like before
/// the re-bar, how `RebarPlanner`'s replacement columns are spliced back over it, and what a re-bar does to a
/// spanner whose span reaches across it.
///
/// Split off `SetTimeSignature.swift` so that file stays a statement of the two commands and their inverse. The
/// seam is the same one `SignaturePrefixes` marks next door in `SetKeySignature.swift`: everything here reads or
/// writes the SCORE around the edit, while the commands state what the edit is.
enum TimeSignatureRegion {
    /// A spanner's address paired with the `nextMeasuresOffset` it carries at one point in time — the pre-image a
    /// restore puts back, and the recomputed value a re-bar writes.
    struct SpannerOffset: Sendable, Equatable {
        var id: VoiceElementID
        var offset: Int
    }

    /// Whether a host's numbers name a signature that can be written at all. The UI never sends anything else;
    /// the guard is for a command built directly. 63 is MuseScore's own numerator ceiling, and the denominators
    /// are the powers of two a note duration exists for.
    static func isWritable(numerator: Int, denominator: Int) -> Bool {
        (1 ... 63).contains(numerator) && [1, 2, 4, 8, 16, 32].contains(denominator)
    }

    // MARK: - Reading what a bar declares

    /// The time signature `measure` declares, wherever in it that declaration sits.
    ///
    /// Deliberately the rule `[Measure].effectiveMeasureDurations()` applies — the FIRST `.timeSignature` found
    /// scanning voices in order — so "the meter in force here" is the same answer every tick walker, encoder and
    /// renderer already resolves a `.measure` duration against.
    static func declaredSignature(in measure: Measure) -> TimeSignature? {
        for voice in measure.voices {
            for element in voice.elements {
                if case let .timeSignature(signature) = element { return signature }
            }
        }
        return nil
    }

    /// The meter `measureIndex` declares of its own, or `nil` when it simply inherits the one in force. Read from
    /// part 0 / staff 0: a time signature is score-wide in this model, the invariant
    /// `Score.effectiveMeasureDurations()` itself rests on.
    static func explicitSignature(in score: Score, measureIndex: Int) -> TimeSignature? {
        guard let staff = score.parts.first?.staves.first,
              staff.measures.indices.contains(measureIndex)
        else { return nil }
        return declaredSignature(in: staff.measures[measureIndex])
    }

    /// The meter in force AT `measureIndex` — the last declaration up to and including that bar.
    static func signature(inForceAt measureIndex: Int, in score: Score) -> TimeSignature {
        prevailing(through: measureIndex, in: score)
    }

    /// The meter in force immediately BEFORE `measureIndex` — what its span reverts to once the bar's own
    /// declaration is removed.
    static func signature(inForceBefore measureIndex: Int, in score: Score) -> TimeSignature {
        prevailing(through: measureIndex - 1, in: score)
    }

    /// 4/4 until something says otherwise, matching `effectiveMeasureDurations`' own default for a score whose
    /// first bars declare nothing.
    private static func prevailing(through last: Int, in score: Score) -> TimeSignature {
        var current = TimeSignature(numerator: 4, denominator: 4)
        guard let staff = score.parts.first?.staves.first else { return current }
        for measureIndex in staff.measures.indices where measureIndex <= last {
            if let declared = declaredSignature(in: staff.measures[measureIndex]) { current = declared }
        }
        return current
    }

    /// The first bar after `measureIndex` that declares a meter of its own — where a signature written at
    /// `measureIndex` stops being the one in force. `nil` when no later bar declares one.
    static func nextExplicitChange(after measureIndex: Int, in score: Score) -> Int? {
        guard let staff = score.parts.first?.staves.first else { return nil }
        let start = max(measureIndex + 1, 0)
        guard start < staff.measures.count else { return nil }
        return (start ..< staff.measures.count).first {
            declaredSignature(in: staff.measures[$0]) != nil
        }
    }

    /// A bar whose length is its own on ANY staff — a pickup, or a deliberately short one. `RebarPlanner` passes
    /// such a bar through verbatim, which is why the head case needs handling here; same spelling it uses.
    static func isIrregular(_ measureIndex: Int, in score: Score) -> Bool {
        score.parts.contains { part in
            part.staves.contains { staff in
                staff.measures.indices.contains(measureIndex)
                    && staff.measures[measureIndex].actualLength != nil
            }
        }
    }

    // MARK: - Writing what the head column declares

    /// Writes `signature` into `column`'s voice 0 on every staff: replacing the meter that bar already declares —
    /// in place, so an invisible or courtesy-suppressed signature stays that way and its bar keeps whatever
    /// `actualLength` it had — or inserting one at the canonical clef → key → time position when it declares
    /// none.
    ///
    /// Only ever called on an IRREGULAR head column. Everywhere else the declaration is `RebarPlanner`'s, which
    /// drops every old signature in the run and writes one fresh — the responsibility stays there.
    static func declare(_ signature: TimeSignature, in column: inout MeasureSlice) {
        mutateVoiceZero(of: &column) { voice in
            let prefix = MeasureStructure.leadingSignaturePrefix(of: voice)
            let existing = prefix.firstIndex { if case .timeSignature = $0 { true } else { false } }
            if let existing, case var .timeSignature(current) = voice.elements[existing] {
                current.numerator = signature.numerator
                current.denominator = signature.denominator
                voice.elements[existing] = .timeSignature(current)
                return
            }
            voice.elements.insert(.timeSignature(signature), at: prefix.count)
            MeasureStructure.shiftTuplets(in: &voice, by: 1)
        }
    }

    /// Drops every meter declaration from `column`'s voice 0 — the removal's half of `declare`, and likewise only
    /// for an irregular head column, since a re-barred run has already lost its own.
    static func removeSignatures(from column: inout MeasureSlice) {
        mutateVoiceZero(of: &column) { voice in
            MeasureStructure.removeElements(in: &voice) {
                if case .timeSignature = $0 { true } else { false }
            }
        }
    }

    private static func mutateVoiceZero(of column: inout MeasureSlice, _ mutate: (inout Voice) -> Void) {
        for partIndex in column.staffMeasures.indices {
            for staffIndex in column.staffMeasures[partIndex].indices
                where !column.staffMeasures[partIndex][staffIndex].voices.isEmpty
            {
                mutate(&column.staffMeasures[partIndex][staffIndex].voices[0])
            }
        }
    }

    // MARK: - Capture and splice

    /// `region`'s measure columns exactly as they stand — every staff plus the parallel `SystemMeasure`.
    static func capturedColumns(of score: Score, over region: Range<Int>) -> [MeasureSlice] {
        region.map { measureIndex in
            MeasureSlice(
                staffMeasures: score.parts.map { part in
                    part.staves.map { staff in
                        staff.measures.indices.contains(measureIndex)
                            ? staff.measures[measureIndex]
                            : Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
                    }
                },
                systemMeasure: score.systemMeasures.indices.contains(measureIndex)
                    ? score.systemMeasures[measureIndex] : SystemMeasure(),
            )
        }
    }

    /// Replaces `range` with `columns` on every staff, and in the system lane when that lane is parallel.
    ///
    /// A staff too short to cover `range` is skipped whole rather than padded — the same conservatism
    /// `InsertMeasure.insert` applies to `systemMeasures`, and for the same reason: a score that never held the
    /// invariant must come back out of an undo exactly as it went in, not partially patched into it.
    static func splice(_ columns: [MeasureSlice], into score: inout Score, replacing range: Range<Int>) {
        let parallelLane = score.systemMeasures.count == MeasureStructure.measureCount(of: score)
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                guard score.parts[partIndex].staves[staffIndex].measures.count >= range.upperBound else {
                    continue
                }
                let replacement = columns.map { column in
                    column.staffMeasures.indices.contains(partIndex)
                        && column.staffMeasures[partIndex].indices.contains(staffIndex)
                        ? column.staffMeasures[partIndex][staffIndex]
                        : Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
                }
                score.parts[partIndex].staves[staffIndex].measures
                    .replaceSubrange(range, with: replacement)
            }
        }
        guard parallelLane, score.systemMeasures.count >= range.upperBound else { return }
        score.systemMeasures.replaceSubrange(range, with: columns.map(\.systemMeasure))
    }

    // MARK: - Spanners reaching across the region

    /// Every spanner anchored BEFORE `region` whose span reaches into it or past it, with the offset it carries
    /// now.
    ///
    /// Spanners anchored inside or after the region are deliberately absent. One anchored after it measures a
    /// distance across bars the re-bar never touched; one anchored inside travels with the column it lives in,
    /// and re-addressing it is `RebarPlanner`'s business rather than the splice's.
    static func crossingSpannerOffsets(of score: Score, region: Range<Int>) -> [SpannerOffset] {
        var result: [SpannerOffset] = []
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                let measures = score.parts[partIndex].staves[staffIndex].measures
                for measureIndex in measures.indices where measureIndex < region.lowerBound {
                    result.append(contentsOf: crossingSpanners(
                        in: measures[measureIndex],
                        staff: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex),
                        measureIndex: measureIndex, region: region,
                    ))
                }
            }
        }
        return result
    }

    private static func crossingSpanners(
        in measure: Measure, staff: StaffAddress, measureIndex: Int, region: Range<Int>,
    ) -> [SpannerOffset] {
        var result: [SpannerOffset] = []
        for voiceIndex in measure.voices.indices {
            let elements = measure.voices[voiceIndex].elements
            for elementIndex in elements.indices {
                guard case let .spanner(spanner) = elements[elementIndex],
                      measureIndex + spanner.nextMeasuresOffset >= region.lowerBound
                else { continue }
                result.append(SpannerOffset(
                    id: VoiceElementID(
                        staff: staff, measureIndex: measureIndex,
                        voiceIndex: voiceIndex, elementIndex: elementIndex,
                    ),
                    offset: spanner.nextMeasuresOffset,
                ))
            }
        }
        return result
    }

    /// `captured` restated against the new barring: the span's END BAR is mapped by tick, so the endpoint stays
    /// on the moment it always fell on.
    ///
    /// Two shapes, and they are not the same arithmetic. A span reaching PAST the region simply gains however
    /// many bars the region gained, because everything after it shifted by exactly that. A span ending INSIDE it
    /// has no such invariant: its end bar is gone, and the new bar to name is whichever column now holds that
    /// bar's start tick.
    static func recomputed(
        _ captured: [SpannerOffset], region: Range<Int>, columns: [MeasureSlice],
        signature: TimeSignature, in score: Score,
    ) -> [SpannerOffset] {
        guard !captured.isEmpty else { return [] }
        let durations = score.effectiveMeasureDurations()
        let oldStarts = startTicks(
            region.map { durations.indices.contains($0) ? durations[$0] : signatureFraction(signature) },
            division: score.division,
        )
        let newStarts = startTicks(
            columns.map { $0.staffMeasures.first?.first?.actualLength ?? signatureFraction(signature) },
            division: score.division,
        )
        let delta = columns.count - region.count
        return captured.map { entry in
            let end = entry.id.measureIndex + entry.offset
            let mapped: Int
            if end >= region.upperBound {
                mapped = end + delta
            } else {
                let offsetInRegion = end - region.lowerBound
                let tick = oldStarts.indices.contains(offsetInRegion) ? oldStarts[offsetInRegion] : 0
                mapped = region.lowerBound + column(containing: tick, starts: newStarts)
            }
            return SpannerOffset(id: entry.id, offset: mapped - entry.id.measureIndex)
        }
    }

    /// Writes each captured offset back onto the spanner it names, skipping any address that no longer holds one.
    static func writeOffsets(_ offsets: [SpannerOffset], into score: inout Score) {
        for entry in offsets {
            guard case var .spanner(spanner) = score[entry.id] else { continue }
            spanner.nextMeasuresOffset = entry.offset
            score[entry.id] = .spanner(spanner)
        }
    }

    /// The offsets the addresses in `offsets` carry in `score` RIGHT NOW — the pre-image a restore's own inverse
    /// needs. Every such address is anchored before the region, so it names the same slot in either barring.
    static func currentOffsets(for offsets: [SpannerOffset], in score: Score) -> [SpannerOffset] {
        offsets.map { entry in
            guard case let .spanner(spanner) = score[entry.id] else { return entry }
            return SpannerOffset(id: entry.id, offset: spanner.nextMeasuresOffset)
        }
    }

    private static func signatureFraction(_ signature: TimeSignature) -> Fraction {
        Fraction(numerator: signature.numerator, denominator: signature.denominator)
    }

    private static func startTicks(_ durations: [Fraction], division: Int) -> [Int] {
        var starts: [Int] = []
        var total = 0
        for duration in durations {
            starts.append(total)
            total += duration.ticks(division: division)
        }
        return starts
    }

    /// The last column starting at or before `tick` — 0 for a tick before the first one, which a clamped read of
    /// an empty column list also gives.
    private static func column(containing tick: Int, starts: [Int]) -> Int {
        var result = 0
        for (index, start) in starts.enumerated() where start <= tick {
            result = index
        }
        return result
    }
}
