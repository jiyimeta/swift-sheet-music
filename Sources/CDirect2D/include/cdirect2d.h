// Direct2D + DirectWrite drawing for SheetMusicRenderWindows, behind a flat C API.
//
// The Windows SDK module the Swift toolchain ships (WinSDK) has neither d2d1.h nor dwrite.h, and DirectWrite has no
// C interface at all, so the drawing lives in C++ and Swift sees these functions only. The vocabulary is the draw
// program's (`DrawCommand`), already in device pixels: the Swift walker does the millimetre conversion, the stroke
// minimum and the text-style state, the same split `DrawProgramCGRenderer` has on the Mac.
//
// Every function returning int32_t returns 0 or a failing HRESULT. Strings are UTF-16 (`wchar_t` on Windows).
#ifndef CDIRECT2D_H
#define CDIRECT2D_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cd2d_canvas cd2d_canvas;
typedef struct cd2d_resources cd2d_resources;

/// Device-independent resources: the Direct2D, DirectWrite and WIC factories, a private font collection (with the
/// installed fonts behind it for a family it lacks), and the caches built on them (glyph outlines, stroke styles, text
/// formats). Every canvas made from them shares the caches;
/// they must outlive those canvases. One thread at a time (the Direct2D factory is single-threaded).
int32_t cd2d_resources_create(cd2d_resources **resources);
/// Adds a font file (OpenType) to the private collection. Call before `cd2d_resources_fonts_ready`.
int32_t cd2d_resources_add_font_file(cd2d_resources *resources, const uint16_t *path);
/// Builds the collection from the files added so far, and empties every cache built against the previous one.
int32_t cd2d_resources_fonts_ready(cd2d_resources *resources);
/// How many glyph outlines the cache holds (for tests and logs).
uint32_t cd2d_resources_glyph_cache_count(cd2d_resources *resources);
void cd2d_resources_destroy(cd2d_resources *resources);

/// An offscreen canvas `width` x `height` pixels drawing with `resources` (a WIC bitmap at 96 DPI, so one Direct2D
/// unit is one pixel), cleared to white and ready to draw.
int32_t cd2d_create_wic(cd2d_canvas **canvas, cd2d_resources *resources, uint32_t width, uint32_t height);

/// `cd2d_create_wic` with resources of its own, which `cd2d_destroy` frees.
int32_t cd2d_create(cd2d_canvas **canvas, uint32_t width, uint32_t height);
/// Adds a font file (OpenType) to the canvas's resources. Call before `cd2d_fonts_ready`.
int32_t cd2d_add_font_file(cd2d_canvas *canvas, const uint16_t *path);
/// Builds the canvas's resources' collection from the files added so far.
int32_t cd2d_fonts_ready(cd2d_canvas *canvas);

void cd2d_set_color(cd2d_canvas *canvas, uint32_t argb);
/// Replaces the transform with a translation (the page offset) followed by `rotation_degrees` around the pivot.
void cd2d_set_transform(
    cd2d_canvas *canvas, float offset_x, float offset_y, float rotation_degrees, float pivot_x, float pivot_y);

void cd2d_move_to(cd2d_canvas *canvas, float x, float y);
void cd2d_line_to(cd2d_canvas *canvas, float x, float y);
void cd2d_cubic_to(cd2d_canvas *canvas, float c1x, float c1y, float c2x, float c2y, float x, float y);
/// Strokes the path built since the last stroke and starts a new one. A dash with both lengths above zero dashes it.
void cd2d_stroke(cd2d_canvas *canvas, float width, float dash_on, float dash_off);
/// Fills the path built since the last stroke or fill — its open figure closed, nonzero winding, in the current
/// color, never dashed — and starts a new one, as `cd2d_stroke` does. The draw program's `fillPath` (beams).
void cd2d_fill_path(cd2d_canvas *canvas);
void cd2d_fill_rect(cd2d_canvas *canvas, float x, float y, float width, float height);

/// A filled shape built once and filled every frame — an ink stroke's outline: closed figures in millimetres, nonzero
/// winding. A path geometry of the canvas's factory, which a device loss does not invalidate.
typedef struct cd2d_shape cd2d_shape;
/// `xy` holds every figure's points in order, x then y; `counts` the number of points in each of `figure_count`
/// figures. A figure of fewer than three points is skipped. Release the result with `cd2d_shape_release`.
int32_t cd2d_shape_create(
    cd2d_canvas *canvas, const float *xy, const uint32_t *counts, uint32_t figure_count, cd2d_shape **out);
