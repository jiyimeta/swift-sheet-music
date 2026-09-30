// The onscreen half of CDirect2D: a Direct3D 11 device, a swap chain (for a XAML SwapChainPanel or a window), bands
// the page is rasterized into, and frames that blit them. Drawing into a band or a frame goes through the same canvas
// functions as the PNG path (cdirect2d.cpp), from the same shared resources.
#include "cdirect2d_internal.h"

#include <d3d11.h>
#include <dxgi1_3.h>

using cd2d::ComPtr;

struct cd2d_band {
    ComPtr<ID2D1Bitmap1> bitmap;
    uint32_t width = 0;
    uint32_t height = 0;
    uint64_t generation = 0;
    cd2d_canvas canvas;
};

struct cd2d_surface {
    cd2d_resources *resources = nullptr;
    HWND hwnd = nullptr;  // null: a composition swap chain
    uint32_t width = 0;
    uint32_t height = 0;
    float scaleX = 1;
    float scaleY = 1;

    ComPtr<ID3D11Device> d3d;
    ComPtr<IDXGIDevice> dxgiDevice;
    ComPtr<IDXGISwapChain1> swapChain;
    ComPtr<ID2D1Device> device;
    ComPtr<ID2D1DeviceContext> context;
    ComPtr<ID2D1SolidColorBrush> brush;
    ComPtr<ID2D1Bitmap1> backBuffer;

    cd2d_canvas frameCanvas;
    uint64_t generation = 1;
    uint64_t bandBytes = 0;
    HRESULT failNext = S_OK;
    uint8_t *readBack = nullptr;
    uint32_t readBackWidth = 0;
    uint32_t readBackHeight = 0;
};

namespace {

/// Device loss, whichever API reported it, as the one code the caller handles.
HRESULT mapDeviceLoss(HRESULT hr) {
    if (hr == D2DERR_RECREATE_TARGET || hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) {
        return CD2D_E_RECREATE;
    }
    return hr;
}

/// Copies the top-left of a mapped image `sourceWidth` x `sourceHeight` pixels (rows `pitch` bytes apart) into
/// `pixels`, `width` x `height` with rows of `width * 4` bytes. What the image does not cover is left as it was.
void copyRows(
    uint8_t *pixels, uint32_t width, uint32_t height, const uint8_t *source, uint32_t pitch, uint32_t sourceWidth,
    uint32_t sourceHeight) {
    const uint32_t rows = sourceHeight < height ? sourceHeight : height;
    const uint32_t columns = sourceWidth < width ? sourceWidth : width;
    for (uint32_t row = 0; row < rows; ++row) {
        std::memcpy(
            pixels + static_cast<size_t>(row) * width * 4, source + static_cast<size_t>(row) * pitch,
            static_cast<size_t>(columns) * 4);
    }
}

/// Copies the back buffer (the frame just ended, before it is presented) into the probe's buffer.
HRESULT readBackFrame(cd2d_surface *surface) {
    ComPtr<ID3D11Texture2D> buffer;
    HRESULT hr = surface->swapChain->GetBuffer(0, IID_PPV_ARGS(&buffer));
    if (FAILED(hr)) return hr;
    D3D11_TEXTURE2D_DESC desc;
    buffer->GetDesc(&desc);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    ComPtr<ID3D11Texture2D> staging;
    hr = surface->d3d->CreateTexture2D(&desc, nullptr, &staging);
    if (FAILED(hr)) return hr;
    ComPtr<ID3D11DeviceContext> immediate;
    surface->d3d->GetImmediateContext(&immediate);
    immediate->CopyResource(staging.Get(), buffer.Get());
    D3D11_MAPPED_SUBRESOURCE mapped;
    hr = immediate->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) return hr;
    copyRows(
        surface->readBack, surface->readBackWidth, surface->readBackHeight, static_cast<const uint8_t *>(mapped.pData),
        mapped.RowPitch, desc.Width, desc.Height);
    immediate->Unmap(staging.Get(), 0);
    return S_OK;
}

HRESULT consumeFailNext(cd2d_surface *surface, HRESULT hr) {
    if (surface->failNext != S_OK) {
        hr = surface->failNext;
        surface->failNext = S_OK;
    }
    return hr;
}

