#include <windows.h>
#include <d2d1.h>
#include <dwrite_3.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <map>
#include <string>
#include <tuple>

#include "cdirect2d.h"

using Microsoft::WRL::ComPtr;

namespace {

/// One resolved face per (family, bold, italic), cached for the canvas's life.
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

}  // namespace

struct cd2d_canvas {
    ComPtr<ID2D1Factory> d2d;
    ComPtr<IDWriteFactory5> dwrite;
    ComPtr<IWICImagingFactory> wic;
    ComPtr<IWICBitmap> bitmap;
    ComPtr<ID2D1RenderTarget> target;
    ComPtr<ID2D1SolidColorBrush> brush;
    ComPtr<IDWriteFontSetBuilder1> fontBuilder;
    ComPtr<IDWriteFontCollection1> fonts;
    std::map<FaceKey, Face> faces;

    ComPtr<ID2D1PathGeometry> path;
    ComPtr<ID2D1GeometrySink> sink;
    bool figureOpen = false;
    D2D1::Matrix3x2F transform = D2D1::Matrix3x2F::Identity();
    bool drawing = false;
};

namespace {

/// Fills `geometry` under `placement` (then the canvas transform).
void fillGeometry(cd2d_canvas *canvas, ID2D1Geometry *geometry, const D2D1::Matrix3x2F &placement) {
    canvas->target->SetTransform(placement * canvas->transform);
    canvas->target->FillGeometry(geometry, canvas->brush.Get());
    canvas->target->SetTransform(canvas->transform);
}

/// The family's face for the requested weight and style, or its regular face when the family has no such face:
/// DirectWrite would otherwise synthesize one, which CoreText (the Mac reference) does not.
Face *resolveFace(cd2d_canvas *canvas, const wchar_t *family, bool bold, bool italic) {
    FaceKey key{family, bold, italic};
    auto found = canvas->faces.find(key);
    if (found != canvas->faces.end()) {
        return found->second.face ? &found->second : nullptr;
    }
    Face resolved;
    UINT32 index = 0;
    BOOL exists = FALSE;
    if (canvas->fonts && SUCCEEDED(canvas->fonts->FindFamilyName(family, &index, &exists)) && exists) {
        // IDWriteFontFamily1: IDWriteFontCollection1's GetFontFamily hides the base overload that takes the older type.
        ComPtr<IDWriteFontFamily1> fontFamily;
        if (SUCCEEDED(canvas->fonts->GetFontFamily(index, &fontFamily))) {
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
    auto inserted = canvas->faces.emplace(key, resolved);
    return inserted.first->second.face ? &inserted.first->second : nullptr;
}

/// The outline of one glyph at `size` pixels, baseline origin at (0, 0), Y down.
ComPtr<ID2D1PathGeometry> glyphOutline(cd2d_canvas *canvas, IDWriteFontFace *face, uint32_t codepoint, float size) {
    UINT16 glyph = 0;
    if (FAILED(face->GetGlyphIndices(&codepoint, 1, &glyph)) || glyph == 0) {
        return nullptr;
    }
    ComPtr<ID2D1PathGeometry> geometry;
    ComPtr<ID2D1GeometrySink> sink;
    if (FAILED(canvas->d2d->CreatePathGeometry(&geometry)) || FAILED(geometry->Open(&sink))) {
        return nullptr;
    }
    face->GetGlyphRunOutline(size, &glyph, nullptr, nullptr, 1, FALSE, FALSE, sink.Get());
    sink->Close();
    return geometry;
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
        HRESULT hr = canvas_->d2d->CreatePathGeometry(&geometry);
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
        if (FAILED(canvas->d2d->CreatePathGeometry(&canvas->path)) || FAILED(canvas->path->Open(&canvas->sink))) {
            canvas->path.Reset();
            canvas->sink.Reset();
            return nullptr;
        }
    }
    return canvas->sink.Get();
}

}  // namespace

extern "C" int32_t cd2d_create(cd2d_canvas **out, uint32_t width, uint32_t height) {
    *out = nullptr;
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return hr;

    auto canvas = new cd2d_canvas();
    hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, canvas->d2d.GetAddressOf());
    if (SUCCEEDED(hr)) {
        hr = DWriteCreateFactory(
            DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory5),
            reinterpret_cast<IUnknown **>(canvas->dwrite.GetAddressOf()));
    }
    if (SUCCEEDED(hr)) hr = canvas->dwrite->CreateFontSetBuilder(&canvas->fontBuilder);
    if (SUCCEEDED(hr)) {
        hr = CoCreateInstance(
            CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&canvas->wic));
    }
    if (SUCCEEDED(hr)) {
        hr = canvas->wic->CreateBitmap(
            width, height, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, &canvas->bitmap);
    }
    if (SUCCEEDED(hr)) {
        D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties(
            D2D1_RENDER_TARGET_TYPE_DEFAULT,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
        hr = canvas->d2d->CreateWicBitmapRenderTarget(canvas->bitmap.Get(), properties, &canvas->target);
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

extern "C" int32_t cd2d_add_font_file(cd2d_canvas *canvas, const uint16_t *path) {
    ComPtr<IDWriteFontFile> file;
    HRESULT hr = canvas->dwrite->CreateFontFileReference(reinterpret_cast<const wchar_t *>(path), nullptr, &file);
    if (SUCCEEDED(hr)) hr = canvas->fontBuilder->AddFontFile(file.Get());
    return hr;
}

extern "C" int32_t cd2d_fonts_ready(cd2d_canvas *canvas) {
    ComPtr<IDWriteFontSet> set;
    HRESULT hr = canvas->fontBuilder->CreateFontSet(&set);
    if (SUCCEEDED(hr)) hr = canvas->dwrite->CreateFontCollectionFromFontSet(set.Get(), &canvas->fonts);
    canvas->faces.clear();
    return hr;
}

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
    ComPtr<ID2D1StrokeStyle> style;
    if (dash_on > 0 && dash_off > 0 && width > 0) {
        // Direct2D measures custom dashes in stroke widths; the stream gives them in pixels.
        const FLOAT dashes[] = {dash_on / width, dash_off / width};
        canvas->d2d->CreateStrokeStyle(
            D2D1::StrokeStyleProperties(
                D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_LINE_JOIN_MITER, 10.0f,
                D2D1_DASH_STYLE_CUSTOM, 0.0f),
            dashes, 2, &style);
    }
    canvas->target->DrawGeometry(canvas->path.Get(), canvas->brush.Get(), width, style.Get());
    canvas->path.Reset();
}

extern "C" void cd2d_fill_rect(cd2d_canvas *canvas, float x, float y, float width, float height) {
    canvas->target->FillRectangle(D2D1::RectF(x, y, x + width, y + height), canvas->brush.Get());
}

extern "C" void cd2d_fill_glyph(
    cd2d_canvas *canvas, const uint16_t *family, uint32_t codepoint, float x, float y, float size, int32_t bold,
    int32_t italic) {
    Face *face = resolveFace(canvas, reinterpret_cast<const wchar_t *>(family), bold != 0, italic != 0);
    if (!face) return;
    ComPtr<ID2D1PathGeometry> outline = glyphOutline(canvas, face->face.Get(), codepoint, size);
    if (!outline) return;
    fillGeometry(canvas, outline.Get(), D2D1::Matrix3x2F::Translation(x, y));
}

extern "C" void cd2d_fill_stretched_glyph(
    cd2d_canvas *canvas, const uint16_t *family, uint32_t codepoint, float right_edge_x, float top_y, float bottom_y,
    float size, float x_scale) {
    Face *face = resolveFace(canvas, reinterpret_cast<const wchar_t *>(family), false, false);
    if (!face) return;
    ComPtr<ID2D1PathGeometry> outline = glyphOutline(canvas, face->face.Get(), codepoint, size);
    if (!outline) return;
    D2D1_RECT_F bounds;
    if (FAILED(outline->GetBounds(nullptr, &bounds))) return;
    const float width = bounds.right - bounds.left;
    const float height = bounds.bottom - bounds.top;
    if (width <= 0 || height <= 0) return;
    const float scale_y = (bottom_y - top_y) / height;
    const D2D1::Matrix3x2F placement = D2D1::Matrix3x2F(
        x_scale, 0, 0, scale_y, right_edge_x - bounds.right * x_scale, top_y - bounds.top * scale_y);
    fillGeometry(canvas, outline.Get(), placement);
}

extern "C" void cd2d_fill_text(
    cd2d_canvas *canvas, const uint16_t *family, const uint16_t *text, uint32_t length, float x, float y, float size,
    int32_t bold, int32_t italic) {
    const wchar_t *name = reinterpret_cast<const wchar_t *>(family);
    Face *face = resolveFace(canvas, name, bold != 0, italic != 0);
    // The face already resolved says which weight and style the family really has, so the layout asks for exactly
    // those and DirectWrite has nothing to synthesize.
    ComPtr<IDWriteTextFormat> format;
    HRESULT hr = canvas->dwrite->CreateTextFormat(
        name, canvas->fonts.Get(), face ? face->weight : DWRITE_FONT_WEIGHT_NORMAL,
        face ? face->style : DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"en-us", &format);
    if (FAILED(hr)) return;
    format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    ComPtr<IDWriteTextLayout> layout;
    hr = canvas->dwrite->CreateTextLayout(
        reinterpret_cast<const wchar_t *>(text), length, format.Get(), 100000.0f, 100000.0f, &layout);
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
    HRESULT hr = S_OK;
    if (canvas->drawing) {
        hr = canvas->target->EndDraw();
        canvas->drawing = false;
        if (FAILED(hr)) return hr;
    }
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapEncoder> encoder;
    ComPtr<IWICBitmapFrameEncode> frame;
    hr = canvas->wic->CreateStream(&stream);
    if (SUCCEEDED(hr)) hr = stream->InitializeFromFilename(reinterpret_cast<const wchar_t *>(path), GENERIC_WRITE);
    if (SUCCEEDED(hr)) hr = canvas->wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    if (SUCCEEDED(hr)) hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
    if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, nullptr);
    if (SUCCEEDED(hr)) hr = frame->Initialize(nullptr);
    if (SUCCEEDED(hr)) hr = frame->WriteSource(canvas->bitmap.Get(), nullptr);
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();
    return hr;
}

extern "C" void cd2d_destroy(cd2d_canvas *canvas) {
    if (!canvas) return;
    if (canvas->drawing) {
        canvas->target->EndDraw();
    }
    delete canvas;
}
