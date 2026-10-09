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

#ifdef __cplusplus
}
#endif

#endif
