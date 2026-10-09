#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
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
