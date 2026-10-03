#define COBJMACROS
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <stdlib.h>

#include "cwasapi.h"

// The interface and class ids, spelled out rather than taken from initguid.h or uuid.lib so this file links alone.
static const CLSID cwasapi_clsid_enumerator =
    {0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}};
static const IID cwasapi_iid_enumerator =
    {0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}};
static const IID cwasapi_iid_client = {0x1CB9AD4C, 0xDBFA, 0x4C32, {0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}};
static const IID cwasapi_iid_render = {0xF294ACFC, 0x3146, 0x4483, {0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2}};
static const IID cwasapi_iid_clock = {0xCD63314F, 0x3FBA, 0x4A1B, {0x81, 0x2C, 0xEF, 0x96, 0x35, 0x87, 0x28, 0xE7}};
// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
static const GUID cwasapi_subtype_float = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};

// 40 ms of buffer. Long enough that a slow two-core machine refills it in time; the cursor does not pay for it,
// because it follows the device clock rather than the frames handed over.
static const REFERENCE_TIME cwasapi_buffer_duration = 400000;

struct cwasapi_stream {
    IMMDeviceEnumerator *enumerator;
    IMMDevice *device;
    IAudioClient *client;
    IAudioRenderClient *render;
    IAudioClock *clock;
    HANDLE event;
    UINT32 buffer_frames;
    UINT64 clock_frequency;
};

int32_t cwasapi_open(cwasapi_stream **stream, cwasapi_format *format) {
    return cwasapi_open_at_rate(stream, format, 0);
}

int32_t cwasapi_open_at_rate(cwasapi_stream **stream, cwasapi_format *format, uint32_t sample_rate) {
    *stream = NULL;
    cwasapi_stream *s = calloc(1, sizeof *s);
    if (s == NULL) {
        return (int32_t)E_OUTOFMEMORY;
    }
    // RPC_E_CHANGED_MODE: the thread is already in a single-threaded apartment, which serves as well.
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
        goto fail;
    }
    hr = CoCreateInstance(
        &cwasapi_clsid_enumerator, NULL, CLSCTX_ALL, &cwasapi_iid_enumerator, (void **)&s->enumerator);
    if (FAILED(hr)) {
        goto fail;
    }
    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(s->enumerator, eRender, eConsole, &s->device);
    if (FAILED(hr)) {
        goto fail;
    }
    hr = IMMDevice_Activate(s->device, &cwasapi_iid_client, CLSCTX_ALL, NULL, (void **)&s->client);
    if (FAILED(hr)) {
        goto fail;
    }

    WAVEFORMATEX *mix = NULL;
    hr = IAudioClient_GetMixFormat(s->client, &mix);
    if (FAILED(hr)) {
        goto fail;
    }
    DWORD rate = sample_rate != 0 ? sample_rate : mix->nSamplesPerSec;
    CoTaskMemFree(mix);

    WAVEFORMATEXTENSIBLE wanted;
    ZeroMemory(&wanted, sizeof wanted);
    wanted.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    wanted.Format.nChannels = 2;
    wanted.Format.nSamplesPerSec = rate;
    wanted.Format.wBitsPerSample = 32;
    wanted.Format.nBlockAlign = 2 * sizeof(float);
    wanted.Format.nAvgBytesPerSec = rate * wanted.Format.nBlockAlign;
    wanted.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    wanted.Samples.wValidBitsPerSample = 32;
    wanted.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
    wanted.SubFormat = cwasapi_subtype_float;

    // AUTOCONVERTPCM lets the stream be stereo float on a device whose mix format is something else (5.1, 24-bit), and
    // at a rate other than the device's (`cwasapi_open_at_rate`), which Windows then resamples.
    DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
        | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    hr = IAudioClient_Initialize(
        s->client, AUDCLNT_SHAREMODE_SHARED, flags, cwasapi_buffer_duration, 0, (WAVEFORMATEX *)&wanted, NULL);
    if (FAILED(hr)) {
        goto fail;
    }
    s->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (s->event == NULL) {
        hr = HRESULT_FROM_WIN32(GetLastError());
        goto fail;
    }
    hr = IAudioClient_SetEventHandle(s->client, s->event);
    if (FAILED(hr)) {
        goto fail;
    }
    hr = IAudioClient_GetBufferSize(s->client, &s->buffer_frames);
    if (FAILED(hr)) {
        goto fail;
    }
    hr = IAudioClient_GetService(s->client, &cwasapi_iid_render, (void **)&s->render);
    if (FAILED(hr)) {
        goto fail;
    }
    hr = IAudioClient_GetService(s->client, &cwasapi_iid_clock, (void **)&s->clock);
    if (FAILED(hr)) {
        goto fail;
    }
    hr = IAudioClock_GetFrequency(s->clock, &s->clock_frequency);
    if (FAILED(hr)) {
        goto fail;
    }

    format->sample_rate = rate;
    format->channels = 2;
    format->buffer_frames = s->buffer_frames;
    *stream = s;
    return 0;