/// The swap chain's transform that undoes the panel's composition scale (composition swap chains only).
HRESULT applyScale(cd2d_surface *surface) {
    if (surface->hwnd) return S_OK;
    ComPtr<IDXGISwapChain2> swapChain2;
    HRESULT hr = surface->swapChain.As(&swapChain2);
    if (FAILED(hr)) return hr;
    DXGI_MATRIX_3X2_F inverse = {};
    inverse._11 = 1.0f / surface->scaleX;
    inverse._22 = 1.0f / surface->scaleY;
    return swapChain2->SetMatrixTransform(&inverse);
}

HRESULT createDevice(cd2d_surface *surface) {
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1};
    HRESULT hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 3, D3D11_SDK_VERSION,
        &surface->d3d, nullptr, nullptr);
    if (FAILED(hr)) {
        // No usable GPU driver: WARP renders the same thing in software.
        hr = D3D11CreateDevice(
            nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 3, D3D11_SDK_VERSION,
            &surface->d3d, nullptr, nullptr);
    }
    if (SUCCEEDED(hr)) hr = surface->d3d.As(&surface->dxgiDevice);
    if (SUCCEEDED(hr)) hr = surface->resources->d2d->CreateDevice(surface->dxgiDevice.Get(), &surface->device);
    if (SUCCEEDED(hr)) {
        hr = surface->device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &surface->context);
    }
    if (SUCCEEDED(hr)) {
        // 96 DPI: one Direct2D unit is one physical pixel, as on the WIC canvas.
        surface->context->SetDpi(96.0f, 96.0f);
        hr = surface->context->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &surface->brush);
    }
    return hr;
}

HRESULT createSwapChain(cd2d_surface *surface) {
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<IDXGIFactory2> factory;
    HRESULT hr = surface->dxgiDevice->GetAdapter(&adapter);
    if (SUCCEEDED(hr)) hr = adapter->GetParent(IID_PPV_ARGS(&factory));
    if (FAILED(hr)) return hr;
    DXGI_SWAP_CHAIN_DESC1 desc = {};
    desc.Width = surface->width;
    desc.Height = surface->height;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    if (surface->hwnd) {
        desc.Scaling = DXGI_SCALING_NONE;
        hr = factory->CreateSwapChainForHwnd(surface->d3d.Get(), surface->hwnd, &desc, nullptr, nullptr, &surface->swapChain);
    } else {
        desc.Scaling = DXGI_SCALING_STRETCH;
        hr = factory->CreateSwapChainForComposition(surface->d3d.Get(), &desc, nullptr, &surface->swapChain);
    }
    if (SUCCEEDED(hr)) hr = applyScale(surface);
    return hr;
}

void releaseDevice(cd2d_surface *surface) {
    if (surface->context) surface->context->SetTarget(nullptr);
    surface->backBuffer.Reset();
    surface->brush.Reset();
    surface->context.Reset();
    surface->device.Reset();
    surface->swapChain.Reset();
    // A flip-model swap chain is destroyed lazily, and a window can own only one: until the immediate context lets go
    // of it, CreateSwapChainForHwnd on the same window fails and the recreated surface has no swap chain at all.
    if (surface->d3d) {
        ComPtr<ID3D11DeviceContext> immediate;
        surface->d3d->GetImmediateContext(&immediate);
        if (immediate) {
            immediate->ClearState();
            immediate->Flush();
        }
    }
    surface->dxgiDevice.Reset();
    surface->d3d.Reset();
}

/// A surface whose last recreate failed has no device: every entry point that draws reports it as lost again, so the
/// host's next frame retries the recreate instead of dereferencing what is not there.
bool hasDevice(const cd2d_surface *surface) {
    return surface->swapChain && surface->context && surface->brush;
}

HRESULT create(cd2d_surface **out, cd2d_resources *resources, HWND hwnd, uint32_t width, uint32_t height, float sx,
               float sy) {
    *out = nullptr;
    auto surface = new cd2d_surface();
    surface->resources = resources;
    surface->hwnd = hwnd;
    surface->width = width > 0 ? width : 1;
    surface->height = height > 0 ? height : 1;
    surface->scaleX = sx > 0 ? sx : 1;
    surface->scaleY = sy > 0 ? sy : 1;
    surface->frameCanvas.resources = resources;
    HRESULT hr = createDevice(surface);
    if (SUCCEEDED(hr)) hr = createSwapChain(surface);
    if (FAILED(hr)) {
        releaseDevice(surface);
        delete surface;
        return hr;
    }
    *out = surface;
    return S_OK;
}

}  // namespace

