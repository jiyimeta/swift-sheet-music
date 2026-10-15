import SheetMusicFoundation

extension Score {
    /// `blocks` without the title block — the one `titleFrame` reads (the first `.verticalFrame` with
    /// `beforeMeasureIndex == 0`) — in their stored order. These are the boxes the layout places between systems.
    package var frameStream: [PositionedScoreBlock] {
        guard let titleIndex = blocks.firstIndex(where: { positioned in
            guard positioned.beforeMeasureIndex == 0 else { return false }
            if case .verticalFrame = positioned.block { return true }
            return false
        }) else { return blocks }
        var stream = blocks
        stream.remove(at: titleIndex)
        return stream
    }
}

extension [PreservedXML] {
    /// Whether the bag holds a `LayoutBreak` whose `subtype` child's text is `page`.
    package var hasPageBreak: Bool {
        contains { element in
            element.name == "LayoutBreak"
                && element.children.contains { $0.name == "subtype" && $0.text == "page" }
        }
    }
}
