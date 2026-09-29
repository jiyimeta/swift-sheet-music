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

/// An offscreen canvas `width` x `height` pixels (a WIC bitmap at 96 DPI, so one Direct2D unit is one pixel), cleared
/// to white and ready to draw.
int32_t cd2d_create(cd2d_canvas **canvas, uint32_t width, uint32_t height);
/// Adds a font file (OpenType) to the canvas's private font collection. Call before `cd2d_fonts_ready`.
int32_t cd2d_add_font_file(cd2d_canvas *canvas, const uint16_t *path);
/// Builds the collection from the files added so far.
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
void cd2d_fill_rect(cd2d_canvas *canvas, float x, float y, float width, float height);

/// `family`: the font family name (L"Bravura", L"Edwin"). Bold / italic pick the family's own face when it has one
/// and the regular face otherwise — never a synthesized one, like CoreText's symbolic traits.
void cd2d_fill_glyph(
    cd2d_canvas *canvas, const uint16_t *family, uint32_t codepoint, float x, float y, float size, int32_t bold,
    int32_t italic);
/// The glyph's outline scaled so its bounding box spans [top_y, bottom_y] vertically, its x scaled by `x_scale`, its
/// right edge at `right_edge_x` (`StaffRenderer.smuflGlyphPathStretched`).
void cd2d_fill_stretched_glyph(
    cd2d_canvas *canvas, const uint16_t *family, uint32_t codepoint, float right_edge_x, float top_y, float bottom_y,
    float size, float x_scale);
/// Laid-out text (DirectWrite shaping and kerning), its outline filled with the baseline at (x, y).
void cd2d_fill_text(
    cd2d_canvas *canvas, const uint16_t *family, const uint16_t *text, uint32_t length, float x, float y, float size,
    int32_t bold, int32_t italic);

/// Ends drawing and writes the canvas as a PNG.
int32_t cd2d_write_png(cd2d_canvas *canvas, const uint16_t *path);
void cd2d_destroy(cd2d_canvas *canvas);

#ifdef __cplusplus
}
#endif

#endif