extern "C" int32_t cd2d_surface_create_composition(
    cd2d_surface **out, cd2d_resources *resources, uint32_t width, uint32_t height, float scale_x, float scale_y,
    void **swap_chain) {
    *swap_chain = nullptr;
    HRESULT hr = create(out, resources, nullptr, width, height, scale_x, scale_y);
    if (FAILED(hr)) return hr;
    (*out)->swapChain->AddRef();
    *swap_chain = (*out)->swapChain.Get();
    return S_OK;
}

extern "C" int32_t cd2d_surface_create_hwnd(
    cd2d_surface **out, cd2d_resources *resources, void *hwnd, uint32_t width, uint32_t height) {
    return create(out, resources, static_cast<HWND>(hwnd), width, height, 1, 1);
}

extern "C" int32_t cd2d_surface_resize(
    cd2d_surface *surface, uint32_t width, uint32_t height, float scale_x, float scale_y) {
    surface->width = width > 0 ? width : 1;
    surface->height = height > 0 ? height : 1;
    surface->scaleX = scale_x > 0 ? scale_x : 1;
    surface->scaleY = scale_y > 0 ? scale_y : 1;
    // The size is kept either way: a recreate builds the swap chain at it.
    if (!hasDevice(surface)) return CD2D_E_RECREATE;
    // Every reference to a buffer has to go before ResizeBuffers.
    surface->context->SetTarget(nullptr);
    surface->backBuffer.Reset();
    HRESULT hr = surface->swapChain->ResizeBuffers(0, surface->width, surface->height, DXGI_FORMAT_UNKNOWN, 0);
    if (SUCCEEDED(hr)) hr = applyScale(surface);
    return mapDeviceLoss(hr);
}

extern "C" int32_t cd2d_surface_recreate(cd2d_surface *surface, void **swap_chain) {
    *swap_chain = nullptr;
    releaseDevice(surface);
    surface->generation += 1;  // every band made on the old device is now unusable
    HRESULT hr = createDevice(surface);
    if (SUCCEEDED(hr)) hr = createSwapChain(surface);
    if (FAILED(hr)) return hr;
    if (!surface->hwnd) {
        surface->swapChain->AddRef();
        *swap_chain = surface->swapChain.Get();
    }
    return S_OK;
}

extern "C" void cd2d_surface_debug_fail_next(cd2d_surface *surface, int32_t hresult) {
    surface->failNext = hresult;
}

extern "C" uint64_t cd2d_surface_band_bytes(cd2d_surface *surface) {
    return surface->bandBytes;
}

extern "C" void cd2d_surface_destroy(cd2d_surface *surface) {
    if (!surface) return;
    releaseDevice(surface);
    delete surface;
}

// MARK: - Bands

extern "C" int32_t cd2d_band_begin(
    cd2d_surface *surface, uint32_t width, uint32_t height, cd2d_band **out, cd2d_canvas **canvas) {
    *out = nullptr;
    *canvas = nullptr;
    if (!hasDevice(surface)) return CD2D_E_RECREATE;
    auto band = new cd2d_band();
    band->width = width;
    band->height = height;
    band->generation = surface->generation;
    band->canvas.resources = surface->resources;
    const D2D1_BITMAP_PROPERTIES1 properties = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        96.0f, 96.0f);
    HRESULT hr = surface->context->CreateBitmap(D2D1::SizeU(width, height), nullptr, 0, properties, &band->bitmap);
    if (FAILED(hr)) {
        delete band;
        return mapDeviceLoss(hr);
    }
    surface->bandBytes += static_cast<uint64_t>(width) * height * 4;
    surface->context->SetTarget(band->bitmap.Get());
    surface->context->BeginDraw();
    cd2d::resetCanvas(&band->canvas, surface->context.Get(), surface->brush.Get());
    band->canvas.drawing = true;
    surface->context->Clear(D2D1::ColorF(1, 1, 1, 1));
    *out = band;
    *canvas = &band->canvas;
    return S_OK;
}

extern "C" int32_t cd2d_band_end(cd2d_surface *surface, cd2d_band *band) {
    band->canvas.drawing = false;
    HRESULT hr = surface->context->EndDraw();
    surface->context->SetTarget(nullptr);
    band->canvas.target.Reset();
    band->canvas.brush.Reset();
    return mapDeviceLoss(consumeFailNext(surface, hr));
}

