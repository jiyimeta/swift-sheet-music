// PDF pages through the OS's own renderer: the document loaded by Windows.Data.Pdf (WinRT, reached over its ABI with
// WRL — the module map has no WinRT projection), drawn by the Direct2D interop (`IPdfRendererNative`). The surface draws
// a page into a band (cdirect2d_surface.cpp); this file loads documents and draws a page alone for tests and
// thumbnails. Measured on the QA machine: a page costs what its content costs, whatever part of it is drawn (folino's
// spec 2026-10-05-windows-phase4-import-export-pdf-design.md §5.3).
#include "cdirect2d_internal.h"

#include <d3d11.h>
#include <roapi.h>
#include <windows.data.pdf.h>
#include <windows.data.pdf.interop.h>
#include <windows.storage.h>
#include <wrl/wrappers/corewrappers.h>

#include <vector>

using cd2d::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;
namespace Foundation = ABI::Windows::Foundation;
namespace Storage = ABI::Windows::Storage;
namespace Pdf = ABI::Windows::Data::Pdf;

struct cd2d_pdf {
    ComPtr<Pdf::IPdfDocument> document;
};

namespace {

/// Waits for a WinRT async operation by polling its status: nothing here runs a message loop or resumes a coroutine.
template <typename Operation> HRESULT wait(Operation *operation) {
    ComPtr<Foundation::IAsyncInfo> info;
    HRESULT hr = operation->QueryInterface(IID_PPV_ARGS(&info));
    if (FAILED(hr)) return hr;
    Foundation::AsyncStatus status = Foundation::AsyncStatus::Started;
    while (SUCCEEDED(hr = info->get_Status(&status)) && status == Foundation::AsyncStatus::Started) {
        Sleep(1);
    }
    if (FAILED(hr)) return hr;
    if (status != Foundation::AsyncStatus::Completed) {
        HRESULT error = E_FAIL;
        info->get_ErrorCode(&error);
        return FAILED(error) ? error : E_FAIL;
    }
    return S_OK;
}

/// A device of its own for drawing a page off screen: hardware, or WARP where there is none.
struct OffscreenDevice {
    ComPtr<ID3D11Device> d3d;
    ComPtr<IDXGIDevice> dxgi;
    ComPtr<ID2D1Factory1> factory;
    ComPtr<ID2D1Device> device;
    ComPtr<ID2D1DeviceContext> context;
    ComPtr<IPdfRendererNative> renderer;

    HRESULT create() {
        const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1};
        HRESULT hr = D3D11CreateDevice(
            nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 3,
            D3D11_SDK_VERSION, &d3d, nullptr, nullptr);
        if (FAILED(hr)) {
            hr = D3D11CreateDevice(
                nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 3,
                D3D11_SDK_VERSION, &d3d, nullptr, nullptr);
        }
        if (SUCCEEDED(hr)) hr = d3d.As(&dxgi);
        if (SUCCEEDED(hr)) hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, factory.GetAddressOf());
        if (SUCCEEDED(hr)) hr = factory->CreateDevice(dxgi.Get(), &device);
        if (SUCCEEDED(hr)) hr = device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &context);
        if (SUCCEEDED(hr)) context->SetDpi(96.0f, 96.0f);
        if (SUCCEEDED(hr)) hr = PdfCreateRenderer(dxgi.Get(), &renderer);
        return hr;
    }
};

/// Page `index` drawn whole on white at `scale` px per DIP into `pixels` (BGRA premultiplied, rows of `width * 4`).
HRESULT renderPixels(
    cd2d_pdf *pdf, uint32_t index, float scale, uint8_t *pixels, uint32_t width, uint32_t height) {
    OffscreenDevice offscreen;
    HRESULT hr = offscreen.create();
    ComPtr<IUnknown> page;
    if (SUCCEEDED(hr)) hr = cd2d::pdfPage(pdf, index, &page);
    if (FAILED(hr)) return hr;
    const D2D1_PIXEL_FORMAT format = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED);
    ComPtr<ID2D1Bitmap1> target;
    ComPtr<ID2D1Bitmap1> readback;
    const auto targetProperties = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW, format, 96.0f, 96.0f);
    hr = offscreen.context->CreateBitmap(D2D1::SizeU(width, height), nullptr, 0, targetProperties, &target);
    const auto readbackProperties = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW, format, 96.0f, 96.0f);
    if (SUCCEEDED(hr)) {
        hr = offscreen.context->CreateBitmap(D2D1::SizeU(width, height), nullptr, 0, readbackProperties, &readback);
    }
    if (FAILED(hr)) return hr;
    offscreen.context->SetTarget(target.Get());
    offscreen.context->BeginDraw();
    offscreen.context->Clear(D2D1::ColorF(1, 1, 1, 1));
    offscreen.context->SetTransform(D2D1::Matrix3x2F::Scale(scale, scale));
    hr = offscreen.renderer->RenderPageToDeviceContext(page.Get(), offscreen.context.Get(), nullptr);
    const HRESULT ended = offscreen.context->EndDraw();
    if (SUCCEEDED(hr)) hr = ended;
    offscreen.context->SetTarget(nullptr);
    if (SUCCEEDED(hr)) hr = readback->CopyFromBitmap(nullptr, target.Get(), nullptr);
    D2D1_MAPPED_RECT mapped = {};
    if (SUCCEEDED(hr)) hr = readback->Map(D2D1_MAP_OPTIONS_READ, &mapped);
    if (FAILED(hr)) return hr;
    for (uint32_t row = 0; row < height; ++row) {
        std::memcpy(pixels + static_cast<size_t>(row) * width * 4, mapped.bits + static_cast<size_t>(row) * mapped.pitch,
                    static_cast<size_t>(width) * 4);
    }
    readback->Unmap();
    return S_OK;
}

}  // namespace

