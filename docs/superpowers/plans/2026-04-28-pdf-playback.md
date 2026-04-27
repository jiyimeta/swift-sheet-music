# PDF Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the iOS example's PDF preview mode to playback feature parity with vertical / horizontal modes — playback cursor overlay, two-axis auto-scroll, and tap-to-seek.

**Architecture:** Example-app-only changes. New `PDFCursorOverlay` SwiftUI view wraps each `PDFPageView` to draw the cursor. New per-page and per-system anchor IDs + `PreferenceKey`s feed a `ScrollViewReader`-driven auto-scroll handler that mirrors the existing vertical/horizontal `paddedAnchor` logic. Tap gesture on `PDFPageView` is converted from page-local to doc coords and forwarded to the existing `handleTap` + `ScoreHitTester` pipeline.

**Tech Stack:** Swift 5.10+, SwiftUI, SheetMusicUI / SheetMusicAudio / SheetMusicPDF / SheetMusicCore (existing). Verified by `swift build`, SwiftLint, and `xcodebuild` against an iOS 17 simulator. No automated UI tests (per CLAUDE.md); manual UAT per spec.

**Spec:** `docs/superpowers/specs/2026-04-28-pdf-playback-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Example/SheetMusicExample/AutoScroll.swift` | Modify | Add `PDFPageAnchorID`, `PDFSystemAnchorID`, `PDFPageFramesKey`, `PDFSystemFramesKey`. Co-located with the existing vertical/horizontal anchor scaffolding. |
| `Example/SheetMusicExample/PDFCursorOverlay.swift` | Create | New SwiftUI view: per-page playback cursor that draws only when the cursor's measure lives on that page; doc → page-local coord translation. |
| `Example/SheetMusicExample/PDFSystemAnchors.swift` | Create | New SwiftUI view: per-system invisible anchors inside one page, sized to each system's staff range, emitting frames in `"pdfScroll"`. Vertical analogue of the existing `VerticalSystemAnchors`. |
| `Example/SheetMusicExample/ContentView.swift` | Modify | `pdfPreviewContent`: wrap in `ScrollViewReader`, name coord space `"pdfScroll"`, compose cursor overlay + system anchors + tap gesture per page; add `pdfPageFrames`/`pdfSystemFrames` state; add `autoScrollPDF(...)` handler. |

---

## Task 1: PDF anchor scaffolding

**Files:**
- Modify: `Example/SheetMusicExample/AutoScroll.swift`

- [ ] **Step 1: Add the two anchor identifiers to `AutoScroll.swift`**

Append after the existing `HorizontalMeasureAnchorID` declaration (around line 57):

```swift
/// Identifier for PDF-mode horizontal auto-scroll. One anchor per
/// page, placed at the page's leading X.
struct PDFPageAnchorID: Hashable {
    let pageIndex: Int
}

/// Identifier for PDF-mode vertical auto-scroll inside one page —
/// only meaningful when the user has zoomed in enough that the
/// page exceeds the viewport. One anchor per system per page,
/// keyed by both indices because the same system never appears on
/// two pages but the system's index *within its page* resets to 0
/// each page.
struct PDFSystemAnchorID: Hashable {
    let pageIndex: Int
    let systemIndexInPage: Int
}
```

- [ ] **Step 2: Add the two preference keys to `AutoScroll.swift`**

Append after the existing `HorizontalMeasureFramesKey` declaration:

```swift
/// Per-page frame in the PDF scroll view's named coord space
/// (`"pdfScroll"`). Drives the horizontal "is the active page on
/// screen?" check.
struct PDFPageFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(
        value: inout [Int: CGRect],
        nextValue: () -> [Int: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Per-system frame keyed by `PDFSystemAnchorID`. Used for the
/// vertical auto-scroll within a zoomed-in page.
struct PDFSystemFramesKey: PreferenceKey {
    static var defaultValue: [PDFSystemAnchorID: CGRect] = [:]
    static func reduce(
        value: inout [PDFSystemAnchorID: CGRect],
        nextValue: () -> [PDFSystemAnchorID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
```

- [ ] **Step 3: Verify the package still builds**

Run: `swift build`
Expected: build succeeds with no warnings/errors. (The new types are unused at this point — Swift accepts that for `struct` declarations.)

