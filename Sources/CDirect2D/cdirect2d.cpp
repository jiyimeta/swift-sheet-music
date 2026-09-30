#include "cdirect2d_internal.h"

using cd2d::ComPtr;

namespace {

/// Fills `geometry` under `placement` (then the canvas transform).
void fillGeometry(cd2d_canvas *canvas, ID2D1Geometry *geometry, const D2D1::Matrix3x2F &placement) {
    canvas->target->SetTransform(placement * canvas->transform);
    canvas->target->FillGeometry(geometry, canvas->brush.Get());
    canvas->target->SetTransform(canvas->transform);
}

/// The family's face for the requested weight and style, or its regular face when the family has no such face:
/// DirectWrite would otherwise synthesize one, which CoreText (the Mac reference) does not.
cd2d::Face *resolveFace(cd2d_resources *resources, const wchar_t *family, bool bold, bool italic) {
    cd2d::FaceKey key{family, bold, italic};
    auto found = resources->faces.find(key);
    if (found != resources->faces.end()) {
        return found->second.face ? &found->second : nullptr;
    }
    cd2d::Face resolved;
    UINT32 index = 0;
    BOOL exists = FALSE;
    if (resources->fonts && SUCCEEDED(resources->fonts->FindFamilyName(family, &index, &exists)) && exists) {
        // IDWriteFontFamily1: IDWriteFontCollection1's GetFontFamily hides the base overload that takes the older type.
        ComPtr<IDWriteFontFamily1> fontFamily;
        if (SUCCEEDED(resources->fonts->GetFontFamily(index, &fontFamily))) {
            ComPtr<IDWriteFont> font;
            auto match = [&](DWRITE_FONT_WEIGHT weight, DWRITE_FONT_STYLE style) {
                font.Reset();
                return SUCCEEDED(fontFamily->GetFirstMatchingFont(weight, DWRITE_FONT_STRETCH_NORMAL, style, &font));
            };
            bool found = match(
                bold ? DWRITE_FONT_WEIGHT_BOLD : DWRITE_FONT_WEIGHT_NORMAL,
                italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL);
            if (found && font->GetSimulations() != DWRITE_FONT_SIMULATIONS_NONE) {
                found = match(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL);
            }
            if (found) {
                resolved.weight = font->GetWeight();
                resolved.style = font->GetStyle();
                font->CreateFontFace(&resolved.face);
            }
        }
    }
    auto inserted = resources->faces.emplace(key, resolved);
    return inserted.first->second.face ? &inserted.first->second : nullptr;
}

/// The outline of one glyph at `cd2d::kGlyphEm`, baseline origin at (0, 0), Y down — made once per face and codepoint.
ID2D1PathGeometry *glyphOutline(cd2d_resources *resources, IDWriteFontFace *face, uint32_t codepoint) {
    cd2d::GlyphKey key{face, codepoint};
    auto found = resources->glyphs.find(key);
    if (found != resources->glyphs.end()) {
        return found->second.Get();
    }
    ComPtr<ID2D1PathGeometry> geometry;
    UINT16 glyph = 0;
    if (SUCCEEDED(face->GetGlyphIndices(&codepoint, 1, &glyph)) && glyph != 0) {
        ComPtr<ID2D1GeometrySink> sink;
        if (SUCCEEDED(resources->d2d->CreatePathGeometry(&geometry)) && SUCCEEDED(geometry->Open(&sink))) {
            face->GetGlyphRunOutline(cd2d::kGlyphEm, &glyph, nullptr, nullptr, 1, FALSE, FALSE, sink.Get());
            sink->Close();
        } else {
            geometry.Reset();
        }
    }
    // A missing glyph is cached too (as null), so it is looked up once.
    auto inserted = resources->glyphs.emplace(key, geometry);
    return inserted.first->second.Get();
}

/// The stroke style for a dash measured in stroke widths, or null for a solid line.
ID2D1StrokeStyle *strokeStyle(cd2d_resources *resources, float on, float off) {
    cd2d::StrokeKey key{on, off};
    auto found = resources->strokes.find(key);
    if (found != resources->strokes.end()) {
        return found->second.Get();
    }
    ComPtr<ID2D1StrokeStyle> style;
    const FLOAT dashes[] = {on, off};
    resources->d2d->CreateStrokeStyle(
        D2D1::StrokeStyleProperties(
            D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_LINE_JOIN_MITER, 10.0f,
            D2D1_DASH_STYLE_CUSTOM, 0.0f),
        dashes, 2, &style);
    auto inserted = resources->strokes.emplace(key, style);
    return inserted.first->second.Get();
}

IDWriteTextFormat *textFormat(
    cd2d_resources *resources, const wchar_t *family, DWRITE_FONT_WEIGHT weight, DWRITE_FONT_STYLE style, float size) {
    uint32_t sizeBits = 0;
    std::memcpy(&sizeBits, &size, sizeof sizeBits);
    cd2d::FormatKey key{family, weight, style, sizeBits};
    auto found = resources->formats.find(key);
    if (found != resources->formats.end()) {
        return found->second.Get();
    }
    ComPtr<IDWriteTextFormat> format;
    if (SUCCEEDED(resources->dwrite->CreateTextFormat(
            family, resources->fonts.Get(), weight, style, DWRITE_FONT_STRETCH_NORMAL, size, L"en-us", &format))) {
        format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    }
    auto inserted = resources->formats.emplace(key, format);
    return inserted.first->second.Get();
}

/// Receives the glyph runs of a laid-out text and fills their outlines — text drawn the way
/// `DrawProgramCGRenderer.fillText` draws it, as outlines at the run positions rather than as rasterized text.
class OutlineRenderer final : public IDWriteTextRenderer {
public:
    OutlineRenderer(cd2d_canvas *canvas, float x, float y) : canvas_(canvas), x_(x), y_(y) {}

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

