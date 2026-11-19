#define COBJMACROS
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <stdlib.h>
#include <string.h>

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
    volatile LONG capture_changed;
    HANDLE event;
    IMMDeviceEnumerator *enumerator;
};

static cwasapi_watcher *cwasapi_watcher_of(IMMNotificationClient *client) {
    return (cwasapi_watcher *)client;
}

// A change of the default render device: the render flag only.
static void cwasapi_watcher_signal(IMMNotificationClient *client) {
    cwasapi_watcher *watcher = cwasapi_watcher_of(client);
    InterlockedExchange(&watcher->changed, 1);
    SetEvent(watcher->event);
}

// A change of the default capture device: the capture flag only.
static void cwasapi_watcher_signal_capture(IMMNotificationClient *client) {
    cwasapi_watcher *watcher = cwasapi_watcher_of(client);
    InterlockedExchange(&watcher->capture_changed, 1);
    SetEvent(watcher->event);
}

// A device's state changed or a device went away, which may concern either direction: both flags.
static void cwasapi_watcher_signal_both(IMMNotificationClient *client) {
    cwasapi_watcher *watcher = cwasapi_watcher_of(client);
    InterlockedExchange(&watcher->changed, 1);
    InterlockedExchange(&watcher->capture_changed, 1);
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
    cwasapi_watcher_signal_both(client);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE cwasapi_watcher_added(IMMNotificationClient *client, LPCWSTR id) {
    (void)client;
    (void)id;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE cwasapi_watcher_removed(IMMNotificationClient *client, LPCWSTR id) {
    (void)id;
    cwasapi_watcher_signal_both(client);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE cwasapi_watcher_default_changed(
    IMMNotificationClient *client, EDataFlow flow, ERole role, LPCWSTR id) {
    (void)id;
    // The engine opens eRender / eConsole and the capture eCapture / eConsole; the other roles change alongside them
    // or not at all for either.
    if (role == eConsole && flow == eRender) {
        cwasapi_watcher_signal(client);
    } else if (role == eConsole && flow == eCapture) {
        cwasapi_watcher_signal_capture(client);
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

int32_t cwasapi_watch_take_capture_change(cwasapi_watcher *watcher) {
    return InterlockedExchange(&watcher->capture_changed, 0) != 0 ? 1 : 0;
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

// MARK: - Capture

static const IID cwasapi_iid_capture = {0xC8ADBD64, 0xE71E, 0x48A0, {0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17}};
static const IID cwasapi_iid_endpoint = {0x1BE09788, 0x6894, 0x4089, {0x85, 0x86, 0x9A, 0x2A, 0x6C, 0x26, 0x5A, 0xC5}};
// PKEY_Device_FriendlyName
static const PROPERTYKEY cwasapi_pkey_friendly_name = {
    {0xA45C254E, 0xDF1C, 0x4EFD, {0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0}}, 14};

// 40 ms of buffer, as for playback: how long the capture thread may be late before the device overwrites unread audio.
// A packet still arrives every device period; the buffer only bounds how far reading may fall behind.
static const REFERENCE_TIME cwasapi_capture_buffer_duration = 400000;

struct cwasapi_capture {
    IMMDeviceEnumerator *enumerator;
    IMMDevice *device;
    IAudioClient *client;
    IAudioCaptureClient *capture;
    HANDLE event;
};

int32_t cwasapi_is_access_denied(int32_t hresult) {
    return hresult == (int32_t)E_ACCESSDENIED ? 1 : 0;
}

// `text` (UTF-8) as a new UTF-16 string, or NULL when it is not UTF-8 or memory ran out. Free with `free`.
static WCHAR *cwasapi_wide(const char *text) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (count <= 0) {
        return NULL;
    }
    WCHAR *wide = malloc((size_t)count * sizeof(WCHAR));
    if (wide == NULL) {
        return NULL;
    }
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count) != count) {
        free(wide);
        return NULL;
    }
    return wide;
}

// `wide` (UTF-16; NULL reads as empty) as a new UTF-8 string, empty when it cannot be converted. NULL only when memory
// ran out. Free with `free`.
static char *cwasapi_utf8(LPCWSTR wide) {
    int count = wide != NULL ? WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL) : 0;
    char *text = malloc(count > 0 ? (size_t)count : 1);
    if (text == NULL) {
        return NULL;
    }
    if (count <= 0 || WideCharToMultiByte(CP_UTF8, 0, wide, -1, text, count, NULL, NULL) != count) {
        text[0] = '\0';
    }
    return text;
}

// Whether `device` is an active capture endpoint.
static int cwasapi_is_active_capture(IMMDevice *device) {
    DWORD state = 0;
    if (FAILED(IMMDevice_GetState(device, &state)) || state != DEVICE_STATE_ACTIVE) {
        return 0;
    }
    IMMEndpoint *endpoint = NULL;
    if (FAILED(IMMDevice_QueryInterface(device, &cwasapi_iid_endpoint, (void **)&endpoint))) {
        return 0;
    }
    EDataFlow flow = eRender;
    HRESULT hr = IMMEndpoint_GetDataFlow(endpoint, &flow);
    IMMEndpoint_Release(endpoint);
    return SUCCEEDED(hr) && flow == eCapture ? 1 : 0;
}

// The default capture endpoint (eCapture / eConsole) for a NULL `device_id`, else the active capture endpoint with that
// id. Anything else — an id Windows does not know, a malformed one, a render endpoint's, one unplugged or disabled —
// fails as E_NOTFOUND, which `cwasapi_is_no_device` reads.
static HRESULT cwasapi_capture_device(IMMDeviceEnumerator *enumerator, const char *device_id, IMMDevice **device) {
    *device = NULL;
    if (device_id == NULL) {
        return IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, eCapture, eConsole, device);
    }
    WCHAR *wide = cwasapi_wide(device_id);
    if (wide == NULL) {
        return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    }
    HRESULT hr = IMMDeviceEnumerator_GetDevice(enumerator, wide, device);
    free(wide);
    if (FAILED(hr)) {
        *device = NULL;
        return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    }
    if (!cwasapi_is_active_capture(*device)) {
        IMMDevice_Release(*device);
        *device = NULL;
        return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    }
    return S_OK;
}

int32_t cwasapi_capture_open(
    cwasapi_capture **capture, cwasapi_capture_format *format, uint32_t sample_rate, const char *device_id) {
    *capture = NULL;
    if (sample_rate == 0) {
        return (int32_t)E_INVALIDARG;
    }
    cwasapi_capture *c = calloc(1, sizeof *c);
    if (c == NULL) {
        return (int32_t)E_OUTOFMEMORY;
    }
    REFERENCE_TIME latency = 0;
    REFERENCE_TIME period = 0;
    REFERENCE_TIME minimum_period = 0;
    UINT32 buffer_frames = 0;
    WAVEFORMATEXTENSIBLE wanted;
    ZeroMemory(&wanted, sizeof wanted);

    // RPC_E_CHANGED_MODE: the thread is already in a single-threaded apartment, which serves as well.
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
        goto fail;
    }
    hr = CoCreateInstance(
        &cwasapi_clsid_enumerator, NULL, CLSCTX_ALL, &cwasapi_iid_enumerator, (void **)&c->enumerator);
    if (FAILED(hr)) {
        goto fail;
    }
    hr = cwasapi_capture_device(c->enumerator, device_id, &c->device);
    if (FAILED(hr)) {
        goto fail;
    }
    // E_ACCESSDENIED here is the privacy setting: Activate is where Windows asks whether this app may use the
    // microphone.
    hr = IMMDevice_Activate(c->device, &cwasapi_iid_client, CLSCTX_ALL, NULL, (void **)&c->client);
    if (FAILED(hr)) {
        goto fail;
    }

    wanted.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    wanted.Format.nChannels = 1;
    wanted.Format.nSamplesPerSec = sample_rate;
    wanted.Format.wBitsPerSample = 32;
    wanted.Format.nBlockAlign = sizeof(float);
    wanted.Format.nAvgBytesPerSec = sample_rate * wanted.Format.nBlockAlign;
    wanted.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    wanted.Samples.wValidBitsPerSample = 32;
    wanted.dwChannelMask = SPEAKER_FRONT_CENTER;
    wanted.SubFormat = cwasapi_subtype_float;

    // AUTOCONVERTPCM mixes a stereo or multichannel microphone down to the one channel asked for and converts its rate
    // to `sample_rate`, as it lets playback keep its own format.
    DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
        | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    hr = IAudioClient_Initialize(
        c->client, AUDCLNT_SHAREMODE_SHARED, flags, cwasapi_capture_buffer_duration, 0, (WAVEFORMATEX *)&wanted,
        NULL);
    if (FAILED(hr)) {
        goto fail;
    }
    c->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (c->event == NULL) {
        hr = HRESULT_FROM_WIN32(GetLastError());
        goto fail;
    }
    hr = IAudioClient_SetEventHandle(c->client, c->event);
    if (FAILED(hr)) {
        goto fail;
    }
    hr = IAudioClient_GetBufferSize(c->client, &buffer_frames);
    if (FAILED(hr)) {
        goto fail;
    }
    hr = IAudioClient_GetService(c->client, &cwasapi_iid_capture, (void **)&c->capture);
    if (FAILED(hr)) {
        goto fail;
    }
    // Both are figures for the host's latency model, not conditions for capturing: a failure reads as 0.
    if (FAILED(IAudioClient_GetStreamLatency(c->client, &latency))) {
        latency = 0;
    }
    if (FAILED(IAudioClient_GetDevicePeriod(c->client, &period, &minimum_period))) {
        period = 0;
    }

    format->sample_rate = sample_rate;
    format->channels = 1;
    format->buffer_frames = buffer_frames;
    format->latency_seconds = (double)latency / 1e7;
    format->period_seconds = (double)period / 1e7;
    *capture = c;
    return 0;

fail:
    cwasapi_capture_close(c);
    return (int32_t)hr;
}