- [ ] **Step 4: Verify SwiftLint is clean**

Run: `swiftlint --quiet Example/SheetMusicExample`
Expected: no output (zero warnings, zero errors).

- [ ] **Step 5: Commit**

```bash
git add Example/SheetMusicExample/AutoScroll.swift
git commit -m "$(cat <<'EOF'
example: PDF anchor IDs + preference keys for upcoming auto-scroll

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: PDFCursorOverlay view

**Files:**
- Create: `Example/SheetMusicExample/PDFCursorOverlay.swift`

- [ ] **Step 1: Create the cursor overlay view**

Write `Example/SheetMusicExample/PDFCursorOverlay.swift`:

```swift
import SheetMusicCore
import SheetMusicPDF
import SheetMusicUI
import SwiftUI

/// Per-page playback cursor for the PDF preview. Sits in the same
/// `ZStack` slot as one `PDFPageView`, sized to the page so the
/// parent `scaleEffect` zooms it uniformly with the page Canvas.
///
/// Renders nothing unless the cursor's measure lives on this page.
/// That filter is by `measureIndex` — `paginate` never splits a
/// system across pages, so the cursor's full-staff Y span fits
/// entirely inside whichever page hosts its measure.
///
/// Doc → page-local translation: doc coords have origin at the top
/// of page 1's content area; page-local has origin at the top-left
/// of the rendered page rect (including margins). The page's
/// content origin sits at `(margins.leading, margins.top)`, and
/// the page covers doc Y in `[pageStartY, pageStartY + usable)`.
/// So a doc-coord cursor at `(x, y)` lands at
/// `(x + margins.leading, y - pageStartY + margins.top)`
/// in page-local space.
@available(macOS 15.0, iOS 16.0, *)
struct PDFCursorOverlay: View {
    let cursor: ScoreCursor?
    let document: LayoutDocument
    let score: Score
    let pageStartY: CGFloat
    let pageMeasureIndices: Set<Int>
    let margins: PageMargins

