@WireFormatChoice
enum ScoreCursorWire {
    case item(ScoreItemIDWire)
    case beat(measureIndex: Int32, tickInMeasure: Int32)
}