fail:
    cwasapi_close(s);
    return (int32_t)hr;
}

int32_t cwasapi_start(cwasapi_stream *stream) {
    return (int32_t)IAudioClient_Start(stream->client);
}

int32_t cwasapi_stop(cwasapi_stream *stream) {
    return (int32_t)IAudioClient_Stop(stream->client);
}

int32_t cwasapi_reset(cwasapi_stream *stream) {
    return (int32_t)IAudioClient_Reset(stream->client);
}

int32_t cwasapi_wait(cwasapi_stream *stream, uint32_t timeout_ms) {
    return WaitForSingleObject(stream->event, timeout_ms) == WAIT_OBJECT_0 ? 0 : 1;
}

static volatile LONG cwasapi_fault_armed = 0;
static volatile LONG cwasapi_fault_removed = 0;

void cwasapi_arm_fault(int32_t device_removed) {
    char value[32];
    DWORD length = GetEnvironmentVariableA("SSM_WASAPI_FAIL_ONCE", value, sizeof value);
    if (length > 0 && length < sizeof value && lstrcmpiA(value, "invalidated") == 0) {
        InterlockedExchange(&cwasapi_fault_removed, device_removed != 0 ? 1 : 0);
        InterlockedExchange(&cwasapi_fault_armed, 1);
    }
}

cwasapi_endpoint *cwasapi_stream_endpoint(cwasapi_stream *stream) {
    IMMDevice_AddRef(stream->device);
    return (cwasapi_endpoint *)stream->device;
}

int32_t cwasapi_endpoint_is_active(cwasapi_endpoint *endpoint) {
    if (InterlockedExchange(&cwasapi_fault_removed, 0) != 0) {
        return 0;
    }
    DWORD state = 0;
    if (FAILED(IMMDevice_GetState((IMMDevice *)endpoint, &state))) {
        return 0;
    }
    return state == DEVICE_STATE_ACTIVE ? 1 : 0;
}

void cwasapi_endpoint_release(cwasapi_endpoint *endpoint) {
    if (endpoint != NULL) {
        IMMDevice_Release((IMMDevice *)endpoint);
    }
}

int32_t cwasapi_is_device_lost(int32_t hresult) {
    return hresult == (int32_t)AUDCLNT_E_DEVICE_INVALIDATED || hresult == (int32_t)AUDCLNT_E_RESOURCES_INVALIDATED;
}

int32_t cwasapi_is_no_device(int32_t hresult) {
    return hresult == (int32_t)HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

int32_t cwasapi_is_current_default(cwasapi_stream *stream) {
    IMMDevice *current = NULL;
    if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(stream->enumerator, eRender, eConsole, &current))) {
        return 0;
    }
    LPWSTR current_id = NULL;
    LPWSTR own_id = NULL;
    int32_t same = 0;
    if (SUCCEEDED(IMMDevice_GetId(current, &current_id)) && SUCCEEDED(IMMDevice_GetId(stream->device, &own_id))) {
        same = lstrcmpW(current_id, own_id) == 0 ? 1 : 0;
    }
    CoTaskMemFree(current_id);
    CoTaskMemFree(own_id);
    IMMDevice_Release(current);
    return same;
}

