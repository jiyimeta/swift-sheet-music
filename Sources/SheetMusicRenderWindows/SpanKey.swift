import SheetMusicBridgeCore

/// A span's identity across an edit (`ScoreSurface.replaceCommands`): its system, or — for the title block and the
/// frames, which have none — its place among those on the page, in command order. Keyed by the system alone, every
/// unnumbered span shared one key and only the first was compared, so an edited frame's tiles were never redrawn and a
/// frame's picture could stay stale. A frame added or removed before another shifts the later ones' places, which
/// only marks them changed too: a redraw, never a miss.
enum SpanKey: Hashable {
    case system(Int)
    case unnumbered(Int)

    /// `spans` by key; the first of two with one key wins, as the dictionary it replaced kept.
    static func keyed(_ spans: [SystemSpan]) -> [SpanKey: SystemSpan] {
        var keyed: [SpanKey: SystemSpan] = [:]
        var unnumbered = 0
        for span in spans {
            let key: SpanKey
            if let system = span.systemIndex {
                key = .system(system)
            } else {
                key = .unnumbered(unnumbered)
                unnumbered += 1
            }
            if keyed[key] == nil {
                keyed[key] = span
            }
        }
        return keyed
    }
}