    // IDWritePixelSnapping: no snapping, one pixel per DIP, no transform — outlines at exact positions.
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
        HRESULT hr = canvas_->resources->d2d->CreatePathGeometry(&geometry);
        if (SUCCEEDED(hr)) hr = geometry->Open(&sink);
        if (SUCCEEDED(hr)) {
            hr = run->fontFace->GetGlyphRunOutline(
                run->fontEmSize, run->glyphIndices, run->glyphAdvances, run->glyphOffsets, run->glyphCount,
                run->isSideways, run->bidiLevel % 2, sink.Get());
            sink->Close();
        }
        if (SUCCEEDED(hr)) {
            fillGeometry(canvas_, geometry.Get(), D2D1::Matrix3x2F::Translation(x_ + baselineX, y_ + baselineY));
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
    cd2d_canvas *canvas_;
    float x_;
    float y_;
};

void endFigure(cd2d_canvas *canvas) {
    if (canvas->figureOpen) {
        canvas->sink->EndFigure(D2D1_FIGURE_END_OPEN);
        canvas->figureOpen = false;
    }
}

/// The path under construction, opened on first use.
ID2D1GeometrySink *pathSink(cd2d_canvas *canvas) {
    if (!canvas->sink) {
        canvas->path.Reset();
        if (FAILED(canvas->resources->d2d->CreatePathGeometry(&canvas->path))
            || FAILED(canvas->path->Open(&canvas->sink))) {
            canvas->path.Reset();
            canvas->sink.Reset();
            return nullptr;
        }
    }
    return canvas->sink.Get();
}

}  // namespace

namespace cd2d {

void resetCanvas(cd2d_canvas *canvas, ID2D1RenderTarget *target, ID2D1SolidColorBrush *brush) {
    canvas->target = target;
    canvas->brush = brush;
    canvas->path.Reset();
    canvas->sink.Reset();
    canvas->figureOpen = false;
    canvas->transform = D2D1::Matrix3x2F::Identity();
    canvas->drawing = false;
    if (brush) brush->SetColor(D2D1::ColorF(0, 0, 0, 1));
    if (target) target->SetTransform(canvas->transform);
}

}  // namespace cd2d

// MARK: - Resources

extern "C" int32_t cd2d_resources_create(cd2d_resources **out) {
    *out = nullptr;
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return hr;

    auto resources = new cd2d_resources();
    hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, resources->d2d.GetAddressOf());
    if (SUCCEEDED(hr)) {
        hr = DWriteCreateFactory(
            DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory5),
            reinterpret_cast<IUnknown **>(resources->dwrite.GetAddressOf()));
    }
    if (SUCCEEDED(hr)) hr = resources->dwrite->CreateFontSetBuilder(&resources->fontBuilder);
    if (SUCCEEDED(hr)) {
        hr = CoCreateInstance(
            CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&resources->wic));
    }
    if (FAILED(hr)) {
        delete resources;
        return hr;
    }
    *out = resources;
    return S_OK;
}

