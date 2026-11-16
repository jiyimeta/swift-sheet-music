#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <strmif.h>
// CODECAPI_* defined here (codecapi.h declares them with DEFINE_GUID); IID_ICodecAPI comes from strmiids.lib.
#include <initguid.h>
#include <codecapi.h>
#include <stdint.h>
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
    /// The decoder, the probes and the tests' read-backs need it; its absence does not unload the encoders.
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

/// A YUV matrix's studio-range coefficients in 1/256ths: luma from R, G, B, then Cb's and Cr's.
typedef struct {
    int yr, yg, yb, ur, ug, ub, vr, vg, vb;
    /// What the matrix is called in an MP4 `colr` box (ISO/IEC 23091-2 MatrixCoefficients): 1 BT.709, 6 BT.601.
    uint16_t colr_matrix;
    /// What it is called in a Media Foundation type (`MFVideoTransferMatrix`).
    UINT32 mf_matrix;
} nv12_matrix;

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
    /// The matrix the frames are converted in (`matrix_for_height`), which the `colr` box then names.
    const nv12_matrix *matrix;
    /// The file, for the `colr` box written once the Sink Writer has let go of it.
    WCHAR *path;
    BOOL com_initialized;
    BOOL mf_started;
    /// The rate control the H.264 encoder took (`cmf_mp4_rate_control`): an `eAVEncCommonRateControlMode`, or -1 when
    /// the encoder could not be asked; and its quality (0–100) in Quality mode, else -1.
    int32_t rate_mode;
    int32_t rate_quality;
};

/// The two matrices' 8-bit studio-range coefficients (ITU-R BT.709 and BT.601), each row rounded so luma's sums to 220
/// and each chroma's to 0, which keeps a grey's chroma at exactly 128 (BT.709's Cb, -25.8 -86.7 +112.4, gives its
/// rounding to green).
static const nv12_matrix matrix_bt709 = {47, 157, 16, -26, -86, 112, 112, -102, -10, 1, MFVideoTransferMatrix_BT709};
static const nv12_matrix matrix_bt601 = {66, 129, 25, -38, -74, 112, 112, -94, -18, 6, MFVideoTransferMatrix_BT601};

/// The matrix a frame `height` rows tall is written in: the one a player assumes for an untagged stream of that
/// height — BT.601 below 720 rows (SD), BT.709 from 720 (HD) — so the colours are right whether or not the player
/// reads the `colr` box that names it. Media Foundation's H.264 encoder writes no colour description into the stream
/// (measured on folino-win, 2026-11-15: its output type held BT.709, the stream's VUI had none), so the container's
/// box is the only tag, and many players read none.
static const nv12_matrix *matrix_for_height(uint32_t height) {
    return height < 720 ? &matrix_bt601 : &matrix_bt709;
}

