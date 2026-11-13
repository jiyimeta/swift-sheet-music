#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <stdlib.h>
#include <string.h>

#include "cmediafoundation.h"

// Media Foundation's entry points, looked up once in DLLs loaded at run time (see the header for why).
typedef HRESULT(WINAPI *mf_startup_fn)(ULONG, DWORD);
typedef HRESULT(WINAPI *mf_shutdown_fn)(void);
typedef HRESULT(WINAPI *mf_create_media_type_fn)(IMFMediaType **);
typedef HRESULT(WINAPI *mf_create_attributes_fn)(IMFAttributes **, UINT32);
typedef HRESULT(WINAPI *mf_create_memory_buffer_fn)(DWORD, IMFMediaBuffer **);
typedef HRESULT(WINAPI *mf_create_sample_fn)(IMFSample **);
typedef HRESULT(WINAPI *mf_tenum_ex_fn)(GUID, UINT32, const MFT_REGISTER_TYPE_INFO *,
                                        const MFT_REGISTER_TYPE_INFO *, IMFActivate ***, UINT32 *);
typedef HRESULT(WINAPI *mf_create_sink_writer_fn)(LPCWSTR, IMFByteStream *, IMFAttributes *, IMFSinkWriter **);
typedef HRESULT(WINAPI *mf_create_source_reader_fn)(LPCWSTR, IMFAttributes *, IMFSourceReader **);

static struct {
    INIT_ONCE once;
    BOOL loaded;
    mf_startup_fn startup;
    mf_shutdown_fn shutdown;
    mf_create_media_type_fn create_media_type;
    mf_create_attributes_fn create_attributes;
    mf_create_memory_buffer_fn create_memory_buffer;
    mf_create_sample_fn create_sample;
    mf_tenum_ex_fn tenum_ex;
    mf_create_sink_writer_fn create_sink_writer;
    /// Only `cmf_mp4_probe` (a test's read-back) needs it, so its absence does not unload the rest.
    mf_create_source_reader_fn create_source_reader;
} mf = {INIT_ONCE_STATIC_INIT};

static BOOL CALLBACK load_mf(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once;
    (void)parameter;
    (void)context;
    HMODULE plat = LoadLibraryW(L"mfplat.dll");
    HMODULE readwrite = LoadLibraryW(L"mfreadwrite.dll");
    if (plat == NULL || readwrite == NULL) return TRUE;
    mf.startup = (mf_startup_fn)GetProcAddress(plat, "MFStartup");
    mf.shutdown = (mf_shutdown_fn)GetProcAddress(plat, "MFShutdown");
    mf.create_media_type = (mf_create_media_type_fn)GetProcAddress(plat, "MFCreateMediaType");
    mf.create_attributes = (mf_create_attributes_fn)GetProcAddress(plat, "MFCreateAttributes");
    mf.create_memory_buffer = (mf_create_memory_buffer_fn)GetProcAddress(plat, "MFCreateMemoryBuffer");
    mf.create_sample = (mf_create_sample_fn)GetProcAddress(plat, "MFCreateSample");
    mf.tenum_ex = (mf_tenum_ex_fn)GetProcAddress(plat, "MFTEnumEx");
    mf.create_sink_writer = (mf_create_sink_writer_fn)GetProcAddress(readwrite, "MFCreateSinkWriterFromURL");
    mf.create_source_reader = (mf_create_source_reader_fn)GetProcAddress(readwrite, "MFCreateSourceReaderFromURL");
    mf.loaded = mf.startup && mf.shutdown && mf.create_media_type && mf.create_attributes &&
                mf.create_memory_buffer && mf.create_sample && mf.tenum_ex && mf.create_sink_writer;
    return TRUE;
}

static BOOL ensure_loaded(void) {
    InitOnceExecuteOnce(&mf.once, load_mf, NULL, NULL);
    return mf.loaded;
}

struct cmf_aac_writer {
    IMFSinkWriter *sink;
    DWORD stream;
    uint32_t sample_rate;
    uint32_t channels;
    LONGLONG frames_written;
    BOOL com_initialized;
    BOOL mf_started;
};