int32_t cwasapi_capture_start(cwasapi_capture *capture) {
    return (int32_t)IAudioClient_Start(capture->client);
}

int32_t cwasapi_capture_stop(cwasapi_capture *capture) {
    return (int32_t)IAudioClient_Stop(capture->client);
}

int32_t cwasapi_capture_wait(cwasapi_capture *capture, uint32_t timeout_ms) {
    return WaitForSingleObject(capture->event, timeout_ms) == WAIT_OBJECT_0 ? 0 : 1;
}

int32_t cwasapi_capture_next(
    cwasapi_capture *capture, uint32_t *frames, float **data, int32_t *silent, int32_t *discontinuity) {
    *frames = 0;
    *data = NULL;
    *silent = 0;
    *discontinuity = 0;
    UINT32 waiting = 0;
    HRESULT hr = IAudioCaptureClient_GetNextPacketSize(capture->capture, &waiting);
    if (FAILED(hr)) {
        return (int32_t)hr;
    }
    if (waiting == 0) {
        return 0;
    }
    BYTE *bytes = NULL;
    UINT32 count = 0;
    DWORD packet_flags = 0;
    hr = IAudioCaptureClient_GetBuffer(capture->capture, &bytes, &count, &packet_flags, NULL, NULL);
    if (FAILED(hr)) {
        return (int32_t)hr;
    }
    // AUDCLNT_S_BUFFER_EMPTY is a success with no packet, and nothing to release.
    if (hr == AUDCLNT_S_BUFFER_EMPTY || count == 0) {
        return 0;
    }
    *frames = count;
    *data = (float *)bytes;
    *silent = (packet_flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 ? 1 : 0;
    *discontinuity = (packet_flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0 ? 1 : 0;
    return 0;
}

int32_t cwasapi_capture_release(cwasapi_capture *capture, uint32_t frames) {
    return (int32_t)IAudioCaptureClient_ReleaseBuffer(capture->capture, frames);
}

int32_t cwasapi_capture_is_current_default(cwasapi_capture *capture) {
    IMMDevice *current = NULL;
    if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(capture->enumerator, eCapture, eConsole, &current))) {
        return 0;
    }
    LPWSTR current_id = NULL;
    LPWSTR own_id = NULL;
    int32_t same = 0;
    if (SUCCEEDED(IMMDevice_GetId(current, &current_id)) && SUCCEEDED(IMMDevice_GetId(capture->device, &own_id))) {
        same = lstrcmpW(current_id, own_id) == 0 ? 1 : 0;
    }
    CoTaskMemFree(current_id);
    CoTaskMemFree(own_id);
    IMMDevice_Release(current);
    return same;
}