extern "C" int32_t cd2d_resources_add_font_file(cd2d_resources *resources, const uint16_t *path) {
    ComPtr<IDWriteFontFile> file;
    HRESULT hr = resources->dwrite->CreateFontFileReference(reinterpret_cast<const wchar_t *>(path), nullptr, &file);
    if (SUCCEEDED(hr)) hr = resources->fontBuilder->AddFontFile(file.Get());
    return hr;
}

extern "C" int32_t cd2d_resources_fonts_ready(cd2d_resources *resources) {
    ComPtr<IDWriteFontSet> set;
    HRESULT hr = resources->fontBuilder->CreateFontSet(&set);
    if (SUCCEEDED(hr)) hr = resources->dwrite->CreateFontCollectionFromFontSet(set.Get(), &resources->fonts);
    // Everything resolved against the previous collection goes: a cached outline of an old face must never be drawn
    // for the new one (the glyph cache is keyed by the face object).
    resources->glyphs.clear();
    resources->formats.clear();
    resources->faces.clear();
    return hr;
}

extern "C" uint32_t cd2d_resources_glyph_cache_count(cd2d_resources *resources) {
    return static_cast<uint32_t>(resources->glyphs.size());
}

extern "C" void cd2d_resources_destroy(cd2d_resources *resources) {
    delete resources;
}

// MARK: - The WIC canvas (PNG)

extern "C" int32_t cd2d_create_wic(cd2d_canvas **out, cd2d_resources *resources, uint32_t width, uint32_t height) {
    *out = nullptr;
    auto canvas = new cd2d_canvas();
    canvas->resources = resources;
    HRESULT hr = resources->wic->CreateBitmap(
        width, height, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, &canvas->bitmap);
    if (SUCCEEDED(hr)) {
        D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties(
            D2D1_RENDER_TARGET_TYPE_DEFAULT,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
        hr = resources->d2d->CreateWicBitmapRenderTarget(canvas->bitmap.Get(), properties, &canvas->target);
    }
    if (SUCCEEDED(hr)) hr = canvas->target->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &canvas->brush);
    if (FAILED(hr)) {
        delete canvas;
        return hr;
    }
    canvas->target->BeginDraw();
    canvas->drawing = true;
    canvas->target->Clear(D2D1::ColorF(1, 1, 1, 1));
    *out = canvas;
    return S_OK;
}

extern "C" int32_t cd2d_create(cd2d_canvas **out, uint32_t width, uint32_t height) {
    *out = nullptr;
    cd2d_resources *resources = nullptr;
    HRESULT hr = cd2d_resources_create(&resources);
    if (FAILED(hr)) return hr;
    hr = cd2d_create_wic(out, resources, width, height);
    if (FAILED(hr)) {
        cd2d_resources_destroy(resources);
        return hr;
    }
    (*out)->ownsResources = true;
    return S_OK;
}

extern "C" int32_t cd2d_add_font_file(cd2d_canvas *canvas, const uint16_t *path) {
    return cd2d_resources_add_font_file(canvas->resources, path);
}

extern "C" int32_t cd2d_fonts_ready(cd2d_canvas *canvas) {
    return cd2d_resources_fonts_ready(canvas->resources);
}

// MARK: - Drawing