    var body: some View {
        if let cursor,
           pageMeasureIndices.contains(cursor.measureIndex),
           let frame = document.cursorFrame(
               for: cursor, in: score) {
            Rectangle()
                .fill(Color.blue.opacity(0.15))
                .frame(width: frame.width, height: frame.height)
                .offset(
                    x: frame.minX + margins.leading,
                    y: frame.minY - pageStartY + margins.top)
                .allowsHitTesting(false)
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: build succeeds with no warnings/errors.

- [ ] **Step 3: Verify SwiftLint**

Run: `swiftlint --quiet Example/SheetMusicExample`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add Example/SheetMusicExample/PDFCursorOverlay.swift
git commit -m "$(cat <<'EOF'
example: PDFCursorOverlay — per-page playback cursor for PDF preview

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: PDFSystemAnchors view

**Files:**
- Create: `Example/SheetMusicExample/PDFSystemAnchors.swift`

- [ ] **Step 1: Create the per-page system anchors view**

Write `Example/SheetMusicExample/PDFSystemAnchors.swift`:

```swift
import SheetMusicCore
import SheetMusicPDF
import SheetMusicUI
import SwiftUI

/// Per-system invisible anchors inside ONE PDF page. Each anchor
/// is sized to the system's staff range (top staff's top → bottom
/// staff's bottom) and positioned at the system's page-local
/// origin via `.offset`. Two jobs:
///
///   * `ScrollViewReader.scrollTo(PDFSystemAnchorID(...), anchor:)`
///     — bring a specific system into the vertical viewport when
///     the user has zoomed in past the point where the page fits.
///   * `PDFSystemFramesKey` preference — report each anchor's live
///     frame in the scroll view's named coord space (`"pdfScroll"`)
///     so the host can no-op when the system is already on screen.
///
/// Sized to the page (`pageSize`) so it composes naturally with
/// `PDFPageView` inside a `ZStack`. The anchors are at absolute
/// page-local positions, not VStack-stacked, because PDF layout
/// already determined exact positions — re-stacking via VStack
/// could disagree with the page Canvas's draw positions.
///
/// **Why `.offset` here is safe (vs `VerticalSystemAnchors` which
/// uses VStack spacers).** Vertical mode needs `scrollTo` to
/// resolve relative to the document; a flat `.offset` would
/// collapse all anchors to the parent origin. Here the parent IS
/// the page rect with absolute size `pageSize`, so each `.offset`
/// child gets a layout frame at the offset position — matching
/// the Canvas's draw coords exactly.
@available(macOS 15.0, iOS 16.0, *)
struct PDFSystemAnchors: View {
    let systems: [LayoutSystem]
    let pageIndex: Int
    let pageStartY: CGFloat
    let margins: PageMargins
    let pageSize: CGSize
    let metrics: StaffMetrics

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<systems.count, id: \.self) { i in
                let sys = systems[i]
                let topY = sys.origin.y
                    + (sys.staffOrigins.first?.y ?? 0)
                let bottomY = sys.origin.y
                    + (sys.staffOrigins.last?.y ?? 0)
                    + metrics.staffHeight
                let height = max(1, bottomY - topY)
                let pageLocalY = topY - pageStartY + margins.top
                let pageLocalX = sys.origin.x + margins.leading
                let id = PDFSystemAnchorID(
                    pageIndex: pageIndex,
                    systemIndexInPage: i)
                Color.clear
                    .frame(
                        width: max(1, sys.size.width),
                        height: height)
                    .id(id)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: PDFSystemFramesKey.self,
                                value: [
                                    id: g.frame(
                                        in: .named("pdfScroll"))
                                ])
                        })
                    .offset(x: pageLocalX, y: pageLocalY)
            }
        }
        .frame(
            width: pageSize.width,
            height: pageSize.height,
            alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: build succeeds with no warnings/errors.

- [ ] **Step 3: Verify SwiftLint**

Run: `swiftlint --quiet Example/SheetMusicExample`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add Example/SheetMusicExample/PDFSystemAnchors.swift
git commit -m "$(cat <<'EOF'
example: PDFSystemAnchors — per-system anchors for PDF auto-scroll

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Wire cursor overlay + tap-to-seek into pdfPreviewContent

**Files:**
- Modify: `Example/SheetMusicExample/ContentView.swift`

- [ ] **Step 1: Thread `score` into `pdfPreviewContent` so the cursor overlay has a non-optional score reference**

In `pdfPreview(score:)` (around line 388), update the call site to pass `score`:

```swift
                pdfPreviewContent(
                    doc: doc, pages: pdfPages,
                    page: resolved.page,
                    score: score)
```

- [ ] **Step 2: Replace the entirety of `pdfPreviewContent` (lines 417–489) with the cursor-aware version**

Replace the whole function with:

```swift
    @ViewBuilder
    private func pdfPreviewContent(
        doc: LayoutDocument,
        pages: [PDFExporter.PageBatch],
        page: EngravingPage,
        score: Score
    ) -> some View {
        let pageSize = page.size
        let pageSpacing: CGFloat = 16 * pdfScale
        let outerPadding: CGFloat = 16 * pdfScale
        let labelHeight: CGFloat = 14 * pdfScale + 6 * pdfScale
        let naturalWidth =
            pageSize.width * pdfScale * CGFloat(pages.count)
            + pageSpacing * CGFloat(max(0, pages.count - 1))
            + outerPadding * 2
        let naturalHeight =
            pageSize.height * pdfScale + labelHeight
            + outerPadding * 2

        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: pageSpacing) {
                ForEach(Array(pages.enumerated()), id: \.offset) { idx, batch in
                    let pageMargins = page.margins(forPageIndex: idx)
                    let measureIndices: Set<Int> = Set(
                        batch.systems.flatMap { sys in
                            sys.measures.map(\.measureIndex)
                        })
                    VStack(spacing: 6 * pdfScale) {
                        // PDFPageView's `renderScale` makes the
                        // Canvas draw glyphs at the new resolution
                        // — vector-sharp instead of an upscaled
                        // bitmap. We only update it on gesture-end
                        // (committed `pdfScale`); during the active
                        // pinch the cheap `scaleEffect` overlay
                        // handles motion smoothly.
                        ZStack(alignment: .topLeading) {
                            PDFPageView(
                                systems: batch.systems,
                                pageStartY: batch.startY,
                                titleFrame: idx == 0 ? doc.titleFrame : nil,
                                metrics: doc.metrics,
                                pageSize: pageSize,
                                margins: pageMargins,
                                renderScale: pdfScale,
                                showBreakIndicators: true)
                            PDFCursorOverlay(
                                cursor: playbackEngine.currentCursor,
                                document: doc,
                                score: score,
                                pageStartY: batch.startY,
                                pageMeasureIndices: measureIndices,
                                margins: pageMargins)
                                .scaleEffect(pdfScale, anchor: .topLeading)
                                .frame(
                                    width: pageSize.width * pdfScale,
                                    height: pageSize.height * pdfScale,
                                    alignment: .topLeading)
                            PDFSystemAnchors(
                                systems: batch.systems,
                                pageIndex: idx,
                                pageStartY: batch.startY,
                                margins: pageMargins,
                                pageSize: pageSize,
                                metrics: doc.metrics)
                                .scaleEffect(pdfScale, anchor: .topLeading)
                                .frame(
                                    width: pageSize.width * pdfScale,
                                    height: pageSize.height * pdfScale,
                                    alignment: .topLeading)
                        }
                        .background(Color.white)
                        .border(Color.gray.opacity(0.4))
                        .shadow(radius: 3 * pdfScale)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            handlePDFTap(
                                at: location,
                                document: doc,
                                pageStartY: batch.startY,
                                margins: pageMargins)
                        }
                        .id(PDFPageAnchorID(pageIndex: idx))
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: PDFPageFramesKey.self,
                                    value: [
                                        idx: g.frame(
                                            in: .named("pdfScroll"))
                                    ])
                            })
                        Text("\(idx + 1) / \(pages.count)")
                            .font(.system(size: 11 * pdfScale))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(outerPadding)
            // Apply the gesture overlay AFTER padding so the whole
            // page deck zooms uniformly. `scaleEffect` is visual-
            // only; the explicit frame tells the parent ScrollView
            // the scaled extent so it can scroll the full zoomed
            // area during the gesture.
            .scaleEffect(pdfGestureScale, anchor: .topLeading)
            .frame(
                width: naturalWidth * pdfGestureScale,
                height: naturalHeight * pdfGestureScale,
                alignment: .topLeading)
        }
        .background(Color(white: 0.92))
        .gesture(
            MagnificationGesture()
                .onChanged { rawValue in
                    let target = pdfScale * rawValue
                    let clamped = max(0.25, min(4.0, target))
                    pdfGestureScale = clamped / pdfScale
                }
                .onEnded { _ in
                    pdfScale = max(
                        0.25, min(4.0, pdfScale * pdfGestureScale))
                    pdfGestureScale = 1
                })
    }
