import SheetMusicFoundation

/// Writes `Measure.startRepeat` and `Measure.endRepeatCount` on one measure column. The flags live on the canonical
/// staff (`Score.canonicalStaff`) the way MuseScore writes them under `writeSystemElements`; the layout generates the
/// repeat barlines from them on every staff. MuseScore's "end-start repeat" palette item is two of these from the
/// host — this measure's end and the next measure's start.
public struct SetRepeatBarLines: EditCommand {
    public let measure: MeasureRef
    public let startRepeat: Bool
    /// Play count for an end repeat, or `nil` for none. MuseScore's default is 2; anything below is not a repeat.
    public let endRepeatCount: Int?

    public init(at measure: MeasureRef, startRepeat: Bool, endRepeatCount: Int?) {
        self.measure = measure
        self.startRepeat = startRepeat
        self.endRepeatCount = endRepeatCount
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(staff: Score.canonicalStaff, measureIndex: measure.measureIndex, voiceIndex: 0, elementIndex: 0)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard var target = score[measure: measure, staff: Score.canonicalStaff] else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        if let endRepeatCount, endRepeatCount < 2 {
            throw Self.refused(.invalidRepeatCount(endRepeatCount))
        }
        let inverse = SetRepeatBarLines(
            at: measure, startRepeat: target.startRepeat, endRepeatCount: target.endRepeatCount,
        )
        target.startRepeat = startRepeat
        target.endRepeatCount = endRepeatCount
        score[measure: measure, staff: Score.canonicalStaff] = target
        return inverse
    }
}