extern "C" int32_t cd2d_band_read_back(
    cd2d_surface *surface, cd2d_band *band, uint8_t *pixels, uint32_t width, uint32_t height) {
    if (!band || band->generation != surface->generation || !hasDevice(surface)) return CD2D_E_RECREATE;
    // A bitmap the CPU can map cannot be a target or drawn, only copied into: the band's own format, so the copy is
    // byte for byte.
    const D2D1_BITMAP_PROPERTIES1 properties = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
    ComPtr<ID2D1Bitmap1> staging;
    HRESULT hr = surface->context->CreateBitmap(
        D2D1::SizeU(band->width, band->height), nullptr, 0, properties, &staging);
    if (SUCCEEDED(hr)) hr = staging->CopyFromBitmap(nullptr, band->bitmap.Get(), nullptr);
    if (FAILED(hr)) return mapDeviceLoss(hr);
    D2D1_MAPPED_RECT mapped;
    hr = staging->Map(D2D1_MAP_OPTIONS_READ, &mapped);
    if (FAILED(hr)) return mapDeviceLoss(hr);
    copyRows(pixels, width, height, mapped.bits, mapped.pitch, band->width, band->height);
    staging->Unmap();
    return S_OK;
}

extern "C" void cd2d_band_release(cd2d_surface *surface, cd2d_band *band) {
    if (!band) return;
    const uint64_t bytes = static_cast<uint64_t>(band->width) * band->height * 4;
    surface->bandBytes = surface->bandBytes >= bytes ? surface->bandBytes - bytes : 0;
    delete band;
}

// MARK: - Frames

extern "C" int32_t cd2d_frame_begin(cd2d_surface *surface, uint32_t background_argb) {
    if (!hasDevice(surface)) return CD2D_E_RECREATE;
    HRESULT hr = S_OK;
    if (!surface->backBuffer) {
        ComPtr<IDXGISurface> buffer;
        hr = surface->swapChain->GetBuffer(0, IID_PPV_ARGS(&buffer));
        if (SUCCEEDED(hr)) {
            const D2D1_BITMAP_PROPERTIES1 properties = D2D1::BitmapProperties1(
                D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 96.0f, 96.0f);
            hr = surface->context->CreateBitmapFromDxgiSurface(buffer.Get(), &properties, &surface->backBuffer);
        }
        if (FAILED(hr)) return mapDeviceLoss(hr);
    }
    surface->context->SetTarget(surface->backBuffer.Get());
    surface->context->BeginDraw();
    cd2d::resetCanvas(&surface->frameCanvas, surface->context.Get(), surface->brush.Get());
    surface->frameCanvas.drawing = true;
    surface->context->Clear(D2D1::ColorF(
        ((background_argb >> 16) & 0xFF) / 255.0f, ((background_argb >> 8) & 0xFF) / 255.0f,
        (background_argb & 0xFF) / 255.0f, 1.0f));
    return S_OK;
}

extern "C" void cd2d_frame_draw_band(cd2d_surface *surface, cd2d_band *band, float x, float y, float scale) {
    if (!band || band->generation != surface->generation) return;
    surface->context->SetTransform(D2D1::Matrix3x2F::Identity());
    const D2D1_RECT_F destination = D2D1::RectF(x, y, x + band->width * scale, y + band->height * scale);
    surface->context->DrawBitmap(
        band->bitmap.Get(), destination, 1.0f,
        scale == 1.0f ? D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR : D2D1_INTERPOLATION_MODE_LINEAR, nullptr);
    surface->context->SetTransform(surface->frameCanvas.transform);
}

extern "C" cd2d_canvas *cd2d_frame_canvas(cd2d_surface *surface) {
    return &surface->frameCanvas;
}

extern "C" int32_t cd2d_frame_present(cd2d_surface *surface) {
    surface->frameCanvas.drawing = false;
    HRESULT hr = consumeFailNext(surface, surface->context->EndDraw());
    surface->context->SetTarget(nullptr);
    if (FAILED(hr)) return mapDeviceLoss(hr);
    if (surface->readBack) {
        hr = readBackFrame(surface);
        surface->readBack = nullptr;
        if (FAILED(hr)) return mapDeviceLoss(hr);
    }
    return mapDeviceLoss(surface->swapChain->Present(1, 0));
}

extern "C" void cd2d_surface_debug_read_back_next(
    cd2d_surface *surface, uint8_t *pixels, uint32_t width, uint32_t height) {
    surface->readBack = pixels;
    surface->readBackWidth = width;
    surface->readBackHeight = height;
}