```

Functional additions vs the original:
1. New `score: Score` parameter (call site updated in Step 1).
2. `let pageMargins` and `let measureIndices` hoisted for reuse.
3. The `PDFPageView` is wrapped in a `ZStack` with `PDFCursorOverlay` and `PDFSystemAnchors` siblings, both `scaleEffect`-matched to `PDFPageView`'s rendered size.
4. The page cell carries `.id(PDFPageAnchorID(...))` and emits its frame via `PDFPageFramesKey`.
5. `.contentShape(Rectangle())` + `.onTapGesture { location in handlePDFTap(...) }` adds tap-to-seek; `MagnificationGesture` still wins during pinch.

The `ScrollViewReader` and `coordinateSpace(name: "pdfScroll")` are NOT yet in this body — they're added in Task 5 with their `onPreferenceChange` / `onChange` handlers, so the preferences emitted by this step are simply ignored until then.

- [ ] **Step 3: Add the `handlePDFTap` helper to `ContentView`**

Append immediately after the existing `handleTap(at:document:)` method (around line 538):

```swift
    /// Tap-to-seek for PDF preview pages. Converts the page-local
    /// tap location to doc coords (the same space `handleTap`
    /// expects) and forwards. The Canvas inside `PDFPageView`
    /// renders at `pdfScale`, so the gesture's reported `location`
    /// is in scaled page-local space — undo that here so the
    /// hit-tester sees doc-coord units regardless of zoom.
    private func handlePDFTap(
        at location: CGPoint,
        document: LayoutDocument,
        pageStartY: CGFloat,
        margins: PageMargins
    ) {
        let scale = max(0.0001, pdfScale)
        let docPoint = CGPoint(
            x: location.x / scale - margins.leading,
            y: location.y / scale - margins.top + pageStartY)
        handleTap(at: docPoint, document: document)
    }