/// Fills `shape` in the current color, its millimetres scaled by `scale` (pixels per millimetre) under the canvas
/// transform — where `cd2d_move_to` and friends take points already in pixels.
void cd2d_fill_shape(cd2d_canvas *canvas, cd2d_shape *shape, float scale);
void cd2d_shape_release(cd2d_shape *shape);

/// `family`: the font family name (L"Bravura", L"Edwin", L"Segoe UI"), looked up in the private collection first and
/// in the installed fonts when the private one lacks it. `weight` is DirectWrite's (400 regular, 600 semibold, 700
/// bold; zero or less is regular). Weight and italic pick the family's own face when it has one and the regular face
/// otherwise — never a synthesized one, like CoreText's symbolic traits.
void cd2d_fill_glyph(
    cd2d_canvas *canvas, const uint16_t *family, uint32_t codepoint, float x, float y, float size, int32_t weight,
    int32_t italic);
/// The glyph's outline scaled so its bounding box spans [top_y, bottom_y] vertically, its x scaled by `x_scale`, its
/// right edge at `right_edge_x` (`StaffRenderer.smuflGlyphPathStretched`).
void cd2d_fill_stretched_glyph(
    cd2d_canvas *canvas, const uint16_t *family, uint32_t codepoint, float right_edge_x, float top_y, float bottom_y,
    float size, float x_scale);
/// Laid-out text (DirectWrite shaping and kerning), its outline filled with the baseline at (x, y). Family, weight
/// and italic as in `cd2d_fill_glyph`.
void cd2d_fill_text(
    cd2d_canvas *canvas, const uint16_t *family, const uint16_t *text, uint32_t length, float x, float y, float size,
    int32_t weight, int32_t italic);

/// What `cd2d_measure_text` measured, in the units of its `size`. `ascent`, `descent` and `lineGap` are the face's
/// (`DWRITE_FONT_METRICS`, descent positive). `advance` is the laid-out width including trailing whitespace (CoreText's
/// typographic width). The ink rect bounds the glyph outlines `cd2d_fill_text` fills, relative to the baseline origin
/// and Y-up like CoreText's bounds: (`inkX`, `inkY`) is its lower-left corner. No ink (empty or blank text) is all
/// four zero.
typedef struct cd2d_text_metrics {
    float ascent;
    float descent;
    float lineGap;
    float advance;
    float inkX;
    float inkY;
    float inkW;
    float inkH;
} cd2d_text_metrics;

/// Measures `text` exactly as `cd2d_fill_text` would draw it at `size` — the same face resolution (private collection,
/// then the installed fonts) and the same `IDWriteTextLayout` — so a layout that anchors on these numbers lands where
/// the drawing does. `length` may be zero: the face metrics only. Fails with DWRITE_E_NOFONT when no collection has
/// the family. Uses the resources' caches: one thread at a time, like drawing.
int32_t cd2d_measure_text(
    cd2d_resources *resources, const uint16_t *family, float size, int32_t weight, int32_t italic,
    const uint16_t *text, uint32_t length, cd2d_text_metrics *out);

/// Where `cd2d_fill_text` puts each caret position of `text`, in the units of `size` from the text's start: `offsets`
/// holds `length + 1` floats, the leading edge of the cluster at each UTF-16 position (a position inside a cluster
/// gets the cluster's) and last the text's trailing edge. The same layout as `cd2d_measure_text`, kerning included.
int32_t cd2d_measure_carets(
    cd2d_resources *resources, const uint16_t *family, float size, int32_t weight, int32_t italic,
    const uint16_t *text, uint32_t length, float *offsets);

/// The path of the font file `cd2d_fill_text` draws `family` from at `weight` and slant — the face it resolves, as
/// `cd2d_fill_glyph` describes — into `path` (`capacity` UTF-16 units, NUL included), its length without the NUL into
/// `length` even when `path` is too short (ERROR_INSUFFICIENT_BUFFER), and the face's index in its file (a collection's
/// member; 0 for a single font) into `face_index`. E_NOTIMPL when the face spans several files; E_NOINTERFACE when the
/// file is not on disk.
int32_t cd2d_font_file_path(
    cd2d_resources *resources, const uint16_t *family, int32_t weight, int32_t italic, uint16_t *path,
    uint32_t capacity, uint32_t *length, uint32_t *face_index);

/// One run of `cd2d_text_font_runs`: the UTF-16 range of the text a glyph run covers, and the file of the face it is
/// drawn in.
typedef struct cd2d_font_run {
    uint32_t start;
    uint32_t length;
    /// The face's index in its file (a collection's member); 0 for a single font.
    uint32_t faceIndex;
    /// The file's path, NUL-terminated; empty when the face is not a file on disk or its path does not fit.
    uint16_t path[260];
} cd2d_font_run;

