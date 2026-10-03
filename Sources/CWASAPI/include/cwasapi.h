// WASAPI shared-mode output for SheetMusicAudioWindows: the few calls the playback engine makes, in C.
//
// The Windows SDK module the Swift toolchain ships (WinSDK) carries COM but not the Core Audio headers
// (audioclient.h, mmdeviceapi.h), and COM interfaces are simpler to drive from C through COBJMACROS than through
// vtables from Swift. Every function returns 0 or a failing HRESULT unless it says otherwise.
#ifndef CWASAPI_H
#define CWASAPI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cwasapi_stream cwasapi_stream;

typedef struct {
    /// The device's own mix rate; the stream is opened at it so Windows does no rate conversion.
    uint32_t sample_rate;
    /// Always 2: interleaved stereo float, whatever the device has (Windows converts the channel layout).
    uint32_t channels;
    /// The shared buffer's size in frames; at most this many can be queued.
    uint32_t buffer_frames;
} cwasapi_format;

/// Opens the default render endpoint in shared, event-driven mode as 32-bit float stereo at the device's mix rate.
int32_t cwasapi_open(cwasapi_stream **stream, cwasapi_format *format);
/// `cwasapi_open` at `sample_rate` (0: the device's mix rate). Windows converts to the device's own rate — how an engine
/// keeps its synth's rate when the default device changes to one that runs at another.
int32_t cwasapi_open_at_rate(cwasapi_stream **stream, cwasapi_format *format, uint32_t sample_rate);

/// Whether `hresult` says the endpoint went away or changed under the stream (AUDCLNT_E_DEVICE_INVALIDATED,
/// AUDCLNT_E_RESOURCES_INVALIDATED): close the stream and open a new one on the current default. Returns 1 or 0.
int32_t cwasapi_is_device_lost(int32_t hresult);
/// Whether `hresult` says there is no render endpoint at all (E_NOTFOUND from the default-endpoint lookup). 1 or 0.
int32_t cwasapi_is_no_device(int32_t hresult);
/// Whether `stream` is on the current default render endpoint (eRender / eConsole): 1 or 0 (0 also when there is no
/// default, or the ids cannot be read). A watcher's change flag covers every endpoint, capture ones included; this
/// tells a change that concerns the stream from one that does not. Call on the stream's own thread.
int32_t cwasapi_is_current_default(cwasapi_stream *stream);

/// The endpoint a stream plays through (an `IMMDevice`), held by its own reference so it outlives `cwasapi_close`: how
/// the stream asks, after closing on a change, whether its device went away or only stopped being the default.
typedef struct cwasapi_endpoint cwasapi_endpoint;
/// `stream`'s endpoint, with a reference for the caller (release with `cwasapi_endpoint_release`). Never NULL for an
/// open stream.
cwasapi_endpoint *cwasapi_stream_endpoint(cwasapi_stream *stream);
/// Whether `endpoint` is still present and enabled (DEVICE_STATE_ACTIVE): 1 or 0. 0 when it was unplugged, disabled
/// or removed — and when its state cannot be read.
int32_t cwasapi_endpoint_is_active(cwasapi_endpoint *endpoint);
void cwasapi_endpoint_release(cwasapi_endpoint *endpoint);

/// Fault injection for probes: with the environment variable SSM_WASAPI_FAIL_ONCE set to `invalidated` when the
/// process starts, the first `cwasapi_writable_frames` after `cwasapi_arm_fault` returns
/// AUDCLNT_E_DEVICE_INVALIDATED once. With `device_removed` nonzero, the next `cwasapi_endpoint_is_active` also
/// answers 0 once, as for an unplugged device; with 0 the device stays (a default change, a driver reset). Does
/// nothing without the variable.
void cwasapi_arm_fault(int32_t device_removed);

/// Watches the endpoints for a change of the default render device or of a device's state, through an
/// `IMMNotificationClient`. The callbacks arrive on a system thread; they only set a flag and signal an event.
typedef struct cwasapi_watcher cwasapi_watcher;
int32_t cwasapi_watch_create(cwasapi_watcher **watcher);
/// 1 when the default render device or a device's state changed since the last call, and clears it; else 0.
int32_t cwasapi_watch_take_change(cwasapi_watcher *watcher);
/// An auto-reset event signaled on every change, for a thread waiting with no stream (no device).
void *cwasapi_watch_event(cwasapi_watcher *watcher);
/// Blocks until the watcher's event is signaled or `timeout_ms` passes: 0 when signaled, 1 on timeout. Leaves the
/// flag `cwasapi_watch_take_change` reads alone.
int32_t cwasapi_watch_wait(cwasapi_watcher *watcher, uint32_t timeout_ms);
void cwasapi_watch_destroy(cwasapi_watcher *watcher);
int32_t cwasapi_start(cwasapi_stream *stream);
int32_t cwasapi_stop(cwasapi_stream *stream);
/// Drops queued audio and zeroes the clock. Only while stopped.
int32_t cwasapi_reset(cwasapi_stream *stream);
/// Blocks until the device asks for data or `timeout_ms` passes. Returns 0 when asked, 1 on timeout.
int32_t cwasapi_wait(cwasapi_stream *stream, uint32_t timeout_ms);
/// Frames that can be written now: the buffer size minus what is still queued.
int32_t cwasapi_writable_frames(cwasapi_stream *stream, uint32_t *frames);
int32_t cwasapi_get_buffer(cwasapi_stream *stream, uint32_t frames, float **data);
int32_t cwasapi_release_buffer(cwasapi_stream *stream, uint32_t frames, int32_t silent);
/// The device clock (`IAudioClock`): seconds of audio the endpoint has played since the stream started. It holds
/// still while stopped and returns to 0 on reset — the clock a cursor follows, since it counts what was heard rather
/// than what was handed over.
int32_t cwasapi_position_seconds(cwasapi_stream *stream, double *seconds);
/// The stream latency Windows reports, in seconds.
int32_t cwasapi_latency_seconds(cwasapi_stream *stream, double *seconds);
/// Releases everything `cwasapi_open` acquired. Accepts NULL. COM stays initialized for the process.
void cwasapi_close(cwasapi_stream *stream);

/// Puts the calling thread in the multimedia scheduler's "Pro Audio" class. Returns a handle for
/// `cwasapi_leave_pro_audio`, or NULL when the scheduler refused (the thread then runs at normal priority).
void *cwasapi_enter_pro_audio(void);
void cwasapi_leave_pro_audio(void *handle);

#ifdef __cplusplus
}
#endif

#endif