```

- [ ] **Step 4: Add the new `@State`s for PDF auto-scroll bookkeeping**

In `ContentView`, alongside the existing state declarations (around line 36–71), add:

```swift
    @State private var pdfPageFrames: [Int: CGRect] = [:]
    @State private var pdfSystemFrames: [PDFSystemAnchorID: CGRect] = [:]
```

Place them after `horizontalMeasureFrames` so the visual grouping with the other auto-scroll state stays consistent.

- [ ] **Step 5: Verify the package + example still build**

Run: `swift build`
Expected: success.

Run: `cd Example && xcodegen generate && cd ..`
Expected: `Example/SheetMusicExample.xcodeproj` regenerated.

Run: `xcodebuild -project Example/SheetMusicExample.xcodeproj -scheme SheetMusicExample -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet`
Expected: `** BUILD SUCCEEDED **`. (No `BUILD FAILED`. Warning lines are okay only if the count matches the prior build — note any new warnings.)

- [ ] **Step 6: Verify SwiftLint**

Run: `swiftlint --quiet Sources Tests Example/SheetMusicExample`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add Example/SheetMusicExample/ContentView.swift
git commit -m "$(cat <<'EOF'
example: PDF preview — playback cursor overlay + tap-to-seek

Cursor draws on the active page only (filtered by measure index).
Tap forwards to the existing handleTap pipeline after page → doc
coord translation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Auto-scroll handler + ScrollViewReader / GeometryReader plumbing

**Files:**
- Modify: `Example/SheetMusicExample/ContentView.swift`

- [ ] **Step 1: Wrap `pdfPreviewContent`'s body in `GeometryReader` + `ScrollViewReader`, name the coord space, and wire the handlers**

In `pdfPreviewContent`, replace the function body (everything between the opening `{` and closing `}` of the function) with the structure below. Only the outermost wrapping changes — the inner `HStack { ... }` and its decorations stay as written in Task 4.

```swift
    @ViewBuilder
    private func pdfPreviewContent(
        doc: LayoutDocument,
        pages: [PDFExporter.PageBatch],
        page: EngravingPage,
        score: Score
    ) -> some View {
        let pageSize = page.size
        let pageSpacing: CGFloat = 16 * pdfScale
        let outerPadding: CGFloat = 16 * pdfScale
        let labelHeight: CGFloat = 14 * pdfScale + 6 * pdfScale
        let naturalWidth =
            pageSize.width * pdfScale * CGFloat(pages.count)
            + pageSpacing * CGFloat(max(0, pages.count - 1))
            + outerPadding * 2
        let naturalHeight =
            pageSize.height * pdfScale + labelHeight
            + outerPadding * 2

        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: pageSpacing) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { idx, batch in
                            let pageMargins = page.margins(forPageIndex: idx)
                            let measureIndices: Set<Int> = Set(
                                batch.systems.flatMap { sys in
                                    sys.measures.map(\.measureIndex)
                                })
                            VStack(spacing: 6 * pdfScale) {
                                ZStack(alignment: .topLeading) {
                                    PDFPageView(
                                        systems: batch.systems,
                                        pageStartY: batch.startY,
                                        titleFrame: idx == 0 ? doc.titleFrame : nil,
                                        metrics: doc.metrics,
                                        pageSize: pageSize,
                                        margins: pageMargins,
                                        renderScale: pdfScale,
                                        showBreakIndicators: true)
                                    PDFCursorOverlay(
                                        cursor: playbackEngine.currentCursor,
                                        document: doc,
                                        score: score,
                                        pageStartY: batch.startY,
                                        pageMeasureIndices: measureIndices,
                                        margins: pageMargins)
                                        .scaleEffect(pdfScale, anchor: .topLeading)
                                        .frame(
                                            width: pageSize.width * pdfScale,
                                            height: pageSize.height * pdfScale,
                                            alignment: .topLeading)
                                    PDFSystemAnchors(
                                        systems: batch.systems,
                                        pageIndex: idx,
                                        pageStartY: batch.startY,
                                        margins: pageMargins,
                                        pageSize: pageSize,
                                        metrics: doc.metrics)
                                        .scaleEffect(pdfScale, anchor: .topLeading)
                                        .frame(
                                            width: pageSize.width * pdfScale,
                                            height: pageSize.height * pdfScale,
                                            alignment: .topLeading)
                                }
                                .background(Color.white)
                                .border(Color.gray.opacity(0.4))
                                .shadow(radius: 3 * pdfScale)
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    handlePDFTap(
                                        at: location,
                                        document: doc,
                                        pageStartY: batch.startY,
                                        margins: pageMargins)
                                }
                                .id(PDFPageAnchorID(pageIndex: idx))
                                .background(
                                    GeometryReader { g in
                                        Color.clear.preference(
                                            key: PDFPageFramesKey.self,
                                            value: [
                                                idx: g.frame(
                                                    in: .named("pdfScroll"))
                                            ])
                                    })
                                Text("\(idx + 1) / \(pages.count)")
                                    .font(.system(size: 11 * pdfScale))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(outerPadding)
                    .scaleEffect(pdfGestureScale, anchor: .topLeading)
                    .frame(
                        width: naturalWidth * pdfGestureScale,
                        height: naturalHeight * pdfGestureScale,
                        alignment: .topLeading)
                }
                .coordinateSpace(name: "pdfScroll")
                .onPreferenceChange(PDFPageFramesKey.self) { f in
                    pdfPageFrames = f
                }
                .onPreferenceChange(PDFSystemFramesKey.self) { f in
                    pdfSystemFrames = f
                }
                .onChange(of: playbackEngine.currentCursor) { newCursor in
                    autoScrollPDF(
                        cursor: newCursor,
                        pages: pages,
                        viewport: geo.size,
                        proxy: proxy)
                }
                .background(Color(white: 0.92))
                .gesture(
                    MagnificationGesture()
                        .onChanged { rawValue in
                            let target = pdfScale * rawValue
                            let clamped = max(0.25, min(4.0, target))
                            pdfGestureScale = clamped / pdfScale
                        }
                        .onEnded { _ in
                            pdfScale = max(
                                0.25, min(4.0, pdfScale * pdfGestureScale))
                            pdfGestureScale = 1
                        })
            }
        }
    }
