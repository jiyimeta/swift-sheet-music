// The structures behind the flat C API, shared by the canvas (cdirect2d.cpp) and the onscreen surface
// (cdirect2d_surface.cpp). Not part of the module's public headers.
#ifndef CDIRECT2D_INTERNAL_H
#define CDIRECT2D_INTERNAL_H

#include <windows.h>
#include <d2d1_1.h>
#include <dwrite_3.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstring>
#include <map>
#include <string>
#include <tuple>

#include "cdirect2d.h"

namespace cd2d {

using Microsoft::WRL::ComPtr;

/// One resolved face per (family, bold, italic).
struct FaceKey {
    std::wstring family;
    bool bold;
    bool italic;
    bool operator<(const FaceKey &other) const {
        return std::tie(family, bold, italic) < std::tie(other.family, other.bold, other.italic);
    }
};

struct Face {
    ComPtr<IDWriteFontFace> face;
    DWRITE_FONT_WEIGHT weight = DWRITE_FONT_WEIGHT_NORMAL;
    DWRITE_FONT_STYLE style = DWRITE_FONT_STYLE_NORMAL;
};

/// A glyph's outline, made once at `kGlyphEm` and scaled to each size it is drawn at: geometries are resolution
/// independent, and Direct2D flattens them after the transform.
struct GlyphKey {
    IDWriteFontFace *face;
    uint32_t codepoint;
    bool operator<(const GlyphKey &other) const {
        return std::tie(face, codepoint) < std::tie(other.face, other.codepoint);
    }
};

constexpr float kGlyphEm = 64.0f;

/// A dash pattern in stroke widths, the unit Direct2D measures custom dashes in.
struct StrokeKey {
    float on;
    float off;
    bool operator<(const StrokeKey &other) const { return std::tie(on, off) < std::tie(other.on, other.off); }
};

struct FormatKey {
    std::wstring family;
    DWRITE_FONT_WEIGHT weight;
    DWRITE_FONT_STYLE style;
    uint32_t sizeBits;
    bool operator<(const FormatKey &other) const {
        return std::tie(family, weight, style, sizeBits) < std::tie(other.family, other.weight, other.style, other.sizeBits);
    }
};

}  // namespace cd2d

/// Everything that does not depend on a device or a render target: the factories, the fonts, and the caches built
/// from them. Shared by every canvas made from it — the PNG path's and the onscreen surface's — so both draw from the
/// same outlines.
struct cd2d_resources {
    cd2d::ComPtr<ID2D1Factory1> d2d;
    cd2d::ComPtr<IDWriteFactory5> dwrite;
    cd2d::ComPtr<IWICImagingFactory> wic;
    cd2d::ComPtr<IDWriteFontSetBuilder1> fontBuilder;
    cd2d::ComPtr<IDWriteFontCollection1> fonts;
    std::map<cd2d::FaceKey, cd2d::Face> faces;
    std::map<cd2d::GlyphKey, cd2d::ComPtr<ID2D1PathGeometry>> glyphs;
    std::map<cd2d::StrokeKey, cd2d::ComPtr<ID2D1StrokeStyle>> strokes;
    std::map<cd2d::FormatKey, cd2d::ComPtr<IDWriteTextFormat>> formats;
};

/// A render target to draw the draw program's vocabulary on, with the path under construction and the transform.
/// The target is a WIC bitmap's (the PNG path) or a device context's (a band or a frame of the onscreen surface).
struct cd2d_canvas {
    cd2d_resources *resources = nullptr;
    bool ownsResources = false;
    cd2d::ComPtr<IWICBitmap> bitmap;
    cd2d::ComPtr<ID2D1RenderTarget> target;
    cd2d::ComPtr<ID2D1SolidColorBrush> brush;

    cd2d::ComPtr<ID2D1PathGeometry> path;
    cd2d::ComPtr<ID2D1GeometrySink> sink;
    bool figureOpen = false;
    D2D1::Matrix3x2F transform = D2D1::Matrix3x2F::Identity();
    bool drawing = false;
};

namespace cd2d {

/// A canvas over a target someone else owns and begins / ends drawing on (a band, a frame).
void resetCanvas(cd2d_canvas *canvas, ID2D1RenderTarget *target, ID2D1SolidColorBrush *brush);

}  // namespace cd2d

#endif
