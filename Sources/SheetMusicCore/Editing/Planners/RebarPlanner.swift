import SheetMusicFoundation

/// Re-partitions one measure region into bars of a new nominal duration. Pure planning: it reads the score,
/// returns the replacement columns, and mutates nothing — `SetTimeSignature` is what writes them back.
///
/// The region is cut into RUNS of regular bars separated by irregular ones (`actualLength != nil`, i.e. a
/// pickup or a deliberately short bar). An irregular column passes through verbatim and each run either side
/// of it is re-barred on its own, because a bar that declares its own length is not the meter's to re-spell.
///
/// Inside a run everything is measured in absolute ticks from the run's start, per staff and per voice, so
/// the new barring is a pure re-partition of one tick stream: a chord that outlasts its new bar comes out as
/// a beat-aligned tied chain (`DurationChangeAlgorithm`), a tuplet is indivisible, and a barline marker only
/// survives if the new grid still has a barline where it sits.
enum RebarPlanner {
    struct Rebarred {
        /// The region's replacement, one entry per NEW measure column, `systemMeasure` included (elements
        /// re-homed by absolute tick). Column count may differ from the region's old count.
        var columns: [MeasureSlice]
    }

    /// `region` is [firstMeasure, endMeasure) in current measure indices. `numerator`/`denominator` are the
    /// new nominal signature.
    ///
    /// With `emitsLeadingSignature` the first REGULAR column's voice-0 prefix declares the new meter on every
    /// staff; without it nothing is declared at all — the shape `RemoveTimeSignature` needs, where the region
    /// re-bars to the meter it inherits and must be left carrying no explicit signature of its own. Either
    /// way every `.timeSignature` already inside a re-barred run is dropped.
    static func rebar(
        region: Range<Int>, in score: Score, numerator: Int, denominator: Int,
        emitsLeadingSignature: Bool = true,
    ) throws -> Rebarred {
        let measureCount = MeasureStructure.measureCount(of: score)
        let newDuration = Fraction(numerator: numerator, denominator: denominator)
        let newTicks = newDuration.ticks(division: score.division)
        guard !region.isEmpty, region.lowerBound >= 0, region.upperBound <= measureCount,
              !score.parts.isEmpty, newTicks > 0
        else { throw refused(.targetNotFound(location(measureIndex: max(region.lowerBound, 0)))) }

        var columns: [MeasureSlice] = []
        var pendingSignature = emitsLeadingSignature
            ? TimeSignature(numerator: numerator, denominator: denominator)
            : nil
        for run in runs(in: region, of: score) {
            switch run {
            case let .irregular(measureIndex):
                columns.append(verbatimColumn(at: measureIndex, of: score))
            case let .regular(range):
                var produced = try rebar(run: range, of: score, newTicks: newTicks)
                if let signature = pendingSignature, !produced.isEmpty {
                    declare(signature, in: &produced[0])
                    pendingSignature = nil
                }
                columns.append(contentsOf: produced)
            }
        }
        return Rebarred(columns: columns)
    }

    static func refused(_ reason: EditRefusal.Reason) -> SheetMusicError {
        .invalidEdit(EditRefusal(operation: "RebarPlanner", reason: reason))
    }

    private static func location(measureIndex: Int) -> VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    // MARK: - Runs

    private enum Run {
        case irregular(Int)
        case regular(Range<Int>)
    }

    /// The region cut at every irregular bar. An irregular bar is one whose length is its own on ANY staff:
    /// re-barring it would contradict the `actualLength` it declares.
    private static func runs(in region: Range<Int>, of score: Score) -> [Run] {
        var result: [Run] = []
        var runStart = region.lowerBound
        for measureIndex in region where isIrregular(measureIndex, in: score) {
            if runStart < measureIndex { result.append(.regular(runStart ..< measureIndex)) }
            result.append(.irregular(measureIndex))
            runStart = measureIndex + 1
        }
        if runStart < region.upperBound { result.append(.regular(runStart ..< region.upperBound)) }
        return result
    }

    private static func isIrregular(_ measureIndex: Int, in score: Score) -> Bool {
        score.parts.contains { part in
            part.staves.contains { staff in
                staff.measures.indices.contains(measureIndex)
                    && staff.measures[measureIndex].actualLength != nil
            }
        }
    }