/// The glyph runs `cd2d_fill_text` draws `text` in, with the file each one's face comes from: the family's own face,
/// or the one DirectWrite's system font fallback chose for characters the family lacks. At most `capacity` runs into
/// `runs`, how many into `count`.
int32_t cd2d_text_font_runs(
    cd2d_resources *resources, const uint16_t *family, int32_t weight, int32_t italic, const uint16_t *text,
    uint32_t length, cd2d_font_run *runs, uint32_t capacity, uint32_t *count);

/// Ends drawing and writes a WIC canvas as a PNG.
int32_t cd2d_write_png(cd2d_canvas *canvas, const uint16_t *path);
void cd2d_destroy(cd2d_canvas *canvas);

// MARK: - Onscreen surface

/// What a draw or present returns when the device was lost (the value of D2DERR_RECREATE_TARGET; the DXGI
/// device-removed and device-reset errors map to it too): call `cd2d_surface_recreate`, which also invalidates every
/// band made before.
static const int32_t CD2D_E_RECREATE = -2003238900;  // 0x8899000C

typedef struct cd2d_surface cd2d_surface;
typedef struct cd2d_band cd2d_band;

/// A surface on a composition swap chain `width` x `height` physical pixels, for a XAML `SwapChainPanel` whose
/// composition scale is (`scale_x`, `scale_y`): the swap chain's matrix transform undoes that scale, so the panel does
/// not stretch the pixels. `swap_chain` receives the `IDXGISwapChain1` with a reference the caller releases after
/// handing it to `ISwapChainPanelNative::SetSwapChain`. Hardware Direct3D 11, or WARP where there is none.
int32_t cd2d_surface_create_composition(
    cd2d_surface **surface, cd2d_resources *resources, uint32_t width, uint32_t height, float scale_x, float scale_y,
    void **swap_chain);
/// A surface on a swap chain for the window `hwnd` (for probes without XAML).
int32_t cd2d_surface_create_hwnd(
    cd2d_surface **surface, cd2d_resources *resources, void *hwnd, uint32_t width, uint32_t height);
/// New size and composition scale; the back buffer is recreated, bands are kept.
int32_t cd2d_surface_resize(cd2d_surface *surface, uint32_t width, uint32_t height, float scale_x, float scale_y);
/// After CD2D_E_RECREATE: a new device and swap chain of the same size. For a composition surface `swap_chain`
/// receives the new swap chain (as in `cd2d_surface_create_composition`); for an HWND surface it is set to null.
int32_t cd2d_surface_recreate(cd2d_surface *surface, void **swap_chain);
/// Debug aid: the next band end or present fails with `hresult`, so the device-loss path can be exercised.
void cd2d_surface_debug_fail_next(cd2d_surface *surface, int32_t hresult);
/// Bytes held by the surface's live bands.
uint64_t cd2d_surface_band_bytes(cd2d_surface *surface);
void cd2d_surface_destroy(cd2d_surface *surface);

/// A new band `width` x `height` pixels, cleared to white, with `canvas` drawing into it until `cd2d_band_end`. The
/// canvas belongs to the band. Bands are drawn one at a time, never during a frame.
int32_t cd2d_band_begin(
    cd2d_surface *surface, uint32_t width, uint32_t height, cd2d_band **band, cd2d_canvas **canvas);
int32_t cd2d_band_end(cd2d_surface *surface, cd2d_band *band);
/// Probe aid: an ended band's pixels in `pixels` (BGRA premultiplied — opaque, since a band starts white — `width` x
/// `height`, rows of `width * 4` bytes, top-down), copied on the surface's device through a CPU-readable bitmap. What
/// the band does not cover is left as it was. A band from before a recreate fails with CD2D_E_RECREATE.
int32_t cd2d_band_read_back(
    cd2d_surface *surface, cd2d_band *band, uint8_t *pixels, uint32_t width, uint32_t height);
void cd2d_band_release(cd2d_surface *surface, cd2d_band *band);