```

- [ ] **Step 2: Add the `autoScrollPDF` handler**

Append immediately after the existing `autoScroll(cursor:doc:score:axis:viewport:proxy:)` method (around line 632):

```swift
    /// Two-axis auto-scroll for PDF preview. Mirrors the
    /// vertical/horizontal handlers but drives both axes from
    /// one cursor change:
    ///
    ///   * Horizontal: bring the active page into the X viewport
    ///     if the page isn't fully visible.
    ///   * Vertical: at zoom levels where the active system
    ///     overruns the Y viewport, bring it into view.
    ///
    /// Visibility uses each anchor's live frame in `"pdfScroll"`,
    /// reported via `PDFPageFramesKey` / `PDFSystemFramesKey`.
    /// Padding is `8 sp` per `paddedAnchor`, scaled by the
    /// committed `pdfScale` since the anchors live in already-
    /// scaled space.
    private func autoScrollPDF(
        cursor: ScoreCursor?,
        pages: [PDFExporter.PageBatch],
        viewport: CGSize,
        proxy: ScrollViewProxy
    ) {
        guard playbackEngine.state == .playing,
              let cursor,
              let doc = pdfDoc
        else { return }
        let mi = cursor.measureIndex

        // Resolve which page hosts the cursor's measure.
        guard let pageIdx = pages.firstIndex(where: { batch in
            batch.systems.contains { sys in
                sys.measures.contains { $0.measureIndex == mi }
            }
        }) else { return }

        // Resolve which system within that page hosts the cursor
        // — needed for vertical scroll when zoomed in.
        let pageSystems = pages[pageIdx].systems
        guard let systemInPage = pageSystems.firstIndex(where: { sys in
            sys.measures.contains { $0.measureIndex == mi }
        }) else { return }

        let pad: CGFloat = 8 * doc.metrics.sp * pdfScale

        // Horizontal: page into the viewport.
        if let pageFrame = pdfPageFrames[pageIdx] {
            if !isFullyVisible(
                anchorMin: pageFrame.minX,
                anchorMax: pageFrame.maxX,
                anchorSize: pageFrame.width,
                viewportSize: viewport.width)
            {
                let unit = paddedAnchor(
                    aboveViewport: pageFrame.minX < 0,
                    anchorSize: pageFrame.width,
                    viewportSize: viewport.width,
                    pad: pad,
                    horizontal: true)
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(
                        PDFPageAnchorID(pageIndex: pageIdx),
                        anchor: unit)
                }
            }
        }

        // Vertical: system into the viewport. Skip silently if
        // the system frame hasn't been reported yet — the next
        // cursor tick will catch it.
        let sysID = PDFSystemAnchorID(
            pageIndex: pageIdx,
            systemIndexInPage: systemInPage)
        if let sysFrame = pdfSystemFrames[sysID] {
            if !isFullyVisible(
                anchorMin: sysFrame.minY,
                anchorMax: sysFrame.maxY,
                anchorSize: sysFrame.height,
                viewportSize: viewport.height)
            {
                let unit = paddedAnchor(
                    aboveViewport: sysFrame.minY < 0,
                    anchorSize: sysFrame.height,
                    viewportSize: viewport.height,
                    pad: pad,
                    horizontal: false)
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(sysID, anchor: unit)
                }
            }
        }
    }
