// Text measurement for the layout (`WindowsFontMetricsProvider`): the numbers a right-aligned part label or a centered
// measure number is anchored on, taken from the same face and the same `IDWriteTextLayout` `cd2d_fill_text` draws.
#include "cdirect2d_internal.h"

using cd2d::ComPtr;

namespace {

/// Receives the glyph runs of a laid-out text and joins the bounds of their outlines — the outlines `cd2d_fill_text`
/// fills, at the run positions it fills them at — relative to the first line's baseline origin, Y down.
///
/// The bounds are the path geometries' own (`ID2D1Geometry::GetBounds`), so they follow the curves rather than their
/// control points, the precision CoreText's image bounds have on the Mac.
class BoundsRenderer final : public IDWriteTextRenderer {
public:
    BoundsRenderer(ID2D1Factory1 *d2d, float dy) : d2d_(d2d), dy_(dy) {}

    bool hasInk = false;
    D2D1_RECT_F ink = D2D1::RectF(0, 0, 0, 0);

    // IUnknown. Lives on the stack for one Draw call, so reference counting is a formality.
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **object) override {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IDWritePixelSnapping)
            || riid == __uuidof(IDWriteTextRenderer)) {
            *object = static_cast<IDWriteTextRenderer *>(this);
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }

    // IDWritePixelSnapping: exactly `OutlineRenderer`'s answers, so the runs arrive where the drawing receives them.
    HRESULT STDMETHODCALLTYPE IsPixelSnappingDisabled(void *, BOOL *disabled) override {
        *disabled = TRUE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetCurrentTransform(void *, DWRITE_MATRIX *matrix) override {
        *matrix = DWRITE_MATRIX{1, 0, 0, 1, 0, 0};
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPixelsPerDip(void *, FLOAT *pixels) override {
        *pixels = 1;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE DrawGlyphRun(
        void *, FLOAT baselineX, FLOAT baselineY, DWRITE_MEASURING_MODE, const DWRITE_GLYPH_RUN *run,
        const DWRITE_GLYPH_RUN_DESCRIPTION *, IUnknown *) override {
        ComPtr<ID2D1PathGeometry> geometry;
        ComPtr<ID2D1GeometrySink> sink;
        HRESULT hr = d2d_->CreatePathGeometry(&geometry);
        if (SUCCEEDED(hr)) hr = geometry->Open(&sink);
        if (SUCCEEDED(hr)) {
            hr = run->fontFace->GetGlyphRunOutline(
                run->fontEmSize, run->glyphIndices, run->glyphAdvances, run->glyphOffsets, run->glyphCount,
                run->isSideways, run->bidiLevel % 2, sink.Get());
            const HRESULT closed = sink->Close();
            if (SUCCEEDED(hr)) hr = closed;
        }
        D2D1_RECT_F box = D2D1::RectF(0, 0, 0, 0);
        const D2D1::Matrix3x2F placement = D2D1::Matrix3x2F::Translation(baselineX, baselineY + dy_);
        if (SUCCEEDED(hr)) hr = geometry->GetBounds(&placement, &box);
        // A run of blanks has no figures, and an empty geometry's bounds come back inverted (left > right).
        if (SUCCEEDED(hr) && box.left <= box.right && box.top <= box.bottom) {
            if (hasInk) {
                if (box.left < ink.left) ink.left = box.left;
                if (box.top < ink.top) ink.top = box.top;
                if (box.right > ink.right) ink.right = box.right;
                if (box.bottom > ink.bottom) ink.bottom = box.bottom;
            } else {
                ink = box;
                hasInk = true;
            }
        }
        return hr;
    }
    HRESULT STDMETHODCALLTYPE DrawUnderline(void *, FLOAT, FLOAT, const DWRITE_UNDERLINE *, IUnknown *) override {
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawStrikethrough(
        void *, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH *, IUnknown *) override {
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawInlineObject(
        void *, FLOAT, FLOAT, IDWriteInlineObject *, BOOL, BOOL, IUnknown *) override {
        return S_OK;
    }

private:
    ID2D1Factory1 *d2d_;
    float dy_;
};

}  // namespace

extern "C" int32_t cd2d_measure_text(
    cd2d_resources *resources, const uint16_t *family, float size, int32_t weight, int32_t italic,
    const uint16_t *text, uint32_t length, cd2d_text_metrics *out) {
    *out = cd2d_text_metrics{};
    const wchar_t *name = reinterpret_cast<const wchar_t *>(family);
    const DWRITE_FONT_WEIGHT dwriteWeight = cd2d::fontWeight(weight);
    cd2d::Face *face = cd2d::resolveFace(resources, name, dwriteWeight, italic != 0);
    if (!face) return DWRITE_E_NOFONT;

    DWRITE_FONT_METRICS metrics;
    face->face->GetMetrics(&metrics);
    if (metrics.designUnitsPerEm == 0) return E_FAIL;
    const float scale = size / static_cast<float>(metrics.designUnitsPerEm);
    out->ascent = static_cast<float>(metrics.ascent) * scale;
    out->descent = static_cast<float>(metrics.descent) * scale;
    out->lineGap = static_cast<float>(metrics.lineGap) * scale;
    if (length == 0) return S_OK;

    ComPtr<IDWriteTextLayout> layout;
    float baseline = 0;
    HRESULT hr = cd2d::layoutText(
        resources, name, reinterpret_cast<const wchar_t *>(text), length, size, dwriteWeight, italic != 0, &layout,
        &baseline);
    if (FAILED(hr)) return hr;

    DWRITE_TEXT_METRICS textMetrics;
    hr = layout->GetMetrics(&textMetrics);
    if (FAILED(hr)) return hr;
    out->advance = textMetrics.widthIncludingTrailingWhitespace;

    // `cd2d_fill_text` places the layout's top `baseline` above the stream's y; shifting the runs up by it puts the
    // bounds relative to the baseline origin the stream's (x, y) names.
    BoundsRenderer renderer(resources->d2d.Get(), -baseline);
    hr = layout->Draw(nullptr, &renderer, 0, 0);
    if (FAILED(hr)) return hr;
    if (renderer.hasInk) {
        // Y down to Y up: the lowest ink (largest y) becomes the rect's origin.
        out->inkX = renderer.ink.left;
        out->inkY = -renderer.ink.bottom;
        out->inkW = renderer.ink.right - renderer.ink.left;
        out->inkH = renderer.ink.bottom - renderer.ink.top;
    }
    return S_OK;
}
