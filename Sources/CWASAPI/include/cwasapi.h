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
