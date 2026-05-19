# FluidSynth Android Artifact Vetting

**Date:** 2026-05-19
**Task:** Plan Task 1 — vet Maven artifact for `SheetMusicAudioAndroid` Kotlin module
**Outcome:** PROCEED — per-staff `fluid_synth_t` architecture confirmed viable

---

## 1. Chosen Artifact

**Note on `dev.atsushieno:fluidsynth-android`:** This coordinate does not exist.
`dev.atsushieno` publishes MIDI utilities (`ktmidi`, `missingdot`, etc.) on Maven Central
but has never published a `fluidsynth-android` artifact. The spec's "or equivalent" clause
applies; the correct artifact is from VolcanoMobile.

**Chosen artifact:**

```
net.volcanomobile.fluidsynth-android:fluidsynth-android:2.4.6
```

**Gradle dependency line:**

```kotlin
implementation("net.volcanomobile.fluidsynth-android:fluidsynth-android:2.4.6")
```

**Maven Central metadata URL:**
`https://repo1.maven.org/maven2/net/volcanomobile/fluidsynth-android/fluidsynth-android/maven-metadata.xml`

**Published versions (Maven Central):**

| Version | Last Updated |
|---------|-------------|
| 2.1.7   | (oldest) |
| 2.3.3   | 2021–2023 |
| 2.4.3   | 2025 |
| **2.4.6** | **2025-06-06** (latest) |

**Source repository:** https://github.com/VolcanoMobile/fluidsynth-android
(fork of FluidSynth/fluidsynth; maintained by Philippe Simons / Volcano Mobile)

**Last commit:** 2025-06-06 ("bump to v2.4.6")
**Open issues:** 0 (verified on GitHub issues page)

---

## 2. License

FluidSynth is licensed under **LGPL 2.1**. The `LICENSE` file in the VolcanoMobile repo
is the full text of LGPL v2.1.

**Dynamic-link compliance assessment:**

- The AAR ships `libfluidsynth.so` as a **shared library** (ELF, dynamically linked).
  `objdump -p` confirms: `SONAME libfluidsynth.so`, `NEEDED libc.so`, `libc++_shared.so`, etc.
  — no static linking of FluidSynth into the host binary.
- Under LGPL §4, distribution of a dynamically linked application is permitted without
  opening the application's source code, provided:
  1. The user can replace the LGPL library with a modified version (satisfied: `.so` is
     a separate file the user can swap at the JNI layer).
  2. Attribution: application must include the LGPL notice and a pointer to source.
- **Required downstream attribution:** `Android/SheetMusicAudioAndroid/README.md` must
  include: "This module uses FluidSynth (LGPL 2.1). Source: https://github.com/VolcanoMobile/fluidsynth-android".
  The example app's About or Open-Source licenses screen must list FluidSynth LGPL 2.1.

**`libc++_shared.so` note:** The `.so` depends on `libc++_shared.so` (NDK C++ STL).
Gradle handles this automatically in release APK builds via the AGP STL packaging rules.
For `.aar`-to-`.aar` distribution the host app must ensure a consistent `c++_shared` STL
variant (standard in modern AGP >= 7.x with `android.ndkVersion` pinned). Not a blocker;
document in module README.

---

## 3. ABI Coverage

Verified by inspecting `prefab/modules/fluidsynth/libs/` inside the `.aar`:

| ABI | Present | Min API | NDK |
|-----|---------|---------|-----|
| `arm64-v8a` | YES | 21 | 21 |
| `x86_64` | YES | 21 | 21 |
| `armeabi-v7a` | YES | 16 | 21 |
| `x86` | YES | 21 | 21 |

Both required ABIs (`arm64-v8a` and `x86_64`) are present. The spec-required minimum
API for the Swift Android SDK is 28; the AAR supports API 21+, so there is no conflict.

---

## 4. FluidSynth Upstream Version

- **Version bundled:** 2.4.6 (confirmed from `prefab/modules/fluidsynth/include/fluidsynth/version.h`:
  `#define FLUIDSYNTH_VERSION "2.4.6"`)
- **Series:** FluidSynth **2.x** (not 3.x)
- **Latest upstream:** 2.5.4 (released 2025-04-19). No 3.0 release exists as of 2026-05-19.

**Relevant 2.x feature history:**

| Feature | Introduced |
|---------|-----------|
| `fluid_player_seek` | 2.0.0 |
| `fluid_player_get_current_tick` | 1.1.7 (stable since) |
| `fluid_player_set_playback_callback` | 1.1.4 |
| `fluid_player_add_mem` | 2.x |
| 16kB page-size alignment (Android 15+) | 2.5.x |

