import Foundation

extension Score {
    /// One entry in a part's instrument timeline: the position from
    /// which `instrument` is in force.
    ///
    /// Deliberately measure-relative rather than an absolute tick.
    /// Consumers convert with THEIR OWN measure tick bases —
    /// `MidiRenderer` counts breath pauses toward a bar's budget
    /// (`MidiRenderer.measureTicks`) while a plain duration sum does
    /// not, and two walkers that disagree by a tick put notes on the
    /// wrong instrument.
    public struct InstrumentChangePoint: Sendable, Equatable {
        public let measureIndex: Int
        public let position: MeasurePosition
        public let instrument: Instrument

        public init(
            measureIndex: Int,
            position: MeasurePosition,
            instrument: Instrument,
        ) {
            self.measureIndex = measureIndex
            self.position = position
            self.instrument = instrument
        }
    }

    /// The ordered instruments in force across `partIndex`, seeded with
    /// the part-level instrument at measure 0 / offset 0.
    ///
    /// Derived on every call — no tick map is stored on `Part`. This
    /// mirrors how `Tempo` lives only as a system element with
    /// `TempoTimeline.build` providing the time-keyed view; a stored map
    /// would be a second source of truth that drifts under edits.
    ///
    /// Scope is the **part**: a change written on staff 1 of a grand
    /// staff re-instruments the whole part, so the lookup keys on
    /// `originalStaff.partIndex` and ignores `staffIndexInPart`. A
    /// change whose `instrument` is nil (text-only placeholder)
    /// contributes no point.
    ///
    /// Preserves each measure's element order rather than re-sorting by
    /// `position` — this assumes callers supply position-sorted
    /// `SystemMeasure.elements`, as both the MSCX and MusicXML decoders
    /// do. A hand-built `Score` with out-of-position elements in a
    /// single measure will come back with a mis-ordered timeline.
    public func instrumentTimeline(
        forPart partIndex: Int,
    ) -> [InstrumentChangePoint] {
        guard parts.indices.contains(partIndex) else { return [] }
        var points = [InstrumentChangePoint(
            measureIndex: 0,
            position: MeasurePosition(
                offset: Fraction(numerator: 0, denominator: 1),
            ),
            instrument: parts[partIndex].instrument,
        )]
        for (measureIndex, measure) in systemMeasures.enumerated() {
            for positioned in measure.elements {
                guard case let .instrumentChange(change) = positioned.element,
                      let instrument = change.instrument,
                      positioned.originalStaff?.partIndex == partIndex
                else { continue }
                points.append(InstrumentChangePoint(
                    measureIndex: measureIndex,
                    position: positioned.position,
                    instrument: instrument,
                ))
            }
        }
        // `systemMeasures` is walked in index order and each measure's
        // elements are already position-sorted by the decoders, so the
        // result is in time order without a re-sort.
        return points
    }
}