int32_t cwasapi_writable_frames(cwasapi_stream *stream, uint32_t *frames) {
    if (InterlockedExchange(&cwasapi_fault_armed, 0) != 0) {
        return (int32_t)AUDCLNT_E_DEVICE_INVALIDATED;
    }
    UINT32 padding = 0;
    HRESULT hr = IAudioClient_GetCurrentPadding(stream->client, &padding);
    if (FAILED(hr)) {
        return (int32_t)hr;
    }
    *frames = stream->buffer_frames - padding;
    return 0;
}

int32_t cwasapi_get_buffer(cwasapi_stream *stream, uint32_t frames, float **data) {
    BYTE *bytes = NULL;
    HRESULT hr = IAudioRenderClient_GetBuffer(stream->render, frames, &bytes);
    *data = (float *)bytes;
    return (int32_t)hr;
}

int32_t cwasapi_release_buffer(cwasapi_stream *stream, uint32_t frames, int32_t silent) {
    return (int32_t)IAudioRenderClient_ReleaseBuffer(stream->render, frames, silent ? AUDCLNT_BUFFERFLAGS_SILENT : 0);
}

int32_t cwasapi_position_seconds(cwasapi_stream *stream, double *seconds) {
    UINT64 position = 0;
    HRESULT hr = IAudioClock_GetPosition(stream->clock, &position, NULL);
    if (FAILED(hr)) {
        return (int32_t)hr;
    }
    *seconds = stream->clock_frequency != 0 ? (double)position / (double)stream->clock_frequency : 0;
    return 0;
}

int32_t cwasapi_latency_seconds(cwasapi_stream *stream, double *seconds) {
    REFERENCE_TIME latency = 0;
    HRESULT hr = IAudioClient_GetStreamLatency(stream->client, &latency);
    if (FAILED(hr)) {
        return (int32_t)hr;
    }
    *seconds = (double)latency / 1e7;
    return 0;
}

void cwasapi_close(cwasapi_stream *stream) {
    if (stream == NULL) {
        return;
    }
    if (stream->client != NULL) {
        IAudioClient_Stop(stream->client);
    }
    if (stream->clock != NULL) {
        IAudioClock_Release(stream->clock);
    }
    if (stream->render != NULL) {
        IAudioRenderClient_Release(stream->render);
    }
    if (stream->client != NULL) {
        IAudioClient_Release(stream->client);
    }
    if (stream->device != NULL) {
        IMMDevice_Release(stream->device);
    }
    if (stream->enumerator != NULL) {
        IMMDeviceEnumerator_Release(stream->enumerator);
    }
    if (stream->event != NULL) {
        CloseHandle(stream->event);
    }
    free(stream);
}

void *cwasapi_enter_pro_audio(void) {
    DWORD task = 0;
    return AvSetMmThreadCharacteristicsW(L"Pro Audio", &task);
}

void cwasapi_leave_pro_audio(void *handle) {
    if (handle != NULL) {
        AvRevertMmThreadCharacteristics(handle);
    }
}

// MARK: - Endpoint notifications