int32_t cmf_aac_encoder_available(void) {
    if (!ensure_loaded()) return 0;
    BOOL com = SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED));
    int32_t found = 0;
    if (SUCCEEDED(mf.startup(MF_VERSION, MFSTARTUP_LITE))) {
        MFT_REGISTER_TYPE_INFO output = {MFMediaType_Audio, MFAudioFormat_AAC};
        IMFActivate **activates = NULL;
        UINT32 count = 0;
        UINT32 flags = MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER;
        if (SUCCEEDED(mf.tenum_ex(MFT_CATEGORY_AUDIO_ENCODER, flags, NULL, &output, &activates, &count))) {
            found = count > 0;
            for (UINT32 i = 0; i < count; i++) IMFActivate_Release(activates[i]);
            CoTaskMemFree(activates);
        }
        mf.shutdown();
    }
    if (com) CoUninitialize();
    return found;
}

/// An audio media type: AAC for the stream, PCM for what is handed to it. Both say 16 bits per sample, which is what
/// the AAC encoder takes in.
static HRESULT audio_type(IMFMediaType **type, const GUID *subtype, uint32_t rate, uint32_t channels,
                          uint32_t bytes_per_second) {
    HRESULT hr = mf.create_media_type(type);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(*type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(*type, &MF_MT_SUBTYPE, subtype);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(*type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(*type, &MF_MT_AUDIO_NUM_CHANNELS, channels);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(*type, &MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(*type, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, bytes_per_second);
    if (SUCCEEDED(hr) && IsEqualGUID(subtype, &MFAudioFormat_PCM)) {
        hr = IMFMediaType_SetUINT32(*type, &MF_MT_AUDIO_BLOCK_ALIGNMENT, channels * 2);
    }
    return hr;
}

int32_t cmf_aac_open(const uint16_t *path, uint32_t sample_rate, uint32_t channels, uint32_t bit_rate,
                     cmf_aac_writer **out) {
    *out = NULL;
    if (!ensure_loaded()) return (int32_t)E_NOTIMPL;
    cmf_aac_writer *writer = (cmf_aac_writer *)calloc(1, sizeof(cmf_aac_writer));
    if (writer == NULL) return (int32_t)E_OUTOFMEMORY;
    writer->sample_rate = sample_rate;
    writer->channels = channels;
    writer->com_initialized = SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED));
    HRESULT hr = mf.startup(MF_VERSION, MFSTARTUP_LITE);
    writer->mf_started = SUCCEEDED(hr);
    IMFAttributes *attributes = NULL;
    IMFMediaType *aac = NULL;
    IMFMediaType *pcm = NULL;
    if (SUCCEEDED(hr)) hr = mf.create_attributes(&attributes, 1);
    if (SUCCEEDED(hr)) {
        hr = IMFAttributes_SetGUID(attributes, &MF_TRANSCODE_CONTAINERTYPE, &MFTranscodeContainerType_MPEG4);
    }
    if (SUCCEEDED(hr)) hr = mf.create_sink_writer((LPCWSTR)path, NULL, attributes, &writer->sink);
    if (SUCCEEDED(hr)) hr = audio_type(&aac, &MFAudioFormat_AAC, sample_rate, channels, bit_rate / 8);
    if (SUCCEEDED(hr)) hr = IMFSinkWriter_AddStream(writer->sink, aac, &writer->stream);
    if (SUCCEEDED(hr)) hr = audio_type(&pcm, &MFAudioFormat_PCM, sample_rate, channels, sample_rate * channels * 2);
    if (SUCCEEDED(hr)) hr = IMFSinkWriter_SetInputMediaType(writer->sink, writer->stream, pcm, NULL);
    if (SUCCEEDED(hr)) hr = IMFSinkWriter_BeginWriting(writer->sink);
    if (attributes) IMFAttributes_Release(attributes);
    if (aac) IMFMediaType_Release(aac);
    if (pcm) IMFMediaType_Release(pcm);
    if (FAILED(hr)) {
        cmf_aac_close(writer);
        return (int32_t)hr;
    }
    *out = writer;
    return 0;
}

int32_t cmf_aac_write(cmf_aac_writer *writer, const int16_t *samples, uint32_t frames) {
    DWORD bytes = frames * writer->channels * 2;
    IMFMediaBuffer *buffer = NULL;
    IMFSample *sample = NULL;
    BYTE *data = NULL;
    HRESULT hr = mf.create_memory_buffer(bytes, &buffer);
    if (SUCCEEDED(hr)) hr = IMFMediaBuffer_Lock(buffer, &data, NULL, NULL);
    if (SUCCEEDED(hr)) {
        memcpy(data, samples, bytes);
        IMFMediaBuffer_Unlock(buffer);
        hr = IMFMediaBuffer_SetCurrentLength(buffer, bytes);
    }
    if (SUCCEEDED(hr)) hr = mf.create_sample(&sample);
    if (SUCCEEDED(hr)) hr = IMFSample_AddBuffer(sample, buffer);
    // In 100 ns units, from the frame count, so no rounding builds up over a long file.
    LONGLONG start = writer->frames_written * 10000000LL / writer->sample_rate;
    LONGLONG end = (writer->frames_written + frames) * 10000000LL / writer->sample_rate;
    if (SUCCEEDED(hr)) hr = IMFSample_SetSampleTime(sample, start);
    if (SUCCEEDED(hr)) hr = IMFSample_SetSampleDuration(sample, end - start);
    if (SUCCEEDED(hr)) hr = IMFSinkWriter_WriteSample(writer->sink, writer->stream, sample);
    if (SUCCEEDED(hr)) writer->frames_written += frames;
    if (sample) IMFSample_Release(sample);
    if (buffer) IMFMediaBuffer_Release(buffer);
    return (int32_t)hr;
}

int32_t cmf_aac_finish(cmf_aac_writer *writer) {
    return (int32_t)IMFSinkWriter_Finalize(writer->sink);
}

void cmf_aac_close(cmf_aac_writer *writer) {
    if (writer == NULL) return;
    if (writer->sink) IMFSinkWriter_Release(writer->sink);
    if (writer->mf_started) mf.shutdown();
    if (writer->com_initialized) CoUninitialize();
    free(writer);
}

// MARK: - MP4 (H.264 + AAC)

struct cmf_mp4_writer {
    IMFSinkWriter *sink;
    DWORD video_stream;
    DWORD audio_stream;
    BOOL has_audio;
    uint32_t width;
    uint32_t height;
    uint32_t fps;
    uint32_t sample_rate;
    uint32_t channels;
    LONGLONG frames_written;
    LONGLONG audio_frames_written;
    /// The frame being handed over, as NV12: `width * height` luma bytes, then interleaved Cb Cr at half size.
    uint8_t *nv12;
    BOOL com_initialized;
    BOOL mf_started;
};

/// BGRA (premultiplied, opaque in a score video) to NV12 in BT.709 studio range — 8-bit integer coefficients, luma per
/// pixel, chroma from each 2x2 block's average. Rows top-down in both.
static void bgra_to_nv12(const uint8_t *bgra, uint8_t *nv12, uint32_t width, uint32_t height) {
    uint8_t *luma = nv12;
    uint8_t *chroma = nv12 + (size_t)width * height;
    for (uint32_t y = 0; y < height; y++) {
        const uint8_t *row = bgra + (size_t)y * width * 4;
        uint8_t *out = luma + (size_t)y * width;
        for (uint32_t x = 0; x < width; x++) {
            int b = row[x * 4], g = row[x * 4 + 1], r = row[x * 4 + 2];
            out[x] = (uint8_t)(((47 * r + 157 * g + 16 * b + 128) >> 8) + 16);
        }
    }
    for (uint32_t y = 0; y < height; y += 2) {
        const uint8_t *top = bgra + (size_t)y * width * 4;
        const uint8_t *bottom = top + (size_t)width * 4;
        uint8_t *out = chroma + (size_t)(y / 2) * width;
        for (uint32_t x = 0; x < width; x += 2) {
            const uint8_t *p = top + x * 4;
            const uint8_t *q = bottom + x * 4;
            int b = (p[0] + p[4] + q[0] + q[4] + 2) >> 2;
            int g = (p[1] + p[5] + q[1] + q[5] + 2) >> 2;
            int r = (p[2] + p[6] + q[2] + q[6] + 2) >> 2;
            out[x] = (uint8_t)(((-26 * r - 87 * g + 112 * b + 128) >> 8) + 128);
            out[x + 1] = (uint8_t)(((112 * r - 102 * g - 10 * b + 128) >> 8) + 128);
        }
    }
}

/// Whether an encoder that outputs `subtype` in `category` is registered — software or hardware.
static int32_t encoder_listed(const GUID *category, const GUID *major, const GUID *subtype) {
    MFT_REGISTER_TYPE_INFO output = {*major, *subtype};
    IMFActivate **activates = NULL;
    UINT32 count = 0;
    UINT32 flags = MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_LOCALMFT |
                   MFT_ENUM_FLAG_SORTANDFILTER;
    int32_t found = 0;
    if (SUCCEEDED(mf.tenum_ex(*category, flags, NULL, &output, &activates, &count))) {
        found = count > 0;
        for (UINT32 i = 0; i < count; i++) IMFActivate_Release(activates[i]);
        CoTaskMemFree(activates);
    }
    return found;
}

int32_t cmf_mp4_encoder_available(void) {
    if (!ensure_loaded()) return 0;
    BOOL com = SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED));
    int32_t found = 0;
    if (SUCCEEDED(mf.startup(MF_VERSION, MFSTARTUP_LITE))) {
        found = encoder_listed(&MFT_CATEGORY_VIDEO_ENCODER, &MFMediaType_Video, &MFVideoFormat_H264) &&
                encoder_listed(&MFT_CATEGORY_AUDIO_ENCODER, &MFMediaType_Audio, &MFAudioFormat_AAC);
        mf.shutdown();
    }
    if (com) CoUninitialize();
    return found;
}