cwasapi_endpoint *cwasapi_capture_endpoint(cwasapi_capture *capture) {
    IMMDevice_AddRef(capture->device);
    return (cwasapi_endpoint *)capture->device;
}

void cwasapi_capture_close(cwasapi_capture *capture) {
    if (capture == NULL) {
        return;
    }
    if (capture->client != NULL) {
        IAudioClient_Stop(capture->client);
    }
    if (capture->capture != NULL) {
        IAudioCaptureClient_Release(capture->capture);
    }
    if (capture->client != NULL) {
        IAudioClient_Release(capture->client);
    }
    if (capture->device != NULL) {
        IMMDevice_Release(capture->device);
    }
    if (capture->enumerator != NULL) {
        IMMDeviceEnumerator_Release(capture->enumerator);
    }
    if (capture->event != NULL) {
        CloseHandle(capture->event);
    }
    free(capture);
}

// MARK: - Capture endpoints

struct cwasapi_device_list {
    uint32_t count;
    int32_t default_index;
    char **ids;
    char **names;
};

// `device`'s friendly name ("Microphone (USB Audio Device)") as a new UTF-8 string, empty when it cannot be read. NULL
// only when memory ran out.
static char *cwasapi_device_name(IMMDevice *device) {
    IPropertyStore *store = NULL;
    char *name = NULL;
    if (SUCCEEDED(IMMDevice_OpenPropertyStore(device, STGM_READ, &store))) {
        PROPVARIANT value;
        PropVariantInit(&value);
        if (SUCCEEDED(IPropertyStore_GetValue(store, &cwasapi_pkey_friendly_name, &value)) && value.vt == VT_LPWSTR) {
            name = cwasapi_utf8(value.pwszVal);
        }
        PropVariantClear(&value);
        IPropertyStore_Release(store);
    }
    return name != NULL ? name : cwasapi_utf8(NULL);
}

