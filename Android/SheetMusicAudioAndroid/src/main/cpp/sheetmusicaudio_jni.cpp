#include <jni.h>
#include <fluidsynth.h>
#include <cstring>
#include <android/log.h>

#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "smfa-jni", __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  "smfa-jni", __VA_ARGS__)

// ─────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────

static fluid_synth_t *synth_from(jlong handle) {
    return reinterpret_cast<fluid_synth_t *>(handle);
}

static fluid_player_t *player_from(jlong handle) {
    return reinterpret_cast<fluid_player_t *>(handle);
}

// ─────────────────────────────────────────────────────────────────────
// Synth lifecycle
// ─────────────────────────────────────────────────────────────────────

extern "C" JNIEXPORT jlong JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_newSynth(
    JNIEnv *, jobject, jint sampleRate
) {
    fluid_settings_t *settings = new_fluid_settings();
    fluid_settings_setnum(settings, "synth.sample-rate", static_cast<double>(sampleRate));
    fluid_settings_setint(settings, "synth.threadsafe-api", 1);
    fluid_synth_t *synth = new_fluid_synth(settings);
    // Settings ownership: FluidSynth 2.x keeps an internal reference.
    // Do not delete settings here; delete on synth teardown via
    // fluid_synth_get_settings.
    if (synth == nullptr) {
        delete_fluid_settings(settings);
        LOGE("newSynth: new_fluid_synth failed at %d Hz", sampleRate);
        return 0;
    }
    // Default FluidSynth gain is 0.2 (very quiet). FluidSynth accepts
    // 0.0–10.0; values up to ~2.5 are typically fine for SF2 content with
    // moderate dynamics — the internal soft-limiter handles transient peaks.
    // Comparable perceived loudness to AVFoundation's AUMIDISynth (Apple
    // path) is reached around gain=2.0–2.5.
    fluid_synth_set_gain(synth, 2.0f);
    LOGI("newSynth: synth created at %d Hz, gain=2.0", sampleRate);
    return reinterpret_cast<jlong>(synth);
}

