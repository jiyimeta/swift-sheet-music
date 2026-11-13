// Media Foundation's AAC encoder and MPEG-4 sink for SheetMusicAudioWindows' audio export: the few calls an export
// makes, in C — COM through COBJMACROS, as CWASAPI drives WASAPI.
//
// mfplat.dll and mfreadwrite.dll are loaded with LoadLibraryW on first use, never linked: Windows "N" editions ship
// without Media Foundation until the Media Feature Pack is installed, and a linked import would stop every app that
// uses this package from starting there. Without them every call answers E_NOTIMPL and `cmf_aac_encoder_available`
// answers 0.
//
// Threading: a writer is used from the one thread that opened it, which `cmf_aac_open` puts in the multithreaded
// apartment (`CoInitializeEx`, balanced in `cmf_aac_close`). Every function returns 0 or a failing HRESULT unless it
// says otherwise.
#ifndef CMEDIAFOUNDATION_H
#define CMEDIAFOUNDATION_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cmf_aac_writer cmf_aac_writer;

/// 1 when Media Foundation loads and lists an AAC encoder, else 0.
int32_t cmf_aac_encoder_available(void);

/// Opens an MPEG-4 file at `path` (UTF-16, replaced if it exists) taking 16-bit PCM at `sample_rate` with `channels`
/// channels, encoded as AAC at `bit_rate` bits per second. E_NOTIMPL (0x80004001) when Media Foundation is absent.
int32_t cmf_aac_open(const uint16_t *path, uint32_t sample_rate, uint32_t channels, uint32_t bit_rate,
                     cmf_aac_writer **writer);

/// Encodes `frames` frames of interleaved 16-bit PCM, `channels` samples each.
int32_t cmf_aac_write(cmf_aac_writer *writer, const int16_t *samples, uint32_t frames);

/// Completes the file. The writer is still to be closed.
int32_t cmf_aac_finish(cmf_aac_writer *writer);

/// Releases everything the writer holds. Accepts NULL; after `cmf_aac_finish`, or instead of it for a file abandoned
/// halfway (which the caller then deletes).
void cmf_aac_close(cmf_aac_writer *writer);

// MARK: - MP4 (H.264 + AAC): a score video

typedef struct cmf_mp4_writer cmf_mp4_writer;

/// 1 when Media Foundation loads and lists both an H.264 video encoder (software or hardware) and an AAC encoder,
/// else 0.
int32_t cmf_mp4_encoder_available(void);

/// Opens an MPEG-4 file at `path` (UTF-16, replaced if it exists) with an H.264 stream of `width` x `height` (both
/// even) at `fps` and `video_bit_rate` bits per second, taking BGRA frames with rows top-down; and, when `sample_rate`
/// and `channels` are not 0, an AAC stream at `audio_bit_rate` taking 16-bit PCM. The video is tagged BT.709, studio
/// range. E_NOTIMPL when Media Foundation is absent, E_INVALIDARG for an odd or empty size.
int32_t cmf_mp4_open(const uint16_t *path, uint32_t width, uint32_t height, uint32_t fps, uint32_t video_bit_rate,
                     uint32_t sample_rate, uint32_t channels, uint32_t audio_bit_rate, cmf_mp4_writer **writer);

/// Encodes the next frame: `width * height * 4` bytes of BGRA, top-down. Its time is the frame count over `fps`.
int32_t cmf_mp4_write_frame(cmf_mp4_writer *writer, const uint8_t *bgra);

/// Encodes `frames` frames of interleaved 16-bit PCM after those written so far. E_UNEXPECTED without an audio stream.
int32_t cmf_mp4_write_audio(cmf_mp4_writer *writer, const int16_t *samples, uint32_t frames);

/// Completes the file. The writer is still to be closed.
int32_t cmf_mp4_finish(cmf_mp4_writer *writer);

/// Releases everything the writer holds. Accepts NULL; after `cmf_mp4_finish`, or instead of it for a file abandoned
/// halfway (which the caller then deletes).
void cmf_mp4_close(cmf_mp4_writer *writer);

/// What the file at `path` holds, read back through Media Foundation's source reader: its duration, its first video
/// stream's size and whether it is H.264, and whether its first audio stream is AAC. For tests.
int32_t cmf_mp4_probe(const uint16_t *path, int64_t *duration_100ns, uint32_t *width, uint32_t *height,
                      int32_t *video_is_h264, int32_t *audio_is_aac);

/// The first frame of the file at `path`, decoded to RGB32 by Media Foundation, at pixel (`x`, `y`) counted from the
/// top-left: its four bytes (B, G, R, X) into `bgra`. For tests of the colour tags and the row order.
int32_t cmf_mp4_first_frame_pixel(const uint16_t *path, uint32_t x, uint32_t y, uint8_t *bgra);

#ifdef __cplusplus
}
#endif

#endif