extern "C" void cd2d_set_color(cd2d_canvas *canvas, uint32_t argb) {
    canvas->brush->SetColor(D2D1::ColorF(
        ((argb >> 16) & 0xFF) / 255.0f, ((argb >> 8) & 0xFF) / 255.0f, (argb & 0xFF) / 255.0f,
        ((argb >> 24) & 0xFF) / 255.0f));
}

extern "C" void cd2d_set_transform(
    cd2d_canvas *canvas, float offset_x, float offset_y, float rotation_degrees, float pivot_x, float pivot_y) {
    canvas->transform = D2D1::Matrix3x2F::Rotation(rotation_degrees, D2D1::Point2F(pivot_x, pivot_y))
        * D2D1::Matrix3x2F::Translation(offset_x, offset_y);
    canvas->target->SetTransform(canvas->transform);
}

extern "C" void cd2d_move_to(cd2d_canvas *canvas, float x, float y) {
    ID2D1GeometrySink *sink = pathSink(canvas);
    if (!sink) return;
    endFigure(canvas);
    sink->BeginFigure(D2D1::Point2F(x, y), D2D1_FIGURE_BEGIN_HOLLOW);
    canvas->figureOpen = true;
}

extern "C" void cd2d_line_to(cd2d_canvas *canvas, float x, float y) {
    if (!canvas->figureOpen) return;
    canvas->sink->AddLine(D2D1::Point2F(x, y));
}

extern "C" void cd2d_cubic_to(cd2d_canvas *canvas, float c1x, float c1y, float c2x, float c2y, float x, float y) {
    if (!canvas->figureOpen) return;
    canvas->sink->AddBezier(D2D1::BezierSegment(D2D1::Point2F(c1x, c1y), D2D1::Point2F(c2x, c2y), D2D1::Point2F(x, y)));
}

extern "C" void cd2d_stroke(cd2d_canvas *canvas, float width, float dash_on, float dash_off) {
    if (!canvas->sink) return;
    endFigure(canvas);
    canvas->sink->Close();
    canvas->sink.Reset();
    ID2D1StrokeStyle *style = nullptr;
    if (dash_on > 0 && dash_off > 0 && width > 0) {
        // Direct2D measures custom dashes in stroke widths; the stream gives them in pixels.
        style = strokeStyle(canvas->resources, dash_on / width, dash_off / width);
    }
    canvas->target->DrawGeometry(canvas->path.Get(), canvas->brush.Get(), width, style);
    canvas->path.Reset();
}

extern "C" void cd2d_fill_rect(cd2d_canvas *canvas, float x, float y, float width, float height) {
    canvas->target->FillRectangle(D2D1::RectF(x, y, x + width, y + height), canvas->brush.Get());
}

extern "C" void cd2d_fill_glyph(
    cd2d_canvas *canvas, const uint16_t *family, uint32_t codepoint, float x, float y, float size, int32_t bold,
    int32_t italic) {
    cd2d::Face *face = resolveFace(canvas->resources, reinterpret_cast<const wchar_t *>(family), bold != 0, italic != 0);
    if (!face) return;
    ID2D1PathGeometry *outline = glyphOutline(canvas->resources, face->face.Get(), codepoint);
    if (!outline) return;
    const float scale = size / cd2d::kGlyphEm;
    fillGeometry(canvas, outline, D2D1::Matrix3x2F::Scale(scale, scale) * D2D1::Matrix3x2F::Translation(x, y));
}

extern "C" void cd2d_fill_stretched_glyph(
    cd2d_canvas *canvas, const uint16_t *family, uint32_t codepoint, float right_edge_x, float top_y, float bottom_y,
    float size, float x_scale) {
    cd2d::Face *face = resolveFace(canvas->resources, reinterpret_cast<const wchar_t *>(family), false, false);
    if (!face) return;
    ID2D1PathGeometry *outline = glyphOutline(canvas->resources, face->face.Get(), codepoint);
    if (!outline) return;
    // The outline's bounds at `size`: the cached outline is at kGlyphEm, and bounds scale with it.
    D2D1_RECT_F em;
    if (FAILED(outline->GetBounds(nullptr, &em))) return;
    const float scale = size / cd2d::kGlyphEm;
    const D2D1_RECT_F bounds = D2D1::RectF(em.left * scale, em.top * scale, em.right * scale, em.bottom * scale);
    const float width = bounds.right - bounds.left;
    const float height = bounds.bottom - bounds.top;
    if (width <= 0 || height <= 0) return;
    const float scale_y = (bottom_y - top_y) / height;
    const D2D1::Matrix3x2F placement = D2D1::Matrix3x2F::Scale(scale, scale)
        * D2D1::Matrix3x2F(x_scale, 0, 0, scale_y, right_edge_x - bounds.right * x_scale, top_y - bounds.top * scale_y);
    fillGeometry(canvas, outline, placement);
}