/// BGRA (premultiplied, opaque in a score video) to NV12 in `m`, studio range — luma per pixel, chroma from each 2x2
/// block's average. Rows top-down in both.
static void bgra_to_nv12(const uint8_t *bgra, uint8_t *nv12, uint32_t width, uint32_t height, const nv12_matrix *m) {
    uint8_t *luma = nv12;
    uint8_t *chroma = nv12 + (size_t)width * height;
    for (uint32_t y = 0; y < height; y++) {
        const uint8_t *row = bgra + (size_t)y * width * 4;
        uint8_t *out = luma + (size_t)y * width;
        for (uint32_t x = 0; x < width; x++) {
            int b = row[x * 4], g = row[x * 4 + 1], r = row[x * 4 + 2];
            out[x] = (uint8_t)(((m->yr * r + m->yg * g + m->yb * b + 128) >> 8) + 16);
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
            out[x] = (uint8_t)(((m->ur * r + m->ug * g + m->ub * b + 128) >> 8) + 128);
            out[x + 1] = (uint8_t)(((m->vr * r + m->vg * g + m->vb * b + 128) >> 8) + 128);
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

/// The frames' colour on the types the Sink Writer is handed: BT.709 primaries and transfer (what the canvas draws in),
/// `matrix`, studio range (16–235). The encoder keeps them on its output type but writes none into the stream, so the
/// file's own tag is the `colr` box `add_colr` writes.
static HRESULT tag_colour(IMFMediaType *type, const nv12_matrix *matrix) {
    HRESULT hr = IMFMediaType_SetUINT32(type, &MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(type, &MF_MT_YUV_MATRIX, matrix->mf_matrix);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(type, &MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(type, &MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
    return hr;
}

// MARK: - The `colr` box
//
// An MP4 says its video's colour in a `colr` box of type `nclx` inside the video sample entry (`avc1`), ISO/IEC
// 14496-12 §12.1.5: primaries, transfer, matrix (ISO/IEC 23091-2 codes) and a full-range flag. Media Foundation's sink
// writes none, and its encoder writes no colour description into the stream either, so the box is added once the file
// is complete. The sink puts the `moov` box after the media data, so the box grows only `moov` and the boxes above the
// sample entry inside it — no chunk offset (`stco`) moves. A file laid out otherwise is left as it is.

/// The size of `moov` a file may have for the box to be added in memory; a score video's is a few hundred KB.
static const uint64_t colr_moov_limit = 64u * 1024 * 1024;
enum { colr_box_size = 19 };

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void write_be32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)(value >> 24);
    p[1] = (uint8_t)(value >> 16);
    p[2] = (uint8_t)(value >> 8);
    p[3] = (uint8_t)value;
}

/// The first box of `type` among the boxes in [start, end) of `box`: its offset, or -1. Boxes with a 64-bit size or
/// running past `end` stop the search (none is expected inside `moov`).
static long find_child(const uint8_t *box, size_t start, size_t end, const char *type) {
    size_t offset = start;
    while (offset + 8 <= end) {
        uint32_t size = read_be32(box + offset);
        if (size < 8 || offset + size > end) return -1;
        if (memcmp(box + offset + 4, type, 4) == 0) return (long)offset;
        offset += size;
    }
    return -1;
}

/// The video track's `avc1` sample entry in `moov` (read into memory): the offsets of the boxes that hold it, outermost
/// first — moov, trak, mdia, minf, stbl, stsd, avc1 — into `chain`. FALSE when there is none.
static BOOL find_avc1(const uint8_t *moov, size_t size, size_t chain[7]) {
    chain[0] = 0;
    size_t start = 8;
    while (start + 8 <= size) {
        long trak = find_child(moov, start, size, "trak");
        if (trak < 0) return FALSE;
        size_t trak_end = (size_t)trak + read_be32(moov + trak);
        start = trak_end;
        long mdia = find_child(moov, (size_t)trak + 8, trak_end, "mdia");
        if (mdia < 0) continue;
        size_t mdia_end = (size_t)mdia + read_be32(moov + mdia);
        long hdlr = find_child(moov, (size_t)mdia + 8, mdia_end, "hdlr");
        // hdlr: header (8), version and flags (4), pre_defined (4), then the handler type.
        if (hdlr < 0 || (size_t)hdlr + 20 > mdia_end || memcmp(moov + hdlr + 16, "vide", 4) != 0) continue;
        long minf = find_child(moov, (size_t)mdia + 8, mdia_end, "minf");
        if (minf < 0) return FALSE;
        size_t minf_end = (size_t)minf + read_be32(moov + minf);
        long stbl = find_child(moov, (size_t)minf + 8, minf_end, "stbl");
        if (stbl < 0) return FALSE;
        size_t stbl_end = (size_t)stbl + read_be32(moov + stbl);
        long stsd = find_child(moov, (size_t)stbl + 8, stbl_end, "stsd");
        if (stsd < 0) return FALSE;
        size_t stsd_end = (size_t)stsd + read_be32(moov + stsd);
        // stsd: header (8), version and flags (4), entry count (4), then the sample entries.
        long avc1 = find_child(moov, (size_t)stsd + 16, stsd_end, "avc1");
        if (avc1 < 0) return FALSE;
        size_t found[7] = {0, (size_t)trak, (size_t)mdia, (size_t)minf, (size_t)stbl, (size_t)stsd, (size_t)avc1};
        memcpy(chain, found, sizeof(found));
        return TRUE;
    }
    return FALSE;
}

/// The offset and size of the file's `moov` box when it is the last box (Media Foundation's layout) and small enough
/// to edit in memory; FALSE otherwise.
static BOOL find_last_moov(HANDLE file, uint64_t *offset, uint64_t *size) {
    LARGE_INTEGER length;
    if (!GetFileSizeEx(file, &length)) return FALSE;
    uint64_t at = 0;
    BOOL found = FALSE;
    while (at + 8 <= (uint64_t)length.QuadPart) {
        uint8_t header[16];
        DWORD read = 0;
        LARGE_INTEGER position;
        position.QuadPart = (LONGLONG)at;
        if (!SetFilePointerEx(file, position, NULL, FILE_BEGIN) || !ReadFile(file, header, 16, &read, NULL) || read < 8) {
            return FALSE;
        }
        uint64_t box = read_be32(header);
        if (box == 1) {
            if (read < 16) return FALSE;
            box = ((uint64_t)read_be32(header + 8) << 32) | read_be32(header + 12);
        } else if (box == 0) {
            box = (uint64_t)length.QuadPart - at;
        }
        if (box < 8) return FALSE;
        found = memcmp(header + 4, "moov", 4) == 0 && read_be32(header) != 1;
        if (found) {
            *offset = at;
            *size = box;
        }
        at += box;
    }
    return found && *offset + *size == (uint64_t)length.QuadPart && *size <= colr_moov_limit;
}

/// Reads the file's `moov` box, if it is the last one, into a new buffer with room for one `colr` box after it.
static uint8_t *read_moov(HANDLE file, uint64_t *offset, uint64_t *size) {
    if (!find_last_moov(file, offset, size)) return NULL;
    uint8_t *moov = (uint8_t *)malloc((size_t)*size + colr_box_size);
    if (moov == NULL) return NULL;
    LARGE_INTEGER position;
    position.QuadPart = (LONGLONG)*offset;
    DWORD read = 0;
    if (!SetFilePointerEx(file, position, NULL, FILE_BEGIN) || !ReadFile(file, moov, (DWORD)*size, &read, NULL) ||
        read != (DWORD)*size) {
        free(moov);
        return NULL;
    }
    return moov;
}

/// Adds a `colr` box naming BT.709 primaries and transfer, `matrix` and studio range to the file's video sample entry.
/// S_FALSE, the file untouched, when it is laid out otherwise or already has one.
static HRESULT add_colr(const WCHAR *path, uint16_t matrix) {
    HANDLE file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
    HRESULT hr = S_FALSE;
    uint64_t offset = 0, size = 0;
    uint8_t *moov = read_moov(file, &offset, &size);
    size_t chain[7];
    if (moov != NULL && find_avc1(moov, (size_t)size, chain)) {
        size_t avc1 = chain[6];
        size_t avc1_end = avc1 + read_be32(moov + avc1);
        // The visual sample entry's fixed fields take 78 bytes after its header; its child boxes follow.
        if (find_child(moov, avc1 + 8 + 78, avc1_end, "colr") < 0) {
            memmove(moov + avc1_end + colr_box_size, moov + avc1_end, (size_t)size - avc1_end);
            uint8_t *box = moov + avc1_end;
            const uint8_t fields[colr_box_size] = {
                0, 0, 0, colr_box_size, 'c', 'o', 'l', 'r', 'n', 'c', 'l', 'x',
                0, 1, // colour_primaries: BT.709
                0, 1, // transfer_characteristics: BT.709
                (uint8_t)(matrix >> 8), (uint8_t)matrix,
                0, // full_range_flag 0: studio range
            };
            memcpy(box, fields, colr_box_size);
            for (int i = 0; i < 7; i++) write_be32(moov + chain[i], read_be32(moov + chain[i]) + colr_box_size);
            LARGE_INTEGER position;
            position.QuadPart = (LONGLONG)offset;
            DWORD written = 0;
            DWORD total = (DWORD)size + colr_box_size;
            hr = SetFilePointerEx(file, position, NULL, FILE_BEGIN) && WriteFile(file, moov, total, &written, NULL) &&
                         written == total
                     ? S_OK
                     : HRESULT_FROM_WIN32(GetLastError());
        }
    }
    free(moov);
    CloseHandle(file);
    return hr;
}

int32_t cmf_mp4_colour(const uint16_t *path, uint16_t *primaries, uint16_t *transfer, uint16_t *matrix,
                       uint8_t *full_range) {
    *primaries = *transfer = *matrix = 0;
    *full_range = 0;
    HANDLE file = CreateFileW((LPCWSTR)path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              NULL);
    if (file == INVALID_HANDLE_VALUE) return (int32_t)HRESULT_FROM_WIN32(GetLastError());
    HRESULT hr = S_FALSE;
    uint64_t offset = 0, size = 0;
    uint8_t *moov = read_moov(file, &offset, &size);
    size_t chain[7];
    if (moov != NULL && find_avc1(moov, (size_t)size, chain)) {
        size_t avc1 = chain[6];
        long colr = find_child(moov, avc1 + 8 + 78, avc1 + read_be32(moov + avc1), "colr");
        if (colr >= 0 && read_be32(moov + colr) >= colr_box_size && memcmp(moov + colr + 8, "nclx", 4) == 0) {
            const uint8_t *fields = moov + colr + 12;
            *primaries = (uint16_t)((fields[0] << 8) | fields[1]);
            *transfer = (uint16_t)((fields[2] << 8) | fields[3]);
            *matrix = (uint16_t)((fields[4] << 8) | fields[5]);
            *full_range = (uint8_t)(fields[6] >> 7);
            hr = S_OK;
        }
    }
    free(moov);
    CloseHandle(file);
    return (int32_t)hr;
}

// MARK: - H.264 rate control

/// `key` read back from the encoder as an integer, or -1 when it gives none (an encoder may not support the property).
/// Only integer VARIANTs are taken, so nothing needs VariantClear.
static int32_t codec_value(ICodecAPI *api, const GUID *key) {
    VARIANT value;
    memset(&value, 0, sizeof(value));
    if (FAILED(ICodecAPI_GetValue(api, key, &value))) return -1;
    switch (value.vt) {
    case VT_UI4: return (int32_t)value.ulVal;
    case VT_I4: return (int32_t)value.lVal;
    case VT_UI8: return value.ullVal > INT32_MAX ? INT32_MAX : (int32_t)value.ullVal;
    default: return -1;
    }
}

static HRESULT codec_set_uint32(ICodecAPI *api, const GUID *key, UINT32 number) {
    VARIANT value;
    memset(&value, 0, sizeof(value));
    value.vt = VT_UI4;
    value.ulVal = number;
    return ICodecAPI_SetValue(api, key, &value);
}

/// The encoding parameters the Sink Writer hands the encoder when `quality` (0–100) is asked for: Quality mode at that
/// quality, and a GOP of half a second — about where Apple's AVAssetWriter puts its key frames for the same video.
static HRESULT quality_parameters(uint32_t quality, uint32_t fps, IMFAttributes **out) {
    HRESULT hr = mf.create_attributes(out, 3);
    if (SUCCEEDED(hr)) {
        hr = IMFAttributes_SetUINT32(*out, &CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_Quality);
    }
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUINT32(*out, &CODECAPI_AVEncCommonQuality, quality);
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUINT32(*out, &CODECAPI_AVEncMPVGOPSize, fps > 1 ? fps / 2 : 1);
    return hr;
}

/// Once the encoder is in the stream (after SetInputMediaType), reads back the rate control it took and settles it:
/// Quality mode as asked, or — when the encoder kept another mode — unconstrained VBR whose mean is `video_bit_rate`,
/// or else whatever it keeps (its default is CBR at the type's average). What it ends on is recorded on `writer`.
/// Never fails the open: an encoder that cannot be asked still writes, at its default.
static void settle_rate_control(cmf_mp4_writer *writer, uint32_t video_bit_rate) {
    writer->rate_mode = -1;
    writer->rate_quality = -1;
    ICodecAPI *api = NULL;
    if (FAILED(IMFSinkWriter_GetServiceForStream(writer->sink, writer->video_stream, &GUID_NULL, &IID_ICodecAPI,
                                                 (void **)&api)) || api == NULL) {
        return;
    }
    int32_t mode = codec_value(api, &CODECAPI_AVEncCommonRateControlMode);
    if (mode != eAVEncCommonRateControlMode_Quality) {
        codec_set_uint32(api, &CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_UnconstrainedVBR);
        codec_set_uint32(api, &CODECAPI_AVEncCommonMeanBitRate, video_bit_rate);
        mode = codec_value(api, &CODECAPI_AVEncCommonRateControlMode);
    }
    writer->rate_mode = mode;
    writer->rate_quality = mode == eAVEncCommonRateControlMode_Quality
        ? codec_value(api, &CODECAPI_AVEncCommonQuality) : -1;
    ICodecAPI_Release(api);
}

int32_t cmf_mp4_rate_control(cmf_mp4_writer *writer, int32_t *mode, int32_t *quality) {
    *mode = writer->rate_mode;
    *quality = writer->rate_quality;
    return 0;
}

int32_t cmf_mp4_open(const uint16_t *path, uint32_t width, uint32_t height, uint32_t fps, uint32_t video_bit_rate,
                     int32_t video_quality, uint32_t sample_rate, uint32_t channels, uint32_t audio_bit_rate,
                     cmf_mp4_writer **out) {
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
    writer->matrix = matrix_for_height(height);
    writer->path = _wcsdup((const wchar_t *)path);
    if (writer->path == NULL) {
        free(writer);
        return (int32_t)E_OUTOFMEMORY;
    }
    writer->com_initialized = SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED));
    writer->rate_mode = -1;
    writer->rate_quality = -1;
    HRESULT hr = mf.startup(MF_VERSION, MFSTARTUP_LITE);
    writer->mf_started = SUCCEEDED(hr);
    IMFAttributes *attributes = NULL;
    IMFAttributes *encoding = NULL;
    IMFMediaType *h264 = NULL;
    IMFMediaType *bgra = NULL;
    IMFMediaType *aac = NULL;
    IMFMediaType *pcm = NULL;
    if (SUCCEEDED(hr)) hr = mf.create_attributes(&attributes, 2);
    if (SUCCEEDED(hr)) {
        hr = IMFAttributes_SetGUID(attributes, &MF_TRANSCODE_CONTAINERTYPE, &MFTranscodeContainerType_MPEG4);
    }
    // Hardware transforms are allowed: no encoder, software or hardware, was seen to write the colour into the stream,
    // so the colour does not depend on which one Media Foundation picks (`matrix_for_height`, `add_colr`).
    if (SUCCEEDED(hr)) hr = IMFAttributes_SetUINT32(attributes, &MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    if (SUCCEEDED(hr)) hr = mf.create_sink_writer((LPCWSTR)path, NULL, attributes, &writer->sink);
    // Video: H.264 out; BGRA in (the frame canvas's pixels), the Sink Writer converting to the encoder's NV12.
    if (SUCCEEDED(hr)) hr = video_type(&h264, &MFVideoFormat_H264, width, height, fps);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(h264, &MF_MT_AVG_BITRATE, video_bit_rate);
    // Asked for a quality: High profile (the default is Baseline) and the encoding parameters for Quality mode.
    if (SUCCEEDED(hr) && video_quality >= 0) {
        hr = IMFMediaType_SetUINT32(h264, &MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
        uint32_t quality = (uint32_t)(video_quality > 100 ? 100 : video_quality);
        if (SUCCEEDED(hr)) hr = quality_parameters(quality, fps, &encoding);
    }
    if (SUCCEEDED(hr)) hr = tag_colour(h264, writer->matrix);
    if (SUCCEEDED(hr)) hr = IMFSinkWriter_AddStream(writer->sink, h264, &writer->video_stream);
    // NV12 in, converted here from the caller's BGRA (`bgra_to_nv12`) rather than by the converter the Sink Writer
    // would insert for RGB32: that converter ignored the colour tags and the colours came back shifted by up to 13
    // levels. Converting here, the data is in the matrix the `colr` box names by construction. Rows top-down (a
    // positive stride).
    if (SUCCEEDED(hr)) hr = video_type(&bgra, &MFVideoFormat_NV12, width, height, fps);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(bgra, &MF_MT_DEFAULT_STRIDE, width);
    if (SUCCEEDED(hr)) hr = tag_colour(bgra, writer->matrix);
    if (SUCCEEDED(hr)) hr = IMFSinkWriter_SetInputMediaType(writer->sink, writer->video_stream, bgra, encoding);
    if (SUCCEEDED(hr) && video_quality >= 0) settle_rate_control(writer, video_bit_rate);
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
    if (encoding) IMFAttributes_Release(encoding);
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
    bgra_to_nv12(bgra, writer->nv12, writer->width, writer->height, writer->matrix);
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
    HRESULT hr = IMFSinkWriter_Finalize(writer->sink);
    if (FAILED(hr)) return (int32_t)hr;
    // The Sink Writer lets go of the file only when it is released; the box is written after.
    IMFSinkWriter_Release(writer->sink);
    writer->sink = NULL;
    return (int32_t)add_colr(writer->path, writer->matrix->colr_matrix);
}

void cmf_mp4_close(cmf_mp4_writer *writer) {
    if (writer == NULL) return;
    if (writer->sink) IMFSinkWriter_Release(writer->sink);
    free(writer->path);
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

/// A source reader over `path` whose first video stream decodes to NV12 (no colour conversion), and that stream's
/// current type. The caller releases both.
static HRESULT open_nv12_reader(const uint16_t *path, IMFSourceReader **reader, IMFMediaType **current) {
    *reader = NULL;
    *current = NULL;
    IMFMediaType *nv12 = NULL;
    HRESULT hr = mf.create_source_reader((LPCWSTR)path, NULL, reader);
    if (SUCCEEDED(hr)) hr = mf.create_media_type(&nv12);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(nv12, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(nv12, &MF_MT_SUBTYPE, &MFVideoFormat_NV12);
    if (SUCCEEDED(hr)) {
        hr = IMFSourceReader_SetCurrentMediaType(*reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, nv12);
    }
    if (SUCCEEDED(hr)) {
        hr = IMFSourceReader_GetCurrentMediaType(*reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, current);
    }
    if (nv12) IMFMediaType_Release(nv12);
    return hr;
}

int32_t cmf_mp4_first_frame_yuv(const uint16_t *path, uint32_t x, uint32_t y, uint8_t *yuv) {
    memset(yuv, 0, 3);
    if (!ensure_loaded() || mf.create_source_reader == NULL) return (int32_t)E_NOTIMPL;
    BOOL com = SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED));
    HRESULT hr = mf.startup(MF_VERSION, MFSTARTUP_LITE);
    BOOL started = SUCCEEDED(hr);
    IMFSourceReader *reader = NULL;
    IMFMediaType *current = NULL;
    IMFSample *sample = NULL;
    IMFMediaBuffer *buffer = NULL;
    IMF2DBuffer *buffer2d = NULL;
    if (SUCCEEDED(hr)) hr = open_nv12_reader(path, &reader, &current);
    // The decoded frame's allocated size: a 180-row picture may come in a 192-row frame, the chroma plane after it.
    UINT32 frame_width = 0;
    UINT32 frame_height = 0;
    if (SUCCEEDED(hr)) {
        UINT64 size = 0;
        IMFMediaType_GetUINT64(current, &MF_MT_FRAME_SIZE, &size);
        frame_width = (UINT32)(size >> 32);
        frame_height = (UINT32)(size & 0xFFFFFFFF);
        if (x >= frame_width || y >= frame_height) hr = E_INVALIDARG;
    }
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
    BYTE *top = NULL;
    LONG pitch = 0;
    BOOL locked2d = FALSE;
    BOOL locked = FALSE;
    if (SUCCEEDED(hr) && SUCCEEDED(IMFMediaBuffer_QueryInterface(buffer, &IID_IMF2DBuffer, (void **)&buffer2d))) {
        hr = IMF2DBuffer_Lock2D(buffer2d, &top, &pitch);
        locked2d = SUCCEEDED(hr);
    } else if (SUCCEEDED(hr)) {
        hr = IMFMediaBuffer_Lock(buffer, &top, NULL, NULL);
        pitch = (LONG)frame_width;
        locked = SUCCEEDED(hr);
    }
    if (SUCCEEDED(hr)) {
        const BYTE *chroma = top + (LONG)frame_height * pitch;
        yuv[0] = top[(LONG)y * pitch + (LONG)x];
        yuv[1] = chroma[(LONG)(y / 2) * pitch + (LONG)(x / 2) * 2];
        yuv[2] = chroma[(LONG)(y / 2) * pitch + (LONG)(x / 2) * 2 + 1];
    }
    if (locked2d) IMF2DBuffer_Unlock2D(buffer2d);
    if (locked) IMFMediaBuffer_Unlock(buffer);
    if (buffer2d) IMF2DBuffer_Release(buffer2d);
    if (buffer) IMFMediaBuffer_Release(buffer);
    if (sample) IMFSample_Release(sample);
    if (current) IMFMediaType_Release(current);
    if (reader) IMFSourceReader_Release(reader);
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

// MARK: - Audio decode and probe

int32_t cmf_audio_decoder_available(void) {
    return ensure_loaded() && mf.create_source_reader != NULL ? 1 : 0;
}

/// Whether `subtype` is the FourCC-based audio subtype for `fourcc`: what Media Foundation reports for a sample entry
/// it has no named format for, such as FairPlay's `drms` or CENC's `enca`.
static BOOL subtype_is_fourcc(const GUID *subtype, const char *fourcc) {
    GUID expected = MFAudioFormat_PCM;
    expected.Data1 = (DWORD)(BYTE)fourcc[0] | ((DWORD)(BYTE)fourcc[1] << 8) | ((DWORD)(BYTE)fourcc[2] << 16) |
                     ((DWORD)(BYTE)fourcc[3] << 24);
    return IsEqualGUID(subtype, &expected);
}

/// Whether an AAC stream's type names AAC-LC: the AudioSpecificConfig after the HEAACWAVEINFO fields in
/// `MF_MT_USER_DATA` (object type 2), or failing that the profile-level indication (0x28 … 0x2B, the AAC profile).
static int32_t aac_is_lc(IMFMediaType *type) {
    // HEAACWAVEINFO's own fields after its WAVEFORMATEX: payload type, profile level, struct type, two reserved.
    const UINT32 wave_info_fields = 12;
    UINT32 size = 0;
    if (SUCCEEDED(IMFMediaType_GetBlobSize(type, &MF_MT_USER_DATA, &size)) && size >= wave_info_fields + 2) {
        BYTE *blob = (BYTE *)malloc(size);
        int32_t lc = -1;
        if (blob != NULL && SUCCEEDED(IMFMediaType_GetBlob(type, &MF_MT_USER_DATA, blob, size, NULL))) {
            const BYTE *config = blob + wave_info_fields;
            UINT32 object = config[0] >> 3;
            if (object == 31) object = 32 + (((UINT32)(config[0] & 7) << 3) | (config[1] >> 5));
            lc = object == 2 ? 1 : 0;
        }
        free(blob);
        if (lc >= 0) return lc;
    }
    UINT32 level = 0;
    if (SUCCEEDED(IMFMediaType_GetUINT32(type, &MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, &level))) {
        return level >= 0x28 && level <= 0x2B ? 1 : 0;
    }
    return 0;
}

int32_t cmf_audio_probe(const uint16_t *path, cmf_audio_probe_result *result) {
    memset(result, 0, sizeof(*result));
    result->status = CMF_AUDIO_UNREADABLE;
    if (!ensure_loaded() || mf.create_source_reader == NULL) return (int32_t)E_NOTIMPL;
    BOOL com = SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED));
    HRESULT hr = mf.startup(MF_VERSION, MFSTARTUP_LITE);
    BOOL started = SUCCEEDED(hr);
    IMFSourceReader *reader = NULL;
    if (SUCCEEDED(hr)) {
        HRESULT opened = mf.create_source_reader((LPCWSTR)path, NULL, &reader);
        // A file that does not open is a status, not a failure of the probe.
        if (opened == MF_E_DRM_UNSUPPORTED) result->status = CMF_AUDIO_PROTECTED;
    }
    if (reader != NULL) {
        PROPVARIANT value;
        PropVariantInit(&value);
        if (SUCCEEDED(IMFSourceReader_GetPresentationAttribute(reader, (DWORD)MF_SOURCE_READER_MEDIASOURCE,
                                                               &MF_PD_DURATION, &value))) {
            result->duration_100ns = (int64_t)value.uhVal.QuadPart;
        }
        PropVariantClear(&value);
        IMFMediaType *type = NULL;
        HRESULT audio = IMFSourceReader_GetNativeMediaType(reader, (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &type);
        if (FAILED(audio)) {
            // Some other stream (index 0) is there: a container with no audio track. None at all: unreadable.
            IMFMediaType *other = NULL;
            if (SUCCEEDED(IMFSourceReader_GetNativeMediaType(reader, 0, 0, &other))) {
                result->status = CMF_AUDIO_NO_AUDIO_TRACK;
                IMFMediaType_Release(other);
            }
        } else {
            GUID subtype = GUID_NULL;
            UINT32 rate = 0;
            UINT32 channels = 0;
            UINT32 bytes_per_second = 0;
            IMFMediaType_GetGUID(type, &MF_MT_SUBTYPE, &subtype);
            IMFMediaType_GetUINT32(type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
            IMFMediaType_GetUINT32(type, &MF_MT_AUDIO_NUM_CHANNELS, &channels);
            if (subtype_is_fourcc(&subtype, "drms") || subtype_is_fourcc(&subtype, "enca")) {
                result->status = CMF_AUDIO_PROTECTED;
            } else if (rate > 0 && channels > 0) {
                result->status = CMF_AUDIO_READ;
                result->sample_rate = rate;
                result->channels = channels;
                result->is_aac_lc = IsEqualGUID(&subtype, &MFAudioFormat_AAC) ? aac_is_lc(type) : 0;
                PropVariantInit(&value);
                if (SUCCEEDED(IMFSourceReader_GetPresentationAttribute(reader, (DWORD)MF_SOURCE_READER_MEDIASOURCE,
                                                                       &MF_PD_AUDIO_ENCODING_BITRATE, &value)) &&
                    value.vt == VT_UI4) {
                    result->bit_rate = value.ulVal;
                }
                PropVariantClear(&value);
                if (result->bit_rate == 0 &&
                    SUCCEEDED(IMFMediaType_GetUINT32(type, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, &bytes_per_second))) {
                    result->bit_rate = bytes_per_second * 8;
                }
            }
            IMFMediaType_Release(type);
        }
        IMFSourceReader_Release(reader);
    }
    if (started) mf.shutdown();
    if (com) CoUninitialize();
    return started ? 0 : (int32_t)hr;
}

struct cmf_audio_reader {
    IMFSourceReader *reader;
    uint32_t channels;
    /// The last block, copied out of Media Foundation's buffer so the sample can be released at once.
    BYTE *block;
    DWORD block_capacity;
    BOOL ended;
    BOOL com_initialized;
    BOOL mf_started;
};

int32_t cmf_audio_reader_open(const uint16_t *path, cmf_audio_reader **out, uint32_t *sample_rate,
                              uint32_t *channels) {
    return cmf_audio_reader_open_as(path, 0, 0, out, sample_rate, channels);
}

int32_t cmf_audio_reader_open_as(const uint16_t *path, uint32_t want_rate, uint32_t want_channels,
                                 cmf_audio_reader **out, uint32_t *sample_rate, uint32_t *channels) {
    *out = NULL;
    *sample_rate = 0;
    *channels = 0;
    if (!ensure_loaded() || mf.create_source_reader == NULL) return (int32_t)E_NOTIMPL;
    cmf_audio_reader *reader = (cmf_audio_reader *)calloc(1, sizeof(cmf_audio_reader));
    if (reader == NULL) return (int32_t)E_OUTOFMEMORY;
    reader->com_initialized = SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED));
    HRESULT hr = mf.startup(MF_VERSION, MFSTARTUP_LITE);
    reader->mf_started = SUCCEEDED(hr);
    IMFMediaType *native = NULL;
    IMFMediaType *pcm = NULL;
    IMFMediaType *current = NULL;
    UINT32 rate = 0;
    UINT32 count = 0;
    const DWORD audio = (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM;
    if (SUCCEEDED(hr)) hr = mf.create_source_reader((LPCWSTR)path, NULL, &reader->reader);
    if (SUCCEEDED(hr)) hr = IMFSourceReader_SetStreamSelection(reader->reader, (DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    if (SUCCEEDED(hr)) hr = IMFSourceReader_SetStreamSelection(reader->reader, audio, TRUE);
    if (SUCCEEDED(hr)) hr = IMFSourceReader_GetNativeMediaType(reader->reader, audio, 0, &native);
    if (SUCCEEDED(hr)) hr = IMFMediaType_GetUINT32(native, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
    if (SUCCEEDED(hr)) hr = IMFMediaType_GetUINT32(native, &MF_MT_AUDIO_NUM_CHANNELS, &count);
    if (SUCCEEDED(hr) && (rate == 0 || count == 0)) hr = MF_E_INVALIDMEDIATYPE;
    // The stream's own rate and channels unless the caller asks for others, so a plain open inserts only the decoder.
    if (SUCCEEDED(hr) && want_rate != 0) rate = want_rate;
    if (SUCCEEDED(hr) && want_channels != 0) count = want_channels;
    if (SUCCEEDED(hr)) hr = audio_type(&pcm, &MFAudioFormat_PCM, rate, count, rate * count * 2);
    if (SUCCEEDED(hr)) hr = IMFSourceReader_SetCurrentMediaType(reader->reader, audio, NULL, pcm);
    // What the decoder actually delivers: an HE-AAC stream can decode at twice the rate its sample entry states.
    if (SUCCEEDED(hr)) hr = IMFSourceReader_GetCurrentMediaType(reader->reader, audio, &current);
    if (SUCCEEDED(hr)) hr = IMFMediaType_GetUINT32(current, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
    if (SUCCEEDED(hr)) hr = IMFMediaType_GetUINT32(current, &MF_MT_AUDIO_NUM_CHANNELS, &count);
    if (native) IMFMediaType_Release(native);
    if (pcm) IMFMediaType_Release(pcm);
    if (current) IMFMediaType_Release(current);
    if (FAILED(hr)) {
        cmf_audio_reader_close(reader);
        return (int32_t)hr;
    }
    reader->channels = count;
    *sample_rate = rate;
    *channels = count;
    *out = reader;
    return 0;
}

int32_t cmf_audio_reader_read(cmf_audio_reader *reader, const int16_t **samples, uint32_t *frames,
                              int64_t *start_100ns, int32_t *end) {
    *samples = (const int16_t *)reader->block;
    *frames = 0;
    *start_100ns = 0;
    *end = 0;
    if (reader->ended) {
        *end = 1;
        return 0;
    }
    IMFSample *sample = NULL;
    HRESULT hr = S_OK;
    // A read can bring a stream tick and no sample: read on until a block or the end comes.
    while (SUCCEEDED(hr) && sample == NULL && !reader->ended) {
        DWORD stream = 0;
        DWORD flags = 0;
        LONGLONG time = 0;
        hr = IMFSourceReader_ReadSample(reader->reader, (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &stream, &flags,
                                        &time, &sample);
        if (SUCCEEDED(hr) && (flags & MF_SOURCE_READERF_ERROR)) hr = E_FAIL;
        // The decoder changing its output mid-stream would change the frame size under the caller.
        if (SUCCEEDED(hr) && (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED)) hr = MF_E_INVALIDMEDIATYPE;
        if (SUCCEEDED(hr) && (flags & MF_SOURCE_READERF_ENDOFSTREAM)) reader->ended = TRUE;
        if (SUCCEEDED(hr) && sample != NULL) *start_100ns = time;
    }
    IMFMediaBuffer *buffer = NULL;
    if (SUCCEEDED(hr) && sample != NULL) hr = IMFSample_ConvertToContiguousBuffer(sample, &buffer);
    if (SUCCEEDED(hr) && buffer != NULL) {
        BYTE *data = NULL;
        DWORD length = 0;
        hr = IMFMediaBuffer_Lock(buffer, &data, NULL, &length);
        if (SUCCEEDED(hr)) {
            if (length > reader->block_capacity) {
                BYTE *grown = (BYTE *)realloc(reader->block, length);
                if (grown == NULL) {
                    hr = E_OUTOFMEMORY;
                } else {
                    reader->block = grown;
                    reader->block_capacity = length;
                }
            }
            if (SUCCEEDED(hr)) {
                memcpy(reader->block, data, length);
                *samples = (const int16_t *)reader->block;
                *frames = length / (reader->channels * 2);
            }
            IMFMediaBuffer_Unlock(buffer);
        }
    }
    if (buffer) IMFMediaBuffer_Release(buffer);
    if (sample) IMFSample_Release(sample);
    if (SUCCEEDED(hr) && *frames == 0 && reader->ended) *end = 1;
    return (int32_t)hr;
}

void cmf_audio_reader_close(cmf_audio_reader *reader) {
    if (reader == NULL) return;
    if (reader->reader) IMFSourceReader_Release(reader->reader);
    free(reader->block);
    if (reader->mf_started) mf.shutdown();
    if (reader->com_initialized) CoUninitialize();
    free(reader);
}
