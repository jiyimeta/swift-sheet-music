// Media Foundation's AAC encoder and MPEG-4 sink for SheetMusicAudioWindows' audio export, and its source reader for
// a recording's decode and probe: the few calls these make, in C — COM through COBJMACROS, as CWASAPI drives WASAPI.
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
/// and `channels` are not 0, an AAC stream at `audio_bit_rate` taking 16-bit PCM. The frames are written in studio
/// range in the matrix a player assumes for an untagged stream of that height — BT.601 below 720 rows, BT.709 from 720
/// — and `cmf_mp4_finish` names it in a `colr` box. E_NOTIMPL when Media Foundation is absent, E_INVALIDARG for an odd
/// or empty size.
int32_t cmf_mp4_open(const uint16_t *path, uint32_t width, uint32_t height, uint32_t fps, uint32_t video_bit_rate,
                     uint32_t sample_rate, uint32_t channels, uint32_t audio_bit_rate, cmf_mp4_writer **writer);

/// Encodes the next frame: `width * height * 4` bytes of BGRA, top-down. Its time is the frame count over `fps`.
int32_t cmf_mp4_write_frame(cmf_mp4_writer *writer, const uint8_t *bgra);

/// Encodes `frames` frames of interleaved 16-bit PCM after those written so far. E_UNEXPECTED without an audio stream.
int32_t cmf_mp4_write_audio(cmf_mp4_writer *writer, const int16_t *samples, uint32_t frames);

/// Where the frames' time has gone so far: seconds in the BGRA to NV12 conversion and in handing the frames to the
/// Sink Writer (its WriteSample encodes), summed; and the H.264 encoder it chose, read after the first frame — its
/// friendly name (UTF-16, cut to `name_capacity - 1` and terminated; empty when it gives none) and 1 for a hardware
/// MFT, 0 for a software one, -1 when not known. Before `cmf_mp4_finish`.
int32_t cmf_mp4_stats(cmf_mp4_writer *writer, double *convert_seconds, double *write_seconds, uint16_t *encoder_name,
                      uint32_t name_capacity, int32_t *encoder_hardware);

/// Completes the file and adds its `colr` box (S_FALSE when the file's layout left no room for one). The writer is
/// still to be closed.
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

/// The colour the file's video sample entry names in its `colr` (nclx) box, read from the container itself: ISO/IEC
/// 23091-2 codes for the primaries, the transfer and the matrix (1 BT.709, 6 BT.601), and the full-range flag. S_FALSE
/// with zeros when there is no such box. For tests of the colour tag.
int32_t cmf_mp4_colour(const uint16_t *path, uint16_t *primaries, uint16_t *transfer, uint16_t *matrix,
                       uint8_t *full_range);

/// The first frame of the file at `path`, decoded to NV12 with no colour conversion, at pixel (`x`, `y`) from the
/// top-left: its luma, Cb and Cr into `yuv`. What the stream holds, whichever matrix a player would assume.
int32_t cmf_mp4_first_frame_yuv(const uint16_t *path, uint32_t x, uint32_t y, uint8_t *yuv);

// MARK: - Audio decode and probe: a score's recordings

/// What `cmf_audio_probe` found. `status` is one of the `CMF_AUDIO_*` values below.
typedef struct cmf_audio_probe_result {
    int32_t status;
    /// 1 when the first audio stream is AAC whose AudioSpecificConfig names object type 2 (AAC-LC).
    int32_t is_aac_lc;
    /// Bits per second the file states for its audio, 0 when it states none.
    uint32_t bit_rate;
    uint32_t sample_rate;
    uint32_t channels;
    /// The presentation's duration in 100 ns units.
    int64_t duration_100ns;
} cmf_audio_probe_result;

#define CMF_AUDIO_READ 0
/// The file does not open, holds no stream, or its audio stream gives no format.
#define CMF_AUDIO_UNREADABLE 1
/// DRM-protected: Media Foundation refuses it as protected, or its sample entry is FairPlay's `drms`.
#define CMF_AUDIO_PROTECTED 2
/// Streams, none of them audio: a video with no sound.
#define CMF_AUDIO_NO_AUDIO_TRACK 3

/// 1 when Media Foundation loads with its source reader, else 0 (a Windows "N" edition without the Media Feature
/// Pack). Whether a given codec decodes is only known by opening a file.
int32_t cmf_audio_decoder_available(void);

/// Reads the first audio stream's format without decoding it. Returns 0 whenever `result` was filled, the status
/// saying what was found; E_NOTIMPL when Media Foundation is absent.
int32_t cmf_audio_probe(const uint16_t *path, cmf_audio_probe_result *result);

typedef struct cmf_audio_reader cmf_audio_reader;

/// Opens the first audio stream of the file at `path` (UTF-16) for decoding to interleaved 16-bit PCM at the
/// stream's own rate and channel count, which `sample_rate` and `channels` receive. Every other stream is
/// deselected. The thread that opens a reader uses it until it is closed.
int32_t cmf_audio_reader_open(const uint16_t *path, cmf_audio_reader **reader, uint32_t *sample_rate,
                              uint32_t *channels);

/// `cmf_audio_reader_open`, asking the reader for 16-bit PCM at `want_rate` Hz and `want_channels` channels instead
/// of the stream's own (0 keeps the stream's). `sample_rate` and `channels` receive what the reader agreed to deliver;
/// a failing HRESULT when it will not convert to them.
int32_t cmf_audio_reader_open_as(const uint16_t *path, uint32_t want_rate, uint32_t want_channels,
                                 cmf_audio_reader **reader, uint32_t *sample_rate, uint32_t *channels);

/// Decodes the next block: `*frames` frames written to `*samples` (the reader's buffer, valid until the next call or
/// the close), 0 frames with `*end` = 1 at the end of the stream. A block's start is the time Media Foundation stamps
/// it with, `*start_100ns`, which a caller compares with the frames it has so far to see a gap or a priming trim.
int32_t cmf_audio_reader_read(cmf_audio_reader *reader, const int16_t **samples, uint32_t *frames,
                              int64_t *start_100ns, int32_t *end);

/// Releases the reader. Accepts NULL.
void cmf_audio_reader_close(cmf_audio_reader *reader);

#ifdef __cplusplus
}
#endif

#endif