extern "C" void cd2d_fill_text(
    cd2d_canvas *canvas, const uint16_t *family, const uint16_t *text, uint32_t length, float x, float y, float size,
    int32_t bold, int32_t italic) {
    const wchar_t *name = reinterpret_cast<const wchar_t *>(family);
    cd2d::Face *face = resolveFace(canvas->resources, name, bold != 0, italic != 0);
    // The face already resolved says which weight and style the family really has, so the layout asks for exactly
    // those and DirectWrite has nothing to synthesize.
    IDWriteTextFormat *format = textFormat(
        canvas->resources, name, face ? face->weight : DWRITE_FONT_WEIGHT_NORMAL,
        face ? face->style : DWRITE_FONT_STYLE_NORMAL, size);
    if (!format) return;
    ComPtr<IDWriteTextLayout> layout;
    HRESULT hr = canvas->resources->dwrite->CreateTextLayout(
        reinterpret_cast<const wchar_t *>(text), length, format, 100000.0f, 100000.0f, &layout);
    if (FAILED(hr)) return;
    DWRITE_LINE_METRICS line;
    UINT32 lines = 0;
    // The glyph runs arrive relative to the layout's top; the stream's y is the first line's baseline.
    float baseline = 0;
    if (SUCCEEDED(layout->GetLineMetrics(&line, 1, &lines)) && lines > 0) {
        baseline = line.baseline;
    }
    OutlineRenderer renderer(canvas, x, y - baseline);
    layout->Draw(nullptr, &renderer, 0, 0);
}

extern "C" int32_t cd2d_write_png(cd2d_canvas *canvas, const uint16_t *path) {
    if (!canvas->bitmap) return E_NOTIMPL;  // only a WIC canvas has pixels to write
    HRESULT hr = S_OK;
    if (canvas->drawing) {
        hr = canvas->target->EndDraw();
        canvas->drawing = false;
        if (FAILED(hr)) return hr;
    }
    cd2d_resources *resources = canvas->resources;
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapEncoder> encoder;
    ComPtr<IWICBitmapFrameEncode> frame;
    hr = resources->wic->CreateStream(&stream);
    if (SUCCEEDED(hr)) hr = stream->InitializeFromFilename(reinterpret_cast<const wchar_t *>(path), GENERIC_WRITE);
    if (SUCCEEDED(hr)) hr = resources->wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    if (SUCCEEDED(hr)) hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
    if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, nullptr);
    if (SUCCEEDED(hr)) hr = frame->Initialize(nullptr);
    if (SUCCEEDED(hr)) hr = frame->WriteSource(canvas->bitmap.Get(), nullptr);
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();
    return hr;
}

extern "C" int32_t cd2d_copy_pixels(cd2d_canvas *canvas, uint8_t *pixels, uint32_t width, uint32_t height) {
    if (!canvas->bitmap) return E_NOTIMPL;
    if (canvas->drawing) {
        HRESULT hr = canvas->target->EndDraw();
        canvas->drawing = false;
        if (FAILED(hr)) return hr;
    }
    return canvas->bitmap->CopyPixels(nullptr, width * 4, width * height * 4, pixels);
}

extern "C" void cd2d_destroy(cd2d_canvas *canvas) {
    if (!canvas) return;
    if (canvas->drawing && canvas->bitmap) {
        canvas->target->EndDraw();
    }
    cd2d_resources *owned = canvas->ownsResources ? canvas->resources : nullptr;
    delete canvas;
    cd2d_resources_destroy(owned);
}
