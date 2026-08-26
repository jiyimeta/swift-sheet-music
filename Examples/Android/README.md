# SheetMusic — Android Compose example

An end-to-end Kotlin Compose demo that parses an `.mscz` and renders it
to a Compose `Canvas` using the cross-compiled `SheetMusicAndroidJNI`
Swift library.

Playback, mixer controls, and audio-file export are available when a General
MIDI SoundFont is staged into the app's assets. The Play button remains
disabled without one.

## Prerequisites

- macOS or Linux host
- Open-source Swift toolchain matching the repository's Android SDK installed
  (see `docs/development/android.md` at the project root)
- Matching Swift Android SDK installed (`swift sdk list` should report it)
- One-time NDK sysroot setup completed (see the same development guide)
- Android Studio Hedgehog or later, JDK 17
- A physical Android device or emulator on API 28 or higher (arm64 or
  x86_64)

## Quickstart

```bash
# from the repo root:
Scripts/android-build-libs.sh        # cross-compile + stage .so per ABI

# Provide your own MuseScore file (this is gitignored and never committed)
cp /path/to/your/file.mscz ~/Desktop/test.mscz

# Optional, but required for audible playback
cp /path/to/GeneralUserGS.sf2 ~/Desktop/gm.sf2

# Copies the available local assets into the gitignored app directory
Scripts/android-bundle-test-score.sh

# Open the example in Android Studio
open -a "Android Studio" Examples/Android
```

Press Run. The app loads `test.mscz`, parses + lays out via the Swift
library through the JNI bridge, and renders page 1 onto the Compose
Canvas. Pinch / drag to zoom and pan; use Prev / Next for page
navigation.

## What this does not do

- Edit the score.
- Export to PDF.
- Use a real SMuFL music font. Phase 2's `StubFontMetricsProvider`
  generates rectangle approximations for glyphs; the Compose canvas
  renders them as small filled squares.

## Troubleshooting

- `UnsatisfiedLinkError: libSheetMusicJNI.so` — run
  `Scripts/android-build-libs.sh`. Confirm both
  `Android/SheetMusicAndroid/src/main/jniLibs/arm64-v8a/libSheetMusicJNI.so`
  and `Android/SheetMusicAndroid/src/main/jniLibs/x86_64/libSheetMusicJNI.so`
  exist.
- App starts but shows "test.mscz is not bundled." — run
  `Scripts/android-bundle-test-score.sh` after putting a MuseScore file
  at `~/Desktop/test.mscz`. Then rebuild and reinstall.
- `'semaphore.h' file not found` during Swift cross-compile — the NDK
  sysroot wasn't set up. See the project root's
  `docs/development/android.md`.
- App crashes on launch with SEGV — the Swift runtime stubs may be
  missing in `jniLibs/<abi>/`. `Scripts/android-build-libs.sh` copies
  them automatically; confirm `libswiftCore.so` is present.
- Gradle sync fails because a `jniLibs/` directory is empty — that's
  fine for sync, but `assembleDebug` will fail at link time. Run the
  build script first.

## Layout

```
Examples/Android/
├── app/
│   ├── build.gradle.kts
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── assets/test.mscz        (gitignored; supplied by you)
│       └── java/com/example/sheetmusic/
│           ├── MainActivity        # entry point
│           ├── SheetMusicApp       # state routing
│           ├── ScoreViewModel      # load / parse / layout pipeline
│           ├── ScoreState          # sealed state machine
│           ├── ScoreView           # ScoreCanvas + PageControls
│           ├── ScoreCanvas         # Compose Canvas + pan/zoom
│           ├── PageControls        # prev / next / disabled play
│           └── draw/DrawProgramDecoder    # parses the binary stream

Android/SheetMusicAndroid/src/main/
└── jniLibs/<abi>/*.so              (built by Scripts/android-build-libs.sh)
```