/// Starts a frame on the back buffer, cleared to `background_argb`.
int32_t cd2d_frame_begin(cd2d_surface *surface, uint32_t background_argb);
/// Draws `band` with its top-left at (`x`, `y`) back-buffer pixels, `scale` times its size (nearest-neighbor at 1,
/// linear otherwise). A band from before a recreate is skipped.
void cd2d_frame_draw_band(cd2d_surface *surface, cd2d_band *band, float x, float y, float scale);
/// A canvas drawing on the frame, for overlays; valid until `cd2d_frame_present`.
cd2d_canvas *cd2d_frame_canvas(cd2d_surface *surface);
/// Ends the frame and presents it (synchronized to the display).
int32_t cd2d_frame_present(cd2d_surface *surface);
/// Probe aid: the next `cd2d_frame_present` also copies the finished frame into `pixels` (BGRA, `width` x `height`,
/// rows of `width * 4` bytes, top-down) before presenting — exactly what was drawn, whatever the compositor shows.
/// The buffer must stay valid until that present returns.
void cd2d_surface_debug_read_back_next(cd2d_surface *surface, uint8_t *pixels, uint32_t width, uint32_t height);

/// Probe aid: a WIC canvas's pixels (BGRA premultiplied, rows of `width * 4` bytes), after ending its drawing.
int32_t cd2d_copy_pixels(cd2d_canvas *canvas, uint8_t *pixels, uint32_t width, uint32_t height);

// MARK: PDF pages, drawn by the OS's own renderer (Windows.Data.Pdf and its Direct2D interop)

typedef struct cd2d_pdf cd2d_pdf;

/// Loads the PDF at `path` (UTF-16, NUL-terminated) and gives its page count. Call it off the UI thread: the load is a
/// WinRT async operation this waits on, and the thread is joined to the multithreaded apartment if it has none.
int32_t cd2d_pdf_open(const uint16_t *path, cd2d_pdf **pdf, uint32_t *page_count);
void cd2d_pdf_close(cd2d_pdf *pdf);
/// Page `page`'s size in DIPs (1/96 inch).
int32_t cd2d_pdf_page_size(cd2d_pdf *pdf, uint32_t page, float *width, float *height);
/// Draws page `page` into the band being drawn (between `cd2d_band_begin` and `cd2d_band_end`), `scale` pixels per
/// DIP, moved by (-`offset_x`, -`offset_y`) pixels. The surface makes its PDF renderer from its own device on first use
/// and again after a recreate. Device loss reports CD2D_E_RECREATE, as every band draw does.
int32_t cd2d_band_draw_pdf(
    cd2d_surface *surface, cd2d_pdf *pdf, uint32_t page, float scale, float offset_x, float offset_y);
/// Page `page` drawn whole on white at `scale` pixels per DIP, on a device of its own (hardware, or WARP), into
/// `pixels` (BGRA premultiplied, `width` x `height`, rows of `width * 4` bytes) — tests and thumbnails.
int32_t cd2d_pdf_render_pixels(
    cd2d_pdf *pdf, uint32_t page, float scale, uint8_t *pixels, uint32_t width, uint32_t height);
/// `cd2d_pdf_render_pixels`, written as PNG to `path` (UTF-16, NUL-terminated).
int32_t cd2d_pdf_write_png(cd2d_pdf *pdf, uint32_t page, float scale, const uint16_t *path);

typedef struct cd2d_pdf_renderer cd2d_pdf_renderer;

/// A device of its own for drawing PDF pages away from the UI thread: hardware, or WARP where there is none. Create it,
/// draw with it and destroy it on one thread, which it joins to the multithreaded apartment if that thread has none.
int32_t cd2d_pdf_renderer_create(cd2d_pdf_renderer **renderer);
void cd2d_pdf_renderer_destroy(cd2d_pdf_renderer *renderer);
/// `width` x `height` pixels of page `page` at `scale` pixels per DIP, starting (`offset_x`, `offset_y`) pixels into
/// the page, drawn on white into `pixels` (BGRA premultiplied, rows of `width * 4` bytes). A lost device reports
/// CD2D_E_RECREATE: destroy the renderer and make another.
int32_t cd2d_pdf_renderer_draw(
    cd2d_pdf_renderer *renderer, cd2d_pdf *pdf, uint32_t page, float scale, float offset_x, float offset_y,
    uint8_t *pixels, uint32_t width, uint32_t height);
/// A band holding `pixels` (BGRA premultiplied, `width` x `height`, rows of `width * 4` bytes) on the surface's device,
/// ready to blit — a page drawn on another thread. Release it with `cd2d_band_release`. Device loss reports
/// CD2D_E_RECREATE.
int32_t cd2d_band_from_pixels(
    cd2d_surface *surface, uint32_t width, uint32_t height, const uint8_t *pixels, cd2d_band **band);

#ifdef __cplusplus
}
#endif

#endif
