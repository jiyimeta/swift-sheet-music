import JavaScriptKit
import SheetMusicCore
import SheetMusicFoundation

/// Steps a durable score position by one measure. Direction is strict at this
/// untyped boundary: `0` is backward and `1` is forward.
@JS public func stepMeasureCursor(
    handle: Int,
    measureIndex: Int,
    tickInMeasure: Int,
    direction: Int,
) -> [Double] {
    guard let score = scoreTable.value(for: Int64(handle)),
          resolvesPosition(score: score, measureIndex: measureIndex, tickInMeasure: tickInMeasure),
          direction == 0 || direction == 1
    else { return [] }
    let from = ScoreCursor.beat(measureIndex: measureIndex, tickInMeasure: tickInMeasure)
    let target = score.cursorSteppingMeasure(
        from: from,
        direction: direction == 0 ? .backward : .forward,
    )
    return [Double(target.measureIndex), Double(score.tickInMeasure(of: target))]
}

/// Advances a durable score position by quarter-note beats.
@JS public func cursorAdvancedByBeats(
    handle: Int,
    measureIndex: Int,
    tickInMeasure: Int,
    beats: Double,
) -> [Double] {
    guard beats.isFinite,
          let score = scoreTable.value(for: Int64(handle)),
          resolvesPosition(score: score, measureIndex: measureIndex, tickInMeasure: tickInMeasure)
    else { return [] }
    let from = ScoreCursor.beat(measureIndex: measureIndex, tickInMeasure: tickInMeasure)
    let target = score.cursor(advancedByBeats: beats, from: from)
    return [Double(target.measureIndex), Double(score.tickInMeasure(of: target))]
}

private func resolvesPosition(score: Score, measureIndex: Int, tickInMeasure: Int) -> Bool {
    guard measureIndex >= 0, tickInMeasure >= 0 else { return false }
    let durations = score.effectiveMeasureDurations()
    guard durations.indices.contains(measureIndex) else { return false }
    return tickInMeasure <= durations[measureIndex].ticks(division: score.division)
}