/// Two 32-bit values packed as Media Foundation's size and ratio attributes take them (MFSetAttributeSize is C++).
static UINT64 pack2(uint32_t high, uint32_t low) {
    return ((UINT64)high << 32) | (UINT64)low;
}

/// A video media type: progressive, square pixels, `width` x `height` at `fps`.
static HRESULT video_type(IMFMediaType **type, const GUID *subtype, uint32_t width, uint32_t height, uint32_t fps) {
    HRESULT hr = mf.create_media_type(type);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(*type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(*type, &MF_MT_SUBTYPE, subtype);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(*type, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT64(*type, &MF_MT_FRAME_SIZE, pack2(width, height));
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT64(*type, &MF_MT_FRAME_RATE, pack2(fps, 1));
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT64(*type, &MF_MT_PIXEL_ASPECT_RATIO, pack2(1, 1));
    return hr;
}

/// The stream's colour, as Apple's writer tags it: BT.709 primaries, matrix and transfer, studio range (16–235).
/// Without these a decoder guesses, and an untagged stream's colours came back lifted (40,120,200 read 57,131,205).
static HRESULT tag_bt709(IMFMediaType *type) {
    HRESULT hr = IMFMediaType_SetUINT32(type, &MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(type, &MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(type, &MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(type, &MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
    return hr;
}

int32_t cmf_mp4_open(const uint16_t *path, uint32_t width, uint32_t height, uint32_t fps, uint32_t video_bit_rate,
                     uint32_t sample_rate, uint32_t channels, uint32_t audio_bit_rate, cmf_mp4_writer **out) {
    *out = NULL;
    if (!ensure_loaded()) return (int32_t)E_NOTIMPL;
    if (width == 0 || height == 0 || fps == 0 || (width % 2) != 0 || (height % 2) != 0) return (int32_t)E_INVALIDARG;
    cmf_mp4_writer *writer = (cmf_mp4_writer *)calloc(1, sizeof(cmf_mp4_writer));
    if (writer == NULL) return (int32_t)E_OUTOFMEMORY;
    writer->width = width;
    writer->height = height;
    writer->fps = fps;
    writer->sample_rate = sample_rate;
    writer->channels = channels;
    writer->has_audio = sample_rate > 0 && channels > 0;
    writer->com_initialized = SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED));
    HRESULT hr = mf.startup(MF_VERSION, MFSTARTUP_LITE);
    writer->mf_started = SUCCEEDED(hr);
    IMFAttributes *attributes = NULL;
    IMFMediaType *h264 = NULL;
    IMFMediaType *bgra = NULL;
    IMFMediaType *aac = NULL;
    IMFMediaType *pcm = NULL;
    if (SUCCEEDED(hr)) hr = mf.create_attributes(&attributes, 2);
    if (SUCCEEDED(hr)) {
        hr = IMFAttributes_SetGUID(attributes, &MF_TRANSCODE_CONTAINERTYPE, &MFTranscodeContainerType_MPEG4);
    }
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUINT32(attributes, &MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    if (SUCCEEDED(hr)) hr = mf.create_sink_writer((LPCWSTR)path, NULL, attributes, &writer->sink);
    // Video: H.264 out; BGRA in (the frame canvas's pixels), the Sink Writer converting to the encoder's NV12.
    if (SUCCEEDED(hr)) hr = video_type(&h264, &MFVideoFormat_H264, width, height, fps);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(h264, &MF_MT_AVG_BITRATE, video_bit_rate);
    if (SUCCEEDED(hr)) hr = tag_bt709(h264);
    if (SUCCEEDED(hr)) hr = IMFSinkWriter_AddStream(writer->sink, h264, &writer->video_stream);
    // NV12 in, converted here from the caller's BGRA (`bgra_to_nv12`) rather than by the converter the Sink Writer
    // would insert for RGB32: that converter ignored the BT.709 tags and the colours came back shifted by up to 13
    // levels. Converting here, the data is the tags' by construction. Rows top-down (a positive stride).
    if (SUCCEEDED(hr)) hr = video_type(&bgra, &MFVideoFormat_NV12, width, height, fps);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(bgra, &MF_MT_DEFAULT_STRIDE, width);
    if (SUCCEEDED(hr)) hr = tag_bt709(bgra);
    if (SUCCEEDED(hr)) hr = IMFSinkWriter_SetInputMediaType(writer->sink, writer->video_stream, bgra, NULL);
    if (SUCCEEDED(hr)) {
        writer->nv12 = (uint8_t *)malloc((size_t)width * height * 3 / 2);
        if (writer->nv12 == NULL) hr = E_OUTOFMEMORY;
    }
    // Audio: AAC out, 16-bit PCM in — the AAC writer's types.
    if (SUCCEEDED(hr) && writer->has_audio) {
        hr = audio_type(&aac, &MFAudioFormat_AAC, sample_rate, channels, audio_bit_rate / 8);
        if (SUCCEEDED(hr)) hr = IMFSinkWriter_AddStream(writer->sink, aac, &writer->audio_stream);
        if (SUCCEEDED(hr)) hr = audio_type(&pcm, &MFAudioFormat_PCM, sample_rate, channels, sample_rate * channels * 2);
        if (SUCCEEDED(hr)) hr = IMFSinkWriter_SetInputMediaType(writer->sink, writer->audio_stream, pcm, NULL);
    }
    if (SUCCEEDED(hr)) hr = IMFSinkWriter_BeginWriting(writer->sink);
    if (attributes) IMFAttributes_Release(attributes);
    if (h264) IMFMediaType_Release(h264);
    if (bgra) IMFMediaType_Release(bgra);
    if (aac) IMFMediaType_Release(aac);
    if (pcm) IMFMediaType_Release(pcm);
    if (FAILED(hr)) {
        cmf_mp4_close(writer);
        return (int32_t)hr;
    }
    *out = writer;
    return 0;
}

/// One sample of `bytes` bytes copied from `data`, at [start, end) in 100 ns units, written to `stream`.
static HRESULT write_sample(IMFSinkWriter *sink, DWORD stream, const void *data, DWORD bytes, LONGLONG start,
                            LONGLONG end) {
    IMFMediaBuffer *buffer = NULL;
    IMFSample *sample = NULL;
    BYTE *target = NULL;
    HRESULT hr = mf.create_memory_buffer(bytes, &buffer);
    if (SUCCEEDED(hr)) hr = IMFMediaBuffer_Lock(buffer, &target, NULL, NULL);
    if (SUCCEEDED(hr)) {
        memcpy(target, data, bytes);
        IMFMediaBuffer_Unlock(buffer);
        hr = IMFMediaBuffer_SetCurrentLength(buffer, bytes);
    }
    if (SUCCEEDED(hr)) hr = mf.create_sample(&sample);
    if (SUCCEEDED(hr)) hr = IMFSample_AddBuffer(sample, buffer);
    if (SUCCEEDED(hr)) hr = IMFSample_SetSampleTime(sample, start);
    if (SUCCEEDED(hr)) hr = IMFSample_SetSampleDuration(sample, end - start);
    if (SUCCEEDED(hr)) hr = IMFSinkWriter_WriteSample(sink, stream, sample);
    if (sample) IMFSample_Release(sample);
    if (buffer) IMFMediaBuffer_Release(buffer);
    return hr;
}

int32_t cmf_mp4_write_frame(cmf_mp4_writer *writer, const uint8_t *bgra) {
    // Times from the frame count, so no rounding builds up over a long video.
    LONGLONG start = writer->frames_written * 10000000LL / writer->fps;
    LONGLONG end = (writer->frames_written + 1) * 10000000LL / writer->fps;
    bgra_to_nv12(bgra, writer->nv12, writer->width, writer->height);
    HRESULT hr = write_sample(writer->sink, writer->video_stream, writer->nv12, writer->width * writer->height * 3 / 2,
                              start, end);
    if (SUCCEEDED(hr)) writer->frames_written += 1;
    return (int32_t)hr;
}

int32_t cmf_mp4_write_audio(cmf_mp4_writer *writer, const int16_t *samples, uint32_t frames) {
    if (!writer->has_audio) return (int32_t)E_UNEXPECTED;
    LONGLONG start = writer->audio_frames_written * 10000000LL / writer->sample_rate;
    LONGLONG end = (writer->audio_frames_written + frames) * 10000000LL / writer->sample_rate;
    HRESULT hr = write_sample(writer->sink, writer->audio_stream, samples, frames * writer->channels * 2, start, end);
    if (SUCCEEDED(hr)) writer->audio_frames_written += frames;
    return (int32_t)hr;
}

int32_t cmf_mp4_finish(cmf_mp4_writer *writer) {
    return (int32_t)IMFSinkWriter_Finalize(writer->sink);
}

void cmf_mp4_close(cmf_mp4_writer *writer) {
    if (writer == NULL) return;
    if (writer->sink) IMFSinkWriter_Release(writer->sink);
    free(writer->nv12);
    if (writer->mf_started) mf.shutdown();
    if (writer->com_initialized) CoUninitialize();
    free(writer);
}

int32_t cmf_mp4_first_frame_pixel(const uint16_t *path, uint32_t x, uint32_t y, uint8_t *bgra) {
    memset(bgra, 0, 4);
    if (!ensure_loaded() || mf.create_source_reader == NULL) return (int32_t)E_NOTIMPL;
    BOOL com = SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED));
    HRESULT hr = mf.startup(MF_VERSION, MFSTARTUP_LITE);
    BOOL started = SUCCEEDED(hr);
    IMFAttributes *attributes = NULL;
    IMFSourceReader *reader = NULL;
    IMFMediaType *rgb = NULL;
    IMFSample *sample = NULL;
    IMFMediaBuffer *buffer = NULL;
    IMF2DBuffer *buffer2d = NULL;
    if (SUCCEEDED(hr)) hr = mf.create_attributes(&attributes, 1);
    // The reader's own colour conversion, so the decoded frame comes back as RGB32.
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUINT32(attributes, &MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    if (SUCCEEDED(hr)) hr = mf.create_source_reader((LPCWSTR)path, attributes, &reader);
    if (SUCCEEDED(hr)) hr = mf.create_media_type(&rgb);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(rgb, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(rgb, &MF_MT_SUBTYPE, &MFVideoFormat_RGB32);
    if (SUCCEEDED(hr)) {
        hr = IMFSourceReader_SetCurrentMediaType(reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, rgb);
    }
    // The frame's size and stride as the reader delivers it: a negative stride is rows stored bottom-up.
    UINT32 frame_width = 0;
    UINT32 frame_height = 0;
    LONG stride = 0;
    if (SUCCEEDED(hr)) {
        IMFMediaType *current = NULL;
        hr = IMFSourceReader_GetCurrentMediaType(reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &current);
        if (SUCCEEDED(hr)) {
            UINT64 size = 0;
            UINT32 declared = 0;
            IMFMediaType_GetUINT64(current, &MF_MT_FRAME_SIZE, &size);
            frame_width = (UINT32)(size >> 32);
            frame_height = (UINT32)(size & 0xFFFFFFFF);
            // RGB32 with no stride declared is bottom-up, Media Foundation's default for RGB.
            stride = SUCCEEDED(IMFMediaType_GetUINT32(current, &MF_MT_DEFAULT_STRIDE, &declared))
                         ? (LONG)declared
                         : -(LONG)(frame_width * 4);
            IMFMediaType_Release(current);
        }
    }
    if (SUCCEEDED(hr) && (x >= frame_width || y >= frame_height)) hr = E_INVALIDARG;
    // The first reads may bring a stream tick or a format change and no sample: read on until a frame comes.
    for (int attempt = 0; SUCCEEDED(hr) && sample == NULL && attempt < 16; attempt++) {
        DWORD stream = 0;
        DWORD flags = 0;
        LONGLONG time = 0;
        hr = IMFSourceReader_ReadSample(reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &stream, &flags, &time,
                                        &sample);
        if (SUCCEEDED(hr) && sample == NULL && (flags & MF_SOURCE_READERF_ENDOFSTREAM)) hr = MF_E_END_OF_STREAM;
    }
    if (SUCCEEDED(hr) && sample == NULL) hr = E_FAIL;
    if (SUCCEEDED(hr)) hr = IMFSample_GetBufferByIndex(sample, 0, &buffer);
    // The 2-D view gives the top row and the real pitch whichever way the rows are stored; a plain buffer is read
    // with the type's stride instead.
    if (SUCCEEDED(hr) && SUCCEEDED(IMFMediaBuffer_QueryInterface(buffer, &IID_IMF2DBuffer, (void **)&buffer2d))) {
        BYTE *top = NULL;
        LONG pitch = 0;
        hr = IMF2DBuffer_Lock2D(buffer2d, &top, &pitch);
        if (SUCCEEDED(hr)) {
            memcpy(bgra, top + (LONG)y * pitch + (LONG)x * 4, 4);
            IMF2DBuffer_Unlock2D(buffer2d);
        }
    } else if (SUCCEEDED(hr)) {
        BYTE *data = NULL;
        hr = IMFMediaBuffer_Lock(buffer, &data, NULL, NULL);
        if (SUCCEEDED(hr)) {
            LONG row = stride >= 0 ? (LONG)y : (LONG)(frame_height - 1 - y);
            LONG pitch = stride >= 0 ? stride : -stride;
            memcpy(bgra, data + row * pitch + (LONG)x * 4, 4);
            IMFMediaBuffer_Unlock(buffer);
        }
    }
    if (buffer2d) IMF2DBuffer_Release(buffer2d);
    if (buffer) IMFMediaBuffer_Release(buffer);
    if (sample) IMFSample_Release(sample);
    if (rgb) IMFMediaType_Release(rgb);
    if (reader) IMFSourceReader_Release(reader);
    if (attributes) IMFAttributes_Release(attributes);
    if (started) mf.shutdown();
    if (com) CoUninitialize();
    return (int32_t)hr;
}

int32_t cmf_mp4_probe(const uint16_t *path, int64_t *duration_100ns, uint32_t *width, uint32_t *height,
                      int32_t *video_is_h264, int32_t *audio_is_aac) {
    *duration_100ns = 0;
    *width = 0;
    *height = 0;
    *video_is_h264 = 0;
    *audio_is_aac = 0;
    if (!ensure_loaded() || mf.create_source_reader == NULL) return (int32_t)E_NOTIMPL;
    BOOL com = SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED));
    HRESULT hr = mf.startup(MF_VERSION, MFSTARTUP_LITE);
    BOOL started = SUCCEEDED(hr);
    IMFSourceReader *reader = NULL;
    if (SUCCEEDED(hr)) hr = mf.create_source_reader((LPCWSTR)path, NULL, &reader);
    if (SUCCEEDED(hr)) {
        PROPVARIANT value;
        PropVariantInit(&value);
        if (SUCCEEDED(IMFSourceReader_GetPresentationAttribute(reader, (DWORD)MF_SOURCE_READER_MEDIASOURCE,
                                                               &MF_PD_DURATION, &value))) {
            *duration_100ns = (int64_t)value.uhVal.QuadPart;
        }
        PropVariantClear(&value);
        IMFMediaType *type = NULL;
        if (SUCCEEDED(IMFSourceReader_GetNativeMediaType(reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0,
                                                         &type))) {
            GUID subtype = GUID_NULL;
            UINT64 size = 0;
            IMFMediaType_GetGUID(type, &MF_MT_SUBTYPE, &subtype);
            IMFMediaType_GetUINT64(type, &MF_MT_FRAME_SIZE, &size);
            *video_is_h264 = IsEqualGUID(&subtype, &MFVideoFormat_H264) ? 1 : 0;
            *width = (uint32_t)(size >> 32);
            *height = (uint32_t)(size & 0xFFFFFFFF);
            IMFMediaType_Release(type);
        }
        if (SUCCEEDED(IMFSourceReader_GetNativeMediaType(reader, (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0,
                                                         &type))) {
            GUID subtype = GUID_NULL;
            IMFMediaType_GetGUID(type, &MF_MT_SUBTYPE, &subtype);
            *audio_is_aac = IsEqualGUID(&subtype, &MFAudioFormat_AAC) ? 1 : 0;
            IMFMediaType_Release(type);
        }
        IMFSourceReader_Release(reader);
    }
    if (started) mf.shutdown();
    if (com) CoUninitialize();
    return (int32_t)hr;
}
