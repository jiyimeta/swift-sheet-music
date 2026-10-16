#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Splits a laid-out document's flat `systems` array into page ranges for
/// page-mode rendering. Lifted from the iOS `PagedScoreContainer` so iOS and
/// the Android JNI bridge produce identical page boundaries.
///
/// Returns index ranges into the source `systems` array rather than slices,
/// so callers retain efficient random access to document coordinates without
/// copying system values.
public enum LayoutPaginator {
    /// Greedy paginator working in document-Y coordinates. Walks `systems` in
    /// order and closes the current page just before a system whose bottom edge
    /// would extend past `pageTopDoc + pageHeight`. `pageTopDoc` is `0` for the
    /// first page (so the title frame and any pre-system decorations are visible)
    /// and the previous page's last-system bottom for every subsequent page (so
    /// the gap above the new page's first system — where rehearsal marks live —
    /// renders on the new page, not the previous one), or the bottom of the
    /// frames whose page break ended the previous page:
    /// `LayoutDocument.pageTop(ofPageStartingAt:)` of the page's first system.
    ///
    /// Authored `<LayoutBreak>page` on a system's last measure closes the page
    /// immediately under `.honor` / `.ignoreSystemBreaks`; `.ignoreAll` lets
    /// pages keep packing until vertical overflow.
    ///
    /// The frames between systems (`LayoutDocument.frames`) reach the cut through two inputs, which
    /// `LayoutDocument.paginate(pageHeight:policy:)` derives. A system index in `pageBreaksBefore` starts a page
    /// whatever room is left — the system below a frame whose `pageBreakAfter` is set (MuseScore `pagelayout.cpp:246`)
    /// — and its value is the lowest bottom of those frames: the frames stay at the bottom of the page they close, so
    /// that page must hold them under its last system (a system that does not fit with them moves to the next page
    /// with them, unless it is the page's first; MuseScore would move only the frame), and the next page starts at
    /// that bottom rather than at the system's. Like a measure's page break it is ignored under `.ignoreAll`, and an
    /// index outside `1 ..< systems.count` is ignored. `trailingFramesBottom` is the lowest bottom of the frames after
    /// the last system (not the document's content bottom, which is never `nil` and would ask for a page that holds
    /// nothing). One more empty range `systems.count ..< systems.count` — a page holding only those frames — is
    /// appended when they do not fit on the last page (`trailingFramesBottom - pageTop > pageHeight`; MuseScore gives
    /// a trailing box that does not fit a page of its own), and always when an honored page break closed the last
    /// page: the frames come after the break (`pagelayout.cpp:246`), and the page before it has no room reserved for
    /// them. The defaults are the cut without frames.
    public static func paginate(
        systems: [LayoutSystem],
        pageHeight: CGFloat,
        policy: LayoutBreakPolicy,
        pageBreaksBefore: [Int: CGFloat] = [:],
        trailingFramesBottom: CGFloat? = nil,
    ) -> [Range<Int>] {
        guard !systems.isEmpty, pageHeight > 0 else { return [] }
        let forced: [Int: CGFloat] = policy == .ignoreAll
            ? [:]
            : pageBreaksBefore.filter { (1 ..< systems.count).contains($0.key) }
        var pages: [Range<Int>] = []
        var pageStart = 0
        var pageTopDoc: CGFloat = 0
        /// Where the page whose first system is `index` starts: the previous system's bottom, or the bottom of the
        /// frames whose page break comes before `index`, when lower (`LayoutDocument.pageTop(ofPageStartingAt:)`).
        func pageTop(at index: Int) -> CGFloat {
            let previous = systems[index - 1]
            let previousBottom = previous.origin.y + previous.size.height
            return max(previousBottom, forced[index] ?? previousBottom)
        }

        for (index, system) in systems.enumerated() {
            // How far down this system takes its page: to its bottom, or to the frames under it when their page
            // break ends the page there.
            let reach = max(system.origin.y + system.size.height, forced[index + 1] ?? -CGFloat.infinity)
            // `index > pageStart` keeps a page's first system on it, so a forced break at 0 (or right after a page
            // break) adds no empty page.
            if index > pageStart, forced[index] != nil || reach - pageTopDoc > pageHeight {
                pages.append(pageStart ..< index)
                pageStart = index
                pageTopDoc = pageTop(at: index)
            }
            if policy != .ignoreAll,
               system.measures.last?.pageBreak == true
            {
                pages.append(pageStart ..< (index + 1))
                pageStart = index + 1
                // For the last system this is its own bottom: no frame's break is kept past it.
                pageTopDoc = pageTop(at: index + 1)
            }
        }
        // A page break on the last system's last measure has already closed the last page.
        let closedByPageBreak = pageStart == systems.count
        if pageStart < systems.count {
            pages.append(pageStart ..< systems.count)
        }
        if let trailingFramesBottom, closedByPageBreak || trailingFramesBottom - pageTopDoc > pageHeight {
            pages.append(systems.count ..< systems.count)
        }
        return pages
    }
}
