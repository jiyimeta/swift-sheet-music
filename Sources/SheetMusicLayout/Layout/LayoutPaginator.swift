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
    /// renders on the new page, not the previous one).
    ///
    /// Authored `<LayoutBreak>page` on a system's last measure closes the page
    /// immediately under `.honor` / `.ignoreSystemBreaks`; `.ignoreAll` lets
    /// pages keep packing until vertical overflow.
    ///
    /// The frames between systems (`LayoutDocument.frames`) reach the cut through two inputs, which
    /// `LayoutDocument.paginate(pageHeight:policy:)` derives. A system index in `forcedBreaksBefore` starts a page
    /// whatever room is left — the system below a frame whose `pageBreakAfter` is set (MuseScore `pagelayout.cpp:246`);
    /// like a measure's page break it is ignored under `.ignoreAll`, and an index outside `1 ..< systems.count` is
    /// ignored. `contentBottom` is the lowest bottom of the frames after the last system: when it does not fit on the
    /// last page (`contentBottom - pageTop > pageHeight`), one more empty range `systems.count ..< systems.count` is
    /// appended — a page holding only those frames, as MuseScore gives a trailing box that does not fit a page of its
    /// own. The defaults are the cut without frames.
    public static func paginate(
        systems: [LayoutSystem],
        pageHeight: CGFloat,
        policy: LayoutBreakPolicy,
        forcedBreaksBefore: Set<Int> = [],
        contentBottom: CGFloat? = nil,
    ) -> [Range<Int>] {
        guard !systems.isEmpty, pageHeight > 0 else { return [] }
        var pages: [Range<Int>] = []
        var pageStart = 0
        var pageTopDoc: CGFloat = 0

        for (index, system) in systems.enumerated() {
            let systemBottom = system.origin.y + system.size.height
            if index > pageStart, systemBottom - pageTopDoc > pageHeight {
                pages.append(pageStart ..< index)
                pageStart = index
                pageTopDoc = systems[index - 1].origin.y
                    + systems[index - 1].size.height
            }
            if policy != .ignoreAll,
               system.measures.last?.pageBreak == true
            {
                pages.append(pageStart ..< (index + 1))
                pageStart = index + 1
                pageTopDoc = systemBottom
            }
        }
        if pageStart < systems.count {
            pages.append(pageStart ..< systems.count)
        }
        return pages
    }
}
