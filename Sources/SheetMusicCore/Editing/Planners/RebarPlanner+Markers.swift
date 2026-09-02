import SheetMusicFoundation

/// Rule 7 — where a barline marker goes when the barlines move.
///
/// A repeat sign, a `Marker` / `Jump`, or a special barline means something only ON a barline: it names the
/// place the music jumps to or from. So each one re-homes onto the new column boundary at its own tick, and
/// when the new grid has no boundary there the whole region is refused rather than have the marker slide
/// silently onto a bar it never belonged to.
///
/// Layout breaks are the deliberate exception. A line or page break is a typesetting hint, not a navigation
/// landmark, and re-barring an imported score would otherwise refuse on every one of them — so those land on
/// the column that holds their tick and nothing is refused.
extension RebarPlanner {
    static func rehome(
        barLines: [BarLineMarker], into columns: inout [Measure], geometry: Geometry,
    ) throws {
        for marker in barLines {
            // A barline written at the run's own start opens the first column — nothing has moved under it.
            if marker.tick <= 0 {
                insert(marker.element, atHeadOf: &columns[0])
                continue
            }
            guard let column = geometry.columnForEnd(marker.tick) else {
                throw refused(.rebarWouldDisplaceBarlineMarker(measureIndex: marker.measureIndex))
            }
            append(marker.element, toTailOf: &columns[column])
        }
    }

    static func rehomeMeasureProperties(
        of staff: Staff, into columns: inout [Measure], geometry: Geometry,
    ) throws {
        for (offset, measureIndex) in geometry.run.enumerated() {
            guard staff.measures.indices.contains(measureIndex) else { continue }
            let source = staff.measures[measureIndex]
            let start = geometry.measureStarts[offset]
            try applyStartAnchored(
                source, measureIndex: measureIndex, tick: start, into: &columns, geometry: geometry,
            )
            try applyEndAnchored(
                source, measureIndex: measureIndex, tick: start + geometry.measureTicks[offset],
                into: &columns, geometry: geometry,
            )
        }
    }

    /// What a bar declares at its LEFT edge: the start repeat, and the `Marker`s (Segno, Coda, …) a jump
    /// aims at.
    private static func applyStartAnchored(
        _ source: Measure, measureIndex: Int, tick: Int,
        into columns: inout [Measure], geometry: Geometry,
    ) throws {
        let exact = geometry.columnForStart(tick)
        let carriesMarker = source.startRepeat || !source.markers.isEmpty
        if carriesMarker, exact == nil {
            throw refused(.rebarWouldDisplaceBarlineMarker(measureIndex: measureIndex))
        }
        let column = exact ?? geometry.column(containing: tick)
        columns[column].startRepeat = columns[column].startRepeat || source.startRepeat
        columns[column].markers.append(contentsOf: source.markers)
        if let count = source.measureRepeatCount { columns[column].measureRepeatCount = count }
        columns[column].irregular = columns[column].irregular || source.irregular
    }

    /// What a bar declares at its RIGHT edge: the end repeat, and the `Jump`s (D.C., D.S., …) that leave it.
    private static func applyEndAnchored(
        _ source: Measure, measureIndex: Int, tick: Int,
        into columns: inout [Measure], geometry: Geometry,
    ) throws {
        let exact = geometry.columnForEnd(tick)
        let carriesMarker = source.endRepeatCount != nil || !source.jumps.isEmpty
        if carriesMarker, exact == nil {
            throw refused(.rebarWouldDisplaceBarlineMarker(measureIndex: measureIndex))
        }
        let column = exact ?? geometry.column(containing: max(tick - 1, 0))
        columns[column].endRepeatCount = source.endRepeatCount ?? columns[column].endRepeatCount
        columns[column].jumps.append(contentsOf: source.jumps)
        columns[column].lineBreak = columns[column].lineBreak || source.lineBreak
        columns[column].pageBreak = columns[column].pageBreak || source.pageBreak
        columns[column].sectionBreak = columns[column].sectionBreak || source.sectionBreak
    }

    /// A `.barLine` element rides in voice 0 — after the bar's signatures at the head, or after everything
    /// at the tail, which is where the decoder reads one from and the encoder writes it back to.
    private static func insert(_ element: VoiceElement, atHeadOf measure: inout Measure) {
        guard !measure.voices.isEmpty else { return }
        let prefix = MeasureStructure.leadingSignaturePrefix(of: measure.voices[0]).count
        measure.voices[0].elements.insert(element, at: prefix)
        MeasureStructure.shiftTuplets(in: &measure.voices[0], by: 1)
    }

    private static func append(_ element: VoiceElement, toTailOf measure: inout Measure) {
        guard !measure.voices.isEmpty else { return }
        measure.voices[0].elements.append(element)
    }
}

extension RebarPlanner.Geometry {
    /// The column that STARTS at `tick`, or nil when the new grid has no barline there.
    func columnForStart(_ tick: Int) -> Int? {
        guard tick >= 0, tick % newTicks == 0 else { return nil }
        let column = tick / newTicks
        return column < columnCount ? column : nil
    }

    /// The column that ENDS at `tick`, or nil when the new grid has no barline there. The run's own end
    /// counts even when the last column is padded past it: the region's closing barline stays its closing
    /// barline.
    func columnForEnd(_ tick: Int) -> Int? {
        if tick == totalTicks { return columnCount - 1 }
        guard tick > 0, tick % newTicks == 0 else { return nil }
        let column = tick / newTicks - 1
        return column < columnCount ? column : nil
    }
}