extern "C" JNIEXPORT void JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_deleteSynth(
    JNIEnv *, jobject, jlong handle
) {
    fluid_synth_t *synth = synth_from(handle);
    if (synth == nullptr) return;
    fluid_settings_t *settings = fluid_synth_get_settings(synth);
    delete_fluid_synth(synth);
    if (settings != nullptr) delete_fluid_settings(settings);
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_sfload(
    JNIEnv *env, jobject, jlong handle, jstring path, jboolean resetPresets
) {
    fluid_synth_t *synth = synth_from(handle);
    if (synth == nullptr) return -1;
    const char *cpath = env->GetStringUTFChars(path, nullptr);
    int result = fluid_synth_sfload(synth, cpath, resetPresets ? 1 : 0);
    if (result < 0) {
        LOGE("sfload: failed to load '%s' (result=%d)", cpath, result);
    } else {
        LOGI("sfload: loaded '%s' -> sfid=%d", cpath, result);
    }
    env->ReleaseStringUTFChars(path, cpath);
    return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_programSelect(
    JNIEnv *, jobject, jlong handle,
    jint channel, jint sfid, jint bank, jint program
) {
    fluid_synth_t *synth = synth_from(handle);
    if (synth == nullptr) return -1;
    return fluid_synth_program_select(synth, channel, sfid, bank, program);
}

// ─────────────────────────────────────────────────────────────────────
// Voice control
// ─────────────────────────────────────────────────────────────────────

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_noteOn(
    JNIEnv *, jobject, jlong handle, jint ch, jint pitch, jint vel
) {
    fluid_synth_t *synth = synth_from(handle);
    if (synth == nullptr) return -1;
    return fluid_synth_noteon(synth, ch, pitch, vel);
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_noteOff(
    JNIEnv *, jobject, jlong handle, jint ch, jint pitch
) {
    fluid_synth_t *synth = synth_from(handle);
    if (synth == nullptr) return -1;
    return fluid_synth_noteoff(synth, ch, pitch);
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_allNotesOff(
    JNIEnv *, jobject, jlong handle, jint ch
) {
    fluid_synth_t *synth = synth_from(handle);
    if (synth == nullptr) return -1;
    return fluid_synth_all_notes_off(synth, ch);
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_cc(
    JNIEnv *, jobject, jlong handle, jint ch, jint ctrl, jint val
) {
    fluid_synth_t *synth = synth_from(handle);
    if (synth == nullptr) return -1;
    return fluid_synth_cc(synth, ch, ctrl, val);
}

extern "C" JNIEXPORT void JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_setGain(
    JNIEnv *, jobject, jlong handle, jfloat value
) {
    fluid_synth_t *synth = synth_from(handle);
    if (synth == nullptr) return;
    fluid_synth_set_gain(synth, value);
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_setChannelType(
    JNIEnv *, jobject, jlong handle, jint channel, jint type
) {
    fluid_synth_t *synth = synth_from(handle);
    if (synth == nullptr) return -1;
    // type: 0 = CHANNEL_TYPE_MELODIC, 1 = CHANNEL_TYPE_DRUM
    int rc = fluid_synth_set_channel_type(synth, channel, type);
    LOGI("setChannelType: channel=%d type=%d rc=%d", channel, type, rc);
    return rc;
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_getCC(
    JNIEnv *, jobject, jlong handle, jint channel, jint controller
) {
    fluid_synth_t *synth = synth_from(handle);
    if (synth == nullptr) return -1;
    int value = 0;
    int rc = fluid_synth_get_cc(synth, channel, controller, &value);
    return (rc == FLUID_OK) ? value : -1;
}

// ─────────────────────────────────────────────────────────────────────
// Rendering
// ─────────────────────────────────────────────────────────────────────

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_writeFloat(
    JNIEnv *env, jobject, jlong handle, jint frameCount,
    jfloatArray leftArr, jfloatArray rightArr
) {
    fluid_synth_t *synth = synth_from(handle);
    if (synth == nullptr) return -1;
    jfloat *left = env->GetFloatArrayElements(leftArr, nullptr);
    jfloat *right = env->GetFloatArrayElements(rightArr, nullptr);
    int rc = fluid_synth_write_float(
        synth, frameCount, left, 0, 1, right, 0, 1
    );
    env->ReleaseFloatArrayElements(leftArr, left, 0);
    env->ReleaseFloatArrayElements(rightArr, right, 0);
    return rc;
}

// ─────────────────────────────────────────────────────────────────────
// Player
// ─────────────────────────────────────────────────────────────────────

extern "C" JNIEXPORT jlong JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_newPlayer(
    JNIEnv *, jobject, jlong synthHandle
) {
    fluid_synth_t *synth = synth_from(synthHandle);
    if (synth == nullptr) return 0;
    fluid_player_t *player = new_fluid_player(synth);
    return reinterpret_cast<jlong>(player);
}

extern "C" JNIEXPORT void JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_deletePlayer(
    JNIEnv *, jobject, jlong handle
) {
    fluid_player_t *player = player_from(handle);
    if (player == nullptr) return;
    delete_fluid_player(player);
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_playerAddMem(
    JNIEnv *env, jobject, jlong handle, jbyteArray bytes
) {
    fluid_player_t *player = player_from(handle);
    if (player == nullptr) return -1;
    jsize len = env->GetArrayLength(bytes);
    jbyte *buf = env->GetByteArrayElements(bytes, nullptr);
    int rc = fluid_player_add_mem(player, buf, static_cast<size_t>(len));
    env->ReleaseByteArrayElements(bytes, buf, JNI_ABORT);
    return rc;
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_playerPlay(
    JNIEnv *, jobject, jlong handle
) {
    fluid_player_t *player = player_from(handle);
    if (player == nullptr) return -1;
    return fluid_player_play(player);
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_playerStop(
    JNIEnv *, jobject, jlong handle
) {
    fluid_player_t *player = player_from(handle);
    if (player == nullptr) return -1;
    return fluid_player_stop(player);
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_playerJoin(
    JNIEnv *, jobject, jlong handle
) {
    fluid_player_t *player = player_from(handle);
    if (player == nullptr) return -1;
    return fluid_player_join(player);
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_playerSeek(
    JNIEnv *, jobject, jlong handle, jlong tick
) {
    fluid_player_t *player = player_from(handle);
    if (player == nullptr) return -1;
    return fluid_player_seek(player, static_cast<int>(tick));
}

extern "C" JNIEXPORT jlong JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_playerGetCurrentTick(
    JNIEnv *, jobject, jlong handle
) {
    fluid_player_t *player = player_from(handle);
    if (player == nullptr) return 0;
    return static_cast<jlong>(fluid_player_get_current_tick(player));
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_kiichiio_sheetmusic_audio_native_FluidSynthNative_playerSetTempo(
    JNIEnv *, jobject, jlong handle, jint type, jdouble value
) {
    fluid_player_t *player = player_from(handle);
    if (player == nullptr) return -1;
    // type maps to fluid_player_set_tempo_type:
    //   0 = FLUID_PLAYER_TEMPO_INTERNAL (relative scale of internal tempo)
    //   1 = FLUID_PLAYER_TEMPO_EXTERNAL_BPM (absolute BPM)
    //   2 = FLUID_PLAYER_TEMPO_EXTERNAL_MIDI (absolute as MIDI us/quarter)
    // PlayerDriver.setTempo hardcodes 0 (INTERNAL).
    return fluid_player_set_tempo(player, static_cast<int>(type),
                                  static_cast<double>(value));
}