// IMMNotificationClient by hand: C has no classes, so the object is its vtable pointer followed by its state.
static const IID cwasapi_iid_unknown = {0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const IID cwasapi_iid_notification_client =
    {0x7991EEC9, 0x7E89, 0x4D85, {0x83, 0x90, 0x6C, 0x70, 0x3C, 0xEC, 0x60, 0xC0}};

struct cwasapi_watcher {
    IMMNotificationClient client;  // first: the COM pointer is the struct's address
    LONG references;
    volatile LONG changed;
    HANDLE event;
    IMMDeviceEnumerator *enumerator;
};

static cwasapi_watcher *cwasapi_watcher_of(IMMNotificationClient *client) {
    return (cwasapi_watcher *)client;
}

static void cwasapi_watcher_signal(IMMNotificationClient *client) {
    cwasapi_watcher *watcher = cwasapi_watcher_of(client);
    InterlockedExchange(&watcher->changed, 1);
    SetEvent(watcher->event);
}

static HRESULT STDMETHODCALLTYPE cwasapi_watcher_query(IMMNotificationClient *client, REFIID riid, void **object) {
    if (IsEqualIID(riid, &cwasapi_iid_unknown) || IsEqualIID(riid, &cwasapi_iid_notification_client)) {
        *object = client;
        InterlockedIncrement(&cwasapi_watcher_of(client)->references);
        return S_OK;
    }
    *object = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE cwasapi_watcher_add_ref(IMMNotificationClient *client) {
    return (ULONG)InterlockedIncrement(&cwasapi_watcher_of(client)->references);
}

// The watcher's memory is owned by `cwasapi_watch_destroy`, which unregisters first; the count only has to stay honest.
static ULONG STDMETHODCALLTYPE cwasapi_watcher_release(IMMNotificationClient *client) {
    return (ULONG)InterlockedDecrement(&cwasapi_watcher_of(client)->references);
}

static HRESULT STDMETHODCALLTYPE cwasapi_watcher_state_changed(IMMNotificationClient *client, LPCWSTR id, DWORD state) {
    (void)id;
    (void)state;
    cwasapi_watcher_signal(client);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE cwasapi_watcher_added(IMMNotificationClient *client, LPCWSTR id) {
    (void)client;
    (void)id;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE cwasapi_watcher_removed(IMMNotificationClient *client, LPCWSTR id) {
    (void)id;
    cwasapi_watcher_signal(client);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE cwasapi_watcher_default_changed(
    IMMNotificationClient *client, EDataFlow flow, ERole role, LPCWSTR id) {
    (void)id;
    // The engine opens eRender / eConsole; the other roles change alongside it or not at all for playback.
    if (flow == eRender && role == eConsole) {
        cwasapi_watcher_signal(client);
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE cwasapi_watcher_property_changed(
    IMMNotificationClient *client, LPCWSTR id, const PROPERTYKEY key) {
    (void)client;
    (void)id;
    (void)key;
    return S_OK;
}

static IMMNotificationClientVtbl cwasapi_watcher_vtable = {
    cwasapi_watcher_query,
    cwasapi_watcher_add_ref,
    cwasapi_watcher_release,
    cwasapi_watcher_state_changed,
    cwasapi_watcher_added,
    cwasapi_watcher_removed,
    cwasapi_watcher_default_changed,
    cwasapi_watcher_property_changed,
};

int32_t cwasapi_watch_create(cwasapi_watcher **out) {
    *out = NULL;
    cwasapi_watcher *watcher = calloc(1, sizeof *watcher);
    if (watcher == NULL) {
        return (int32_t)E_OUTOFMEMORY;
    }
    watcher->client.lpVtbl = &cwasapi_watcher_vtable;
    watcher->references = 1;
    watcher->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    HRESULT hr = watcher->event != NULL ? S_OK : HRESULT_FROM_WIN32(GetLastError());
    if (SUCCEEDED(hr)) {
        hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
        if (hr == RPC_E_CHANGED_MODE || hr == S_FALSE) hr = S_OK;
    }
    if (SUCCEEDED(hr)) {
        hr = CoCreateInstance(
            &cwasapi_clsid_enumerator, NULL, CLSCTX_ALL, &cwasapi_iid_enumerator, (void **)&watcher->enumerator);
    }
    if (SUCCEEDED(hr)) {
        hr = IMMDeviceEnumerator_RegisterEndpointNotificationCallback(watcher->enumerator, &watcher->client);
    }
    if (FAILED(hr)) {
        if (watcher->enumerator != NULL) IMMDeviceEnumerator_Release(watcher->enumerator);
        if (watcher->event != NULL) CloseHandle(watcher->event);
        free(watcher);
        return (int32_t)hr;
    }
    *out = watcher;
    return 0;
}

int32_t cwasapi_watch_take_change(cwasapi_watcher *watcher) {
    return InterlockedExchange(&watcher->changed, 0) != 0 ? 1 : 0;
}

void *cwasapi_watch_event(cwasapi_watcher *watcher) {
    return watcher->event;
}

int32_t cwasapi_watch_wait(cwasapi_watcher *watcher, uint32_t timeout_ms) {
    return WaitForSingleObject(watcher->event, timeout_ms) == WAIT_OBJECT_0 ? 0 : 1;
}

void cwasapi_watch_destroy(cwasapi_watcher *watcher) {
    if (watcher == NULL) {
        return;
    }
    IMMDeviceEnumerator_UnregisterEndpointNotificationCallback(watcher->enumerator, &watcher->client);
    IMMDeviceEnumerator_Release(watcher->enumerator);
    CloseHandle(watcher->event);
    free(watcher);
}