**2.4.6 notable fix:** "Fix MIDI player skipping some events when seeking" (upstream
issue #1532). This directly improves `fluid_player_seek` reliability for our seek-on-cursor use case.

**Version gap (2.4.6 vs 2.5.4):** The 2.5.x series requires a C++11-compliant compiler
linkage and drops SDL2 (uses SDL3). For our use case (Oboe audio driver, no shell), the
behavioral gap is small. The VolcanoMobile artifact at 2.4.6 is well-tested on Android;
upgrading to 2.5.x would require VolcanoMobile to publish a new version. This is a
tracked risk (see Section 7).

---

## 5. API Symbol Coverage

All symbols were verified in two ways:
1. `nm -D libfluidsynth.so` against the arm64-v8a `.so` extracted from the 2.4.6 `.aar`.
2. Header declarations in `prefab/modules/fluidsynth/include/fluidsynth/{synth,midi}.h`.

The AAR is a **native-only prefab** (no Kotlin/Java wrapper classes bundled). All calls
are raw NDK JNI via `System.loadLibrary("fluidsynth")` + `external fun` declarations.

| Symbol | Status | Notes |
|--------|--------|-------|
| `new_fluid_synth` | AVAILABLE | `fluid_synth_t* new_fluid_synth(fluid_settings_t*)` |
| `delete_fluid_synth` | AVAILABLE | `void delete_fluid_synth(fluid_synth_t*)` |
| `fluid_synth_sfload` | AVAILABLE | `int fluid_synth_sfload(fluid_synth_t*, const char* filename, int reset_presets)` |
| `fluid_synth_program_select` | AVAILABLE | `int fluid_synth_program_select(fluid_synth_t*, int chan, int sfont_id, int bank_num, int preset_num)` |
| `fluid_synth_noteon` | AVAILABLE | `int fluid_synth_noteon(fluid_synth_t*, int chan, int key, int vel)` |
| `fluid_synth_noteoff` | AVAILABLE | `int fluid_synth_noteoff(fluid_synth_t*, int chan, int key)` |
| `fluid_synth_all_notes_off` | AVAILABLE | `int fluid_synth_all_notes_off(fluid_synth_t*, int chan)` |
| `fluid_synth_set_gain` | AVAILABLE | `void fluid_synth_set_gain(fluid_synth_t*, float gain)` — global gain, not per-channel; see note |
| `fluid_synth_cc` | AVAILABLE | `int fluid_synth_cc(fluid_synth_t*, int chan, int ctrl, int val)` |
| `fluid_synth_handle_midi_event` | AVAILABLE | `int fluid_synth_handle_midi_event(void* data, fluid_midi_event_t* event)` |
| `fluid_synth_write_float` | AVAILABLE | `int fluid_synth_write_float(fluid_synth_t*, int len, void* lout, int loff, int lincr, void* rout, int roff, int rincr)` |
| `new_fluid_player` | AVAILABLE | `fluid_player_t* new_fluid_player(fluid_synth_t*)` |
| `delete_fluid_player` | AVAILABLE | `void delete_fluid_player(fluid_player_t*)` |
| `fluid_player_add_mem` | AVAILABLE | `int fluid_player_add_mem(fluid_player_t*, const void* buffer, size_t len)` |
| `fluid_player_play` | AVAILABLE | `int fluid_player_play(fluid_player_t*)` |
| `fluid_player_stop` | AVAILABLE | `int fluid_player_stop(fluid_player_t*)` — "pause and remember" semantics |
| `fluid_player_join` | AVAILABLE | `int fluid_player_join(fluid_player_t*)` |
| `fluid_player_seek` | AVAILABLE | `int fluid_player_seek(fluid_player_t*, int ticks)` — since 2.0.0; seek-event fix in 2.4.6 |
| `fluid_player_get_current_tick` | AVAILABLE | `int fluid_player_get_current_tick(fluid_player_t*)` — since 1.1.7 |
| `fluid_player_set_playback_callback` | AVAILABLE | `int fluid_player_set_playback_callback(fluid_player_t*, handle_midi_event_func_t, void*)` |

**All 20 required symbols are present and exported from the `.so`.**

### `fluid_synth_set_gain` note

`fluid_synth_set_gain` applies a **global gain** to the entire `fluid_synth_t` instance —
not per-channel gain. In the per-staff architecture (one `fluid_synth_t` per staff), this
maps cleanly to per-staff volume: calling `setGain(volume)` on staff N's synth adjusts
that staff's output level, which is exactly what `setStaffVolume` needs.

In the *single*-synth alternative, per-channel volume would need MIDI CC 7 instead:
`fluid_synth_cc(synth, channel, 7, volume*127)`. This works but is slightly less precise
(7-bit resolution vs. float gain). This is a minor distinction and does not drive the
architecture decision.

---

## 6. Decision: Per-Staff vs. Single-`fluid_synth_t`

**Decision: Continue with per-staff `fluid_synth_t`** as specified.

Rationale:

1. **`fluid_synth_set_gain` maps cleanly.** One `fluid_synth_t` per staff means
   `setGain(float)` is the exact volume knob for that staff. Clean 1:1 mapping.
   In single-synth architecture, per-channel gain would require CC 7 (7-bit resolution)
   or a FluidSynth extension API that was not vetted.

2. **All required symbols are available.** No missing API forces a pivot.

3. **16-staff ceiling is identical either way.** The spec already acknowledges this;
   the constraint is MIDI channel field width, not FluidSynth instance count.

4. **Metronome gets its own `fluid_synth_t`.** This is already specified (standalone
   drum-kit synth). Per-staff architecture is consistent with this pattern.

5. **None of the spec's pivot triggers were hit:**
   - Per-channel gain API: present (`fluid_synth_set_gain` on each instance).
   - Memory benchmark: not yet run on device, but the spec calls for a benchmark task.
     If density benchmarks exceed thresholds, the single-synth pivot is documented as
     the immediate fallback (spec §"Alternative architectures considered").
   - Implementation complexity: playback callback dispatch to per-staff staves is
     well-described in the spec and straightforward with the available API surface.

---

## 7. Risks

1. **Version gap (2.4.6 vs 2.5.4).** VolcanoMobile has not yet published a 2.5.x artifact.
   FluidSynth 2.5.x adds Android 15+ 16kB page-size alignment for large-page devices.
   Devices with 16kB pages (some Samsung Galaxy / Pixel 9+ configurations) may exhibit
   crashes loading a 4kB-aligned `.so` on 16kB-page kernels. Mitigation: watch
   VolcanoMobile's repo for a 2.5.x bump; add `android:extractNativeLibs="false"` to the
   manifest to enable page-aligned extraction on modern AGP.

2. **Single-maintainer bottleneck.** The VolcanoMobile repo is maintained by one developer
   (Philippe Simons). The last publish was June 2025; if the maintainer becomes inactive,
   bumping to a newer FluidSynth requires forking the build. Mitigation: the spec's
   long-term plan already notes "Phase 5 may graduate to an in-repo NDK build of FluidSynth."
   In the interim, the prefab AAR format makes it feasible to self-host a CI-built replacement
   with a compatible Maven coordinate.

3. **`libc++_shared.so` collisions.** The `.so` is built with `c++_shared`. If another
   native library in the host APK uses a conflicting STL variant (e.g., `c++_static`),
   C++ global state can corrupt. Mitigation: document in `README.md` that the host app
   must set `android.defaultConfig.externalNativeBuild` / `ndk.stl = "c++_shared"`, and
   use `abiFilters` matching the prefab's supported ABIs.

4. **`fluid_player_get_current_tick` polling cost.** The spec calls for a 30 Hz poll
   from a Kotlin coroutine. The function is a simple atomic read on FluidSynth's player
   thread; no known lock-contention issues in 2.4.x. The race condition issue #648 was
   for `fluid_player_get_total_ticks` (not current tick) and is closed. Low risk, but
   the plan includes a latency benchmark on arm64 device.

5. **SF2 caching and content URI resolution.** `fluid_synth_sfload` takes a file path,
   not a content `Uri`. The Kotlin engine must materialize content URIs to
   `context.cacheDir`. Large SF2 files (50+ MB) on a slow device storage may add seconds
   to `prepare`. Mitigation: copy to cache on first use; cache keyed by URI hash and reused
   across staves with identical program (already described in spec).

---

## 8. Sources

- Maven Central metadata: https://repo1.maven.org/maven2/net/volcanomobile/fluidsynth-android/fluidsynth-android/maven-metadata.xml
- VolcanoMobile/fluidsynth-android repository: https://github.com/VolcanoMobile/fluidsynth-android
- VolcanoMobile/fluidsynth-android commit history: https://github.com/VolcanoMobile/fluidsynth-android/commits/master
- VolcanoMobile/fluidsynth-android issues: https://github.com/VolcanoMobile/fluidsynth-android/issues
- FluidSynth upstream releases: https://github.com/FluidSynth/fluidsynth/releases
- FluidSynth 2.5 API docs (MIDI Player group): https://www.fluidsynth.org/api/group__midi__player.html
- Libraries.io entry: https://libraries.io/maven/net.volcanomobile.fluidsynth-android:fluidsynth-android
- dev.atsushieno Maven Central namespace (no fluidsynth artifact): https://repo1.maven.org/maven2/dev/atsushieno/
- FluidSynth race condition issue (get_total_ticks, closed): https://github.com/FluidSynth/fluidsynth/issues/648
- Android NDK C++ STL guidance: https://developer.android.com/ndk/guides/cpp-support
