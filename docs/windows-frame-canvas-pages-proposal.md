# 4.38.0: the frame canvas paints a score's pages, clips, and composites a picture at an opacity (Windows)

Date: 2026-11-14
Status: approved by the owner (2026-11-14, the three items below); implemented on branch
`windows-frame-canvas-pages`, Windows tests pending.
Consumer: folino's Windows score video export, slice 2 (the frame drawer).
folino spec: `2026-11-13-windows-score-video-export-design.md` §6, §9; follows `windows-frame-canvas-proposal.md`
(4.37.0).

## Why

4.37.0's `Direct2DFrameCanvas.paint(_ commands:)` takes `DrawCommand`s, but a host cannot get any: `ScorePages` keeps
its pages' commands and their system spans `package` ("the pages themselves stay inside the package"). So the canvas
can draw overlays but not the score. A score video's frame also needs what the Apple drawer does with Core Graphics
and the canvas cannot: each pane is clipped to where it lands on the frame, and the folino wordmark is composited at
one opacity over the whole mark.

## 1. `Direct2DFrameCanvas.paint(_ pages: ScorePages, …)` (public)

```swift
extension Direct2DFrameCanvas {
    /// Paints page `page` of `pages` at `pxPerMM`, the page's origin at `offsetPx`. With `systems`, only the runs of
    /// those systems (indices into `pages.document.systems`) — no title block, no box between systems; without, the
    /// whole page. The runs are walked as `ScoreSurface` walks a tile's (`systemCommandRanges(onPage:)`), from the draw
    /// program's default state, so a run replayed alone paints what the page paints there.
    public func paint(
        _ pages: ScorePages, page: Int, systems: Set<Int>? = nil, pxPerMM: Double, offsetPx: (x: Double, y: Double),
    )
}
```

Mode 1, 2 and 4 videos paint the systems a pane meets; mode 5 paints a whole page. No new drawing code: it is the
tile walk over `ScorePages.pages[page].commands`, filtered by span, through the same `DrawCommandWalker`. The commands
stay `package`.

## 2. An axis-aligned clip (public)

```swift
extension Direct2DFrameCanvas {
    /// Clips every paint until the matching `popClip()` to `rectPx` (canvas pixels), inside any clip already pushed.
    public func pushClip(x: Double, y: Double, width: Double, height: Double)
    public func popClip()
}
```

C: `cd2d_push_clip` / `cd2d_pop_clip` over `ID2D1RenderTarget::PushAxisAlignedClip` (antialiased) / `PopAxisAlignedClip`.
`copyPixels` refuses while a clip is pushed (a frame must end balanced).

## 3. A picture at an opacity (public)

```swift
extension Direct2DFrameCanvas {
    /// Draws BGRA premultiplied `pixels` (`widthPx` x `heightPx`, top-down) stretched over the rect at `opacity`.
    public func draw(
        pixels: UnsafeRawBufferPointer, widthPx: Int, heightPx: Int,
        in rect: (x: Double, y: Double, width: Double, height: Double), opacity: Double,
    ) throws
}
```

The wordmark: folino rasterizes its PDF once at the placed size (`Direct2DPageRenderer`'s PDF path, as the Windows
reader draws original PDFs) and composites it per frame at `ScoreVideoAppearance.logoAlpha`, one opacity over the whole
mark as Apple's transparency layer applies it. C: `cd2d_draw_bitmap(canvas, bgra, w, h, x, y, rw, rh, opacity)` over a
`ID2D1Bitmap` from memory, cached per canvas by the pointer and size.

## Tests (Windows)

- A page of a title run and two system runs: `systems: [1]` paints system 1 and neither the title nor system 0;
  without `systems` all three paint. (Through the `package` entry the public one calls, with the page's commands and
  spans built by hand, so the test needs no laid-out score.)
- A pushed clip leaves everything outside it the clear color; nested clips intersect; `copyPixels` throws while one
  is pushed.
- `draw(pixels:…, opacity: 0.5)` of opaque black over white reads back mid-gray (within 2).

## Versioning

Additive, public, Windows-only targets (`SheetMusicRenderWindows`, `CDirect2D`): a minor release, 4.38.0. Apple and
Android builds are untouched.