int32_t cwasapi_capture_devices(cwasapi_device_list **out) {
    *out = NULL;
    cwasapi_device_list *list = calloc(1, sizeof *list);
    if (list == NULL) {
        return (int32_t)E_OUTOFMEMORY;
    }
    list->default_index = -1;
    IMMDeviceEnumerator *enumerator = NULL;
    IMMDeviceCollection *collection = NULL;
    IMMDevice *default_device = NULL;
    LPWSTR default_id = NULL;
    UINT count = 0;

    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
        goto done;
    }
    hr = CoCreateInstance(&cwasapi_clsid_enumerator, NULL, CLSCTX_ALL, &cwasapi_iid_enumerator, (void **)&enumerator);
    if (FAILED(hr)) {
        goto done;
    }
    hr = IMMDeviceEnumerator_EnumAudioEndpoints(enumerator, eCapture, DEVICE_STATE_ACTIVE, &collection);
    if (FAILED(hr)) {
        goto done;
    }
    hr = IMMDeviceCollection_GetCount(collection, &count);
    if (FAILED(hr)) {
        goto done;
    }
    // No default (E_NOTFOUND) when there is no endpoint, which is not a failure of the listing.
    if (SUCCEEDED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, eCapture, eConsole, &default_device))) {
        if (FAILED(IMMDevice_GetId(default_device, &default_id))) {
            default_id = NULL;
        }
    }
    if (count > 0) {
        list->ids = calloc(count, sizeof(char *));
        list->names = calloc(count, sizeof(char *));
        if (list->ids == NULL || list->names == NULL) {
            hr = E_OUTOFMEMORY;
            goto done;
        }
    }
    for (UINT index = 0; index < count; index++) {
        IMMDevice *device = NULL;
        if (FAILED(IMMDeviceCollection_Item(collection, index, &device))) {
            continue;
        }
        LPWSTR id = NULL;
        if (SUCCEEDED(IMMDevice_GetId(device, &id))) {
            char *id_text = cwasapi_utf8(id);
            char *name_text = cwasapi_device_name(device);
            if (id_text == NULL || name_text == NULL) {
                free(id_text);
                free(name_text);
                CoTaskMemFree(id);
                IMMDevice_Release(device);
                hr = E_OUTOFMEMORY;
                goto done;
            }
            if (default_id != NULL && lstrcmpW(id, default_id) == 0) {
                list->default_index = (int32_t)list->count;
            }
            list->ids[list->count] = id_text;
            list->names[list->count] = name_text;
            list->count += 1;
            CoTaskMemFree(id);
        }
        IMMDevice_Release(device);
    }
    hr = S_OK;

done:
    CoTaskMemFree(default_id);
    if (default_device != NULL) {
        IMMDevice_Release(default_device);
    }
    if (collection != NULL) {
        IMMDeviceCollection_Release(collection);
    }
    if (enumerator != NULL) {
        IMMDeviceEnumerator_Release(enumerator);
    }
    if (FAILED(hr)) {
        cwasapi_device_list_free(list);
        return (int32_t)hr;
    }
    *out = list;
    return 0;
}

uint32_t cwasapi_device_list_count(cwasapi_device_list *list) {
    return list->count;
}

const char *cwasapi_device_list_id(cwasapi_device_list *list, uint32_t index) {
    return index < list->count ? list->ids[index] : "";
}

const char *cwasapi_device_list_name(cwasapi_device_list *list, uint32_t index) {
    return index < list->count ? list->names[index] : "";
}

int32_t cwasapi_device_list_default_index(cwasapi_device_list *list) {
    return list->default_index;
}

void cwasapi_device_list_free(cwasapi_device_list *list) {
    if (list == NULL) {
        return;
    }
    for (uint32_t index = 0; index < list->count; index++) {
        free(list->ids[index]);
        free(list->names[index]);
    }
    free(list->ids);
    free(list->names);
    free(list);
}