HRESULT cd2d::pdfPage(cd2d_pdf *pdf, uint32_t index, IUnknown **page) {
    ComPtr<Pdf::IPdfPage> pdfPage;
    HRESULT hr = pdf->document->GetPage(index, &pdfPage);
    if (FAILED(hr)) return hr;
    return pdfPage.CopyTo(page);
}

extern "C" int32_t cd2d_pdf_open(const uint16_t *path, cd2d_pdf **out, uint32_t *page_count) {
    *out = nullptr;
    *page_count = 0;
    // A thread with no apartment joins the multithreaded one; one that already has an apartment keeps it.
    HRESULT hr = RoInitialize(RO_INIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return hr;
    const auto *widePath = reinterpret_cast<const wchar_t *>(path);
    ComPtr<Storage::IStorageFileStatics> files;
    hr = RoGetActivationFactory(HStringReference(RuntimeClass_Windows_Storage_StorageFile).Get(), IID_PPV_ARGS(&files));
    ComPtr<Foundation::IAsyncOperation<Storage::StorageFile *>> fileOperation;
    if (SUCCEEDED(hr)) {
        hr = files->GetFileFromPathAsync(
            HStringReference(widePath, static_cast<unsigned int>(wcslen(widePath))).Get(), &fileOperation);
    }
    if (SUCCEEDED(hr)) hr = wait(fileOperation.Get());
    ComPtr<Storage::IStorageFile> file;
    if (SUCCEEDED(hr)) hr = fileOperation->GetResults(&file);
    ComPtr<Pdf::IPdfDocumentStatics> documents;
    if (SUCCEEDED(hr)) {
        hr = RoGetActivationFactory(
            HStringReference(RuntimeClass_Windows_Data_Pdf_PdfDocument).Get(), IID_PPV_ARGS(&documents));
    }
    ComPtr<Foundation::IAsyncOperation<Pdf::PdfDocument *>> documentOperation;
    if (SUCCEEDED(hr)) hr = documents->LoadFromFileAsync(file.Get(), &documentOperation);
    if (SUCCEEDED(hr)) hr = wait(documentOperation.Get());
    auto pdf = new cd2d_pdf();
    if (SUCCEEDED(hr)) hr = documentOperation->GetResults(&pdf->document);
    UINT32 count = 0;
    if (SUCCEEDED(hr)) hr = pdf->document->get_PageCount(&count);
    if (FAILED(hr)) {
        delete pdf;
        return hr;
    }
    *out = pdf;
    *page_count = count;
    return S_OK;
}

extern "C" void cd2d_pdf_close(cd2d_pdf *pdf) {
    delete pdf;
}

extern "C" int32_t cd2d_pdf_page_size(cd2d_pdf *pdf, uint32_t index, float *width, float *height) {
    ComPtr<Pdf::IPdfPage> page;
    HRESULT hr = pdf->document->GetPage(index, &page);
    Foundation::Size size = {};
    if (SUCCEEDED(hr)) hr = page->get_Size(&size);
    *width = size.Width;
    *height = size.Height;
    return hr;
}

extern "C" int32_t cd2d_pdf_render_pixels(
    cd2d_pdf *pdf, uint32_t page, float scale, uint8_t *pixels, uint32_t width, uint32_t height) {
    return renderPixels(pdf, page, scale, pixels, width, height);
}

extern "C" int32_t cd2d_pdf_write_png(cd2d_pdf *pdf, uint32_t page, float scale, const uint16_t *path) {
    float widthDIP = 0;
    float heightDIP = 0;
    HRESULT hr = cd2d_pdf_page_size(pdf, page, &widthDIP, &heightDIP);
    if (FAILED(hr)) return hr;
    const uint32_t width = static_cast<uint32_t>(widthDIP * scale + 0.999f);
    const uint32_t height = static_cast<uint32_t>(heightDIP * scale + 0.999f);
    if (width == 0 || height == 0) return E_INVALIDARG;
    std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4);
    hr = renderPixels(pdf, page, scale, pixels.data(), width, height);
    if (FAILED(hr)) return hr;
    ComPtr<IWICImagingFactory> wic;
    hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic));
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapEncoder> encoder;
    ComPtr<IWICBitmapFrameEncode> frame;
    if (SUCCEEDED(hr)) hr = wic->CreateStream(&stream);
    if (SUCCEEDED(hr)) hr = stream->InitializeFromFilename(reinterpret_cast<const wchar_t *>(path), GENERIC_WRITE);
    if (SUCCEEDED(hr)) hr = wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    if (SUCCEEDED(hr)) hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
    if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, nullptr);
    if (SUCCEEDED(hr)) hr = frame->Initialize(nullptr);
    if (SUCCEEDED(hr)) hr = frame->SetSize(width, height);
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppPBGRA;
    if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
    if (SUCCEEDED(hr)) {
        hr = frame->WritePixels(height, width * 4, static_cast<UINT>(pixels.size()), pixels.data());
    }
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();
    return hr;
}