```

- [ ] **Step 3: Verify it builds**

Run: `swift build`
Expected: success.

Run: `cd Example && xcodegen generate && cd ..`
Expected: project regenerated.

Run: `xcodebuild -project Example/SheetMusicExample.xcodeproj -scheme SheetMusicExample -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Verify SwiftLint**

Run: `swiftlint --quiet Sources Tests Example/SheetMusicExample`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add Example/SheetMusicExample/ContentView.swift
git commit -m "$(cat <<'EOF'
example: PDF preview — two-axis auto-scroll during playback

Page-level horizontal auto-scroll always; per-system vertical
auto-scroll engages when the page exceeds the viewport (zoomed in).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Manual UAT + final lint

**Files:** none (verification only).

- [ ] **Step 1: Boot the example on simulator**

```bash
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' \
           build -quiet
```

Then launch via Xcode (`open Example/SheetMusicExample.xcodeproj`) and run on iPhone 17 simulator. The bundled `test.mscx` loads automatically.

- [ ] **Step 2: UAT 1 — cursor on active page**

Switch to PDF mode (rightmost layout segment). Hit play. Confirm:
- Blue translucent cursor appears on whichever page hosts the active chord.
- Cursor advances chord-by-chord across the system; jumps cleanly to the next page when the system changes.
- Cursor does NOT appear on inactive pages.

- [ ] **Step 3: UAT 2 — horizontal auto-scroll**

With playback running and zoom at default (`pdfScale = 1`), let playback cross a page boundary. Confirm the next page slides into the horizontal viewport with a short ease-in-out animation.

- [ ] **Step 4: UAT 3 — vertical auto-scroll under pinch zoom**

Pause. Pinch to zoom in until one page is taller than the viewport. Resume play from a measure that falls in the lower half of a page. Confirm the system scrolls vertically into view.

- [ ] **Step 5: UAT 4 — tap-to-seek while playing**

While playing, tap a note on a page that's not the active one. Confirm:
- Audio jumps to that note.
- On the next cursor tick, the page (and the new measure) scrolls into view per the auto-scroll path.

- [ ] **Step 6: UAT 5 — tap-to-select while paused**

Stop playback. Tap a note. Confirm:
- The note shows the blue selection highlight (same as vertical/horizontal modes).
- A short MuseScore-style preview tone fires.

- [ ] **Step 7: UAT 6 — no taps fire mid-pinch**

Start a pinch gesture and, mid-pinch, lift one finger to a single-touch position over a note. Confirm no seek/preview fires (the magnification gesture wins).

- [ ] **Step 8: UAT 7 — score swap during playback**

Open file picker, choose a different `.mscx` / `.mscz`. Confirm:
- The PDF view re-lays out cleanly.
- No stale cursor / overlay from the previous score.
- Hitting play on the new score works.

- [ ] **Step 9: Final lint sweep**

Run: `swiftlint --quiet Sources Tests Example/SheetMusicExample`
Expected: no output.

- [ ] **Step 10: Final test sweep**

Run: `swift test`
Expected: 48 tests pass, 12 suites green (per CLAUDE.md baseline).

- [ ] **Step 11: No commit**

UAT only — no code changes. If any UAT step fails, return to the relevant task and patch.