    private static func verbatimColumn(at measureIndex: Int, of score: Score) -> MeasureSlice {
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

    /// Writes `signature` into every staff's voice-0 leading-signature run, after whatever clef and key that
    /// bar already carries — MuseScore's structural order, the same one `MeasureStructure` merges into.
    private static func declare(_ signature: TimeSignature, in column: inout MeasureSlice) {
        for partIndex in column.staffMeasures.indices {
            for staffIndex in column.staffMeasures[partIndex].indices {
                guard !column.staffMeasures[partIndex][staffIndex].voices.isEmpty else { continue }
                var voice = column.staffMeasures[partIndex][staffIndex].voices[0]
                let prefix = MeasureStructure.leadingSignaturePrefix(of: voice).count
                voice.elements.insert(.timeSignature(signature), at: prefix)
                // Every tuplet in a re-barred bar spans chords, so all of them sit past the prefix.
                MeasureStructure.shiftTuplets(in: &voice, by: 1)
                column.staffMeasures[partIndex][staffIndex].voices[0] = voice
            }
        }
    }

    // MARK: - One regular run

    private static func rebar(run: Range<Int>, of score: Score, newTicks: Int) throws -> [MeasureSlice] {
        let geometry = geometry(run: run, score: score, newTicks: newTicks)
        assertStavesAgree(on: geometry, in: score)
        var staffColumns: [[[Measure]]] = []
        for part in score.parts {
            var perStaff: [[Measure]] = []
            for staff in part.staves {
                try perStaff.append(measures(of: staff, geometry: geometry))
            }
            staffColumns.append(perStaff)
        }
        let lanes = systemMeasures(of: score, geometry: geometry)
        return (0 ..< geometry.columnCount).map { column in
            MeasureSlice(
                staffMeasures: staffColumns.map { part in part.map { $0[column] } },
                systemMeasure: lanes[column],
            )
        }
    }

    /// Where each old bar of the run starts, how long it is, and how many new columns the run's ticks fill.
    ///
    /// Read from part 0 / staff 0: a time signature is score-wide in this model and a run carries no
    /// `actualLength`, so every staff measures the same run the same way. `assertStavesAgree` states that.
    private static func geometry(run: Range<Int>, score: Score, newTicks: Int) -> Geometry {
        let durations = score.effectiveMeasureDurations()
        var starts: [Int] = []
        var fractions: [Fraction] = []
        var ticks: [Int] = []
        var total = 0
        for measureIndex in run {
            let duration = durations.indices.contains(measureIndex)
                ? durations[measureIndex] : Fraction(numerator: 4, denominator: 4)
            starts.append(total)
            fractions.append(duration)
            let measureTicks = duration.ticks(division: score.division)
            ticks.append(measureTicks)
            total += measureTicks
        }
        return Geometry(
            run: run,
            division: score.division,
            newTicks: newTicks,
            columnCount: max(1, (total + newTicks - 1) / newTicks),
            totalTicks: total,
            measureStarts: starts,
            measureDurations: fractions,
            measureTicks: ticks,
        )
    }

    /// Rule 9: every staff must produce the same number of columns. It does by construction — same nominal
    /// durations, same run ticks — so this is a DEBUG statement of the invariant, not a runtime check.
    private static func assertStavesAgree(on geometry: Geometry, in score: Score) {
        #if DEBUG
            for (partIndex, part) in score.parts.enumerated() {
                for staffIndex in part.staves.indices {
                    let durations = score.effectiveMeasureDurations(
                        partIndex: partIndex, staffIndex: staffIndex,
                    )
                    let total = geometry.run.reduce(0) { sum, measureIndex in
                        sum + (durations.indices.contains(measureIndex)
                            ? durations[measureIndex].ticks(division: geometry.division) : 0)
                    }
                    assert(
                        total == geometry.totalTicks,
                        "RebarPlanner: staff \(partIndex)/\(staffIndex) spans \(total) ticks, "
                            + "not the run's \(geometry.totalTicks)",
                    )
                }
            }
        #endif
    }

    // MARK: - One staff

    private static func measures(of staff: Staff, geometry: Geometry) throws -> [Measure] {
        var emitters: [VoiceEmitter] = []
        var barLines: [BarLineMarker] = []
        for voiceIndex in 0 ..< voiceCount(of: staff, geometry: geometry) {
            let flat = flatten(voiceIndex: voiceIndex, in: staff, geometry: geometry)
            var emitter = VoiceEmitter(geometry: geometry, voiceIndex: voiceIndex)
            try emitter.place(flat.items)
            emitter.pad()
            emitters.append(emitter)
            barLines.append(contentsOf: flat.barLines)
        }
        var built = (0 ..< geometry.columnCount).map { column in
            Measure(voices: voices(from: emitters, column: column))
        }
        try rehome(barLines: barLines, into: &built, geometry: geometry)
        try rehomeMeasureProperties(of: staff, into: &built, geometry: geometry)
        return built
    }

    private static func voiceCount(of staff: Staff, geometry: Geometry) -> Int {
        let counts = geometry.run.compactMap { measureIndex in
            staff.measures.indices.contains(measureIndex) ? staff.measures[measureIndex].voices.count : nil
        }
        return max(1, counts.max() ?? 1)
    }

    /// Voice 0 is always written; a higher voice appears only where the run actually put something in it, so
    /// a bar that is pure gap for that voice simply doesn't declare it. Interior holes keep the array dense
    /// (voice index is positional); trailing empties are trimmed away.
    private static func voices(from emitters: [VoiceEmitter], column: Int) -> [Voice] {
        var result = emitters.map { $0.voice(forColumn: column) ?? Voice(elements: []) }
        while result.count > 1, let last = result.last, last.elements.isEmpty, last.tuplets.isEmpty {
            result.removeLast()
        }
        return result
    }

    // MARK: - System lane

    private static func systemMeasures(of score: Score, geometry: Geometry) -> [SystemMeasure] {
        var lanes = Array(repeating: SystemMeasure(), count: geometry.columnCount)
        for (offset, measureIndex) in geometry.run.enumerated() {
            guard score.systemMeasures.indices.contains(measureIndex) else { continue }
            for positioned in score.systemMeasures[measureIndex].elements {
                let tick = geometry.measureStarts[offset]
                    + positioned.position.ticks(division: geometry.division)
                let column = geometry.column(containing: tick)
                var moved = positioned
                moved.position = MeasurePosition(
                    offset: geometry.fraction(ofTicks: tick - geometry.columnStart(column)),
                )
                lanes[column].elements.append(moved)
            }
        }
        return lanes
    }
}
