# 4.37.0: a reusable offscreen frame canvas, an MP4 writer and an export count-in, for Windows

Date: 2026-11-13
Status: implemented on branch `windows-frame-canvas`, tested on Windows (folino-qa: 41 tests in 7 suites); approved by
the owner (2026-11-13), not released.
Consumer: folino's Windows score video export.
folino spec: `2026-11-13-windows-score-video-export-design.md` §5, §6, §7, §9.

## 1. `Direct2DFrameCanvas` (public, `SheetMusicRenderWindows`)

**Why.** A score video draws thousands of frames, each a few systems (or a page), a caret, ink and a logo, into pixels
an encoder takes. `Direct2DPageRenderer` already draws exactly this offscreen — a WIC software canvas
(`cd2d_create`), the screen's own walk (`DrawCommandWalker.paint`), the surface's overlay painting
(`ScoreSurface.paint`) and a pixel read (`cd2d_copy_pixels`) — but every entry that returns pixels is `package`
(`renderPixels`, `renderOverlayPixels`), and each call creates a canvas and loads the fonts again. The one public entry,
`renderPNG`, writes a whole page to a file. A host can neither reach the pixels nor afford a canvas per frame.

**API.**

```swift
public final class Direct2DFrameCanvas {
    /// A white `widthPx` x `heightPx` canvas with `fontFiles` (as `ScoreSurface(fontFiles:)` takes them) loaded once.
    public init(widthPx: Int, heightPx: Int, fontFiles: [String]) throws
    public var widthPx: Int { get }
    public var heightPx: Int { get }
    /// Fills the whole canvas with `argb`.
    public func clear(argb: UInt32)
    /// Paints `commands` at `pxPerMM`, offset by `offsetPx`, over what is there — once per system shown.
    public func paint(_ commands: some Collection<DrawCommand>, pxPerMM: Double, offsetPx: (x: Double, y: Double))
    /// Paints `overlays` the way `ScoreSurface` paints them, at `pxPerMM`, offset by `offsetPx`.
    public func paint(_ overlays: [ScoreSurface.Overlay], pxPerMM: Double, offsetPx: (x: Double, y: Double))
    /// Copies the canvas into `pixels` (BGRA premultiplied, top-down, `widthPx * heightPx * 4` bytes).
    public func copyPixels(into pixels: UnsafeMutableRawBufferPointer) throws
}
```

As built: `Direct2DPageRenderer`'s functions are left as they are; a test asserts that a frame on the canvas equals
their one-shot render of the same commands. The one C addition is `cd2d_clear` (`cd2d_copy_pixels` ends the drawing; the
next frame begins it again). `paint` culls to the canvas. The stroke floor applies per `paint` as it does today.

**Compatibility.** Additive; no existing signature changes. Not `Sendable`: one export thread draws on one canvas.

**Tests.** The existing `renderPixels` / `renderOverlayPixels` goldens, now through the class; one new test that two
`paint` calls at different offsets on one canvas equal one walk of both command lists, and that `clear` between frames
leaves nothing of the last frame.

## 2. An MP4 writer behind `CMediaFoundation`'s loader

**Why.** Windows "N" editions have no Media Foundation unless the Media Feature Pack is installed, which is why
`CMediaFoundation` loads `mfplat.dll` and `mfreadwrite.dll` at run time rather than linking them. A score video's writer
uses the same Sink Writer the AAC sink does; outside ssm it would need a second copy of that loader, or link the DLLs and
stop folino starting on an N edition. Beside the AAC sink, it shares the loader and the encoder checks.

**API.**

- `CMediaFoundation`: `cmf_mp4_encoder_available()` (H.264 and AAC encoders present), `cmf_mp4_open(path, width,
  height, fps, video_bit_rate, sample_rate, channels, audio_bit_rate, &writer)`, `cmf_mp4_write_frame(writer, bgra,
  time_100ns, duration_100ns)`, `cmf_mp4_write_audio(writer, samples, frames, time_100ns)`, `cmf_mp4_finish`,
  `cmf_mp4_close` — the `cmf_aac_*` shape.
- Swift, public: `MP4VideoWriter` in `SheetMusicAudioWindows` (or a new `SheetMusicVideoWindows` target, ssm's call) with
  `static var isAvailable`, `init(url:width:height:fps:videoBitRate:sampleRate:channels:audioBitRate:)`,
  `appendFrame(_:at:duration:)`, `appendAudio(_:frames:at:)`, `finish()`.
- As built: frames are converted to NV12 here (BT.709 studio range, 8-bit integer coefficients, chroma from each 2x2
  block's average) and handed to the encoder as NV12, the input and output types tagged BT.709 / 16–235. Handing it
  RGB32 instead let Media Foundation insert a converter that ignored the tags: colours read back up to 13 levels off.
  With NV12, Media Foundation read the colours back within 8 levels and AVFoundation on the Mac within 10 (its display
  colour management lifting them slightly, as it does Apple's own videos).
- The output type declares BT.709 primaries, matrix and transfer and the 16–235 nominal range; the input type a positive
  default stride (top-down rows). (folino's spike wrote an untagged stream whose colours a decoder lifted: RGB 40,120,200
  read back as 57,131,205.)

**Compatibility.** Additive.

**Tests.** On a Windows host: a one-second file with a colour chart and a frame whose top and bottom halves differ,
read back through the Source Reader (duration, size, H.264, AAC, the top row's colour within a few levels).

## 3. `countIn` for `WindowsPlaybackEngine.exportAudioFile`

**Why.** A score video's pre-roll counts in; Apple's `exportAudioFile(…, countIn:)` puts the count live playback plays
in front of the music (`exportCountIn`). Windows' export has no such parameter, so a Windows video's pre-roll would be
silent where every other platform's clicks. folino already carries the gap as a parity marker at its m4a exporter.

**API.** `countIn: Bool = false` on `WindowsPlaybackEngine.exportAudioFile`, after `range`, with Apple's semantics: the
count from the range's start at the metronome strip's volume whatever the metronome toggle says, the file longer by the
pre-roll over the rate, and a start with no count-in exporting as `false`. The count-in computation is lifted from the
Apple export into `SheetMusicAudioCore` if it is not portable already, so the two engines share it.

**Compatibility.** Additive, defaulted.

**Tests.** The portable count-in placement shared by both engines; on Windows, an export with `countIn: true` is longer
than one without by the pre-roll, within one render chunk.
