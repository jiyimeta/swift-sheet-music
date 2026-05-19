# SheetMusic — Android Compose example

An end-to-end Kotlin Compose demo that parses an `.mscz` and renders it
to a Compose `Canvas` using the cross-compiled `SheetMusicAndroidJNI`
Swift library.

Audio is intentionally disabled; the Play button is shown but greyed
out. Wiring `SheetMusicAudioCore` into the JNI bridge is a Phase 4 follow-up.

## Prerequisites

- macOS or Linux host
- Open-source Swift 6.3.2-RELEASE toolchain installed (see the project
  root `CLAUDE.md` "Android build" section for the install command and
  `TOOLCHAINS` env var)
- Swift Android SDK 6.3.2-RELEASE_android-0.1 installed (`swift sdk list`
  should report it)
- One-time NDK sysroot symlink setup completed (see root `CLAUDE.md`)
- Android Studio Hedgehog or later, JDK 17
- A physical Android device or emulator on API 28 or higher (arm64 or
  x86_64)

## Quickstart

```bash
# from the repo root:
Scripts/android-build-libs.sh        # cross-compile + stage .so per ABI

# Provide your own MuseScore file (this is gitignored and never committed)
cp /path/to/your/file.mscz ~/Desktop/test.mscz
Scripts/android-bundle-test-score.sh # copies it into Examples/Android/app/src/main/assets/

# Open the example in Android Studio
open -a "Android Studio" Examples/Android
```

Press Run. The app loads `test.mscz`, parses + lays out via the Swift
library through the JNI bridge, and renders page 1 onto the Compose
Canvas. Pinch / drag to zoom and pan; use Prev / Next for page
navigation.

## What this does NOT do

- Play audio — the icon is disabled until Phase 3 lands.
- Edit the score.
- Export to PDF.
- Use a real SMuFL music font. Phase 2's `StubFontMetricsProvider`
  generates rectangle approximations for glyphs; the Compose canvas
  renders them as small filled squares.

## Troubleshooting

- `UnsatisfiedLinkError: libSheetMusicJNI.so` — run
  `Scripts/android-build-libs.sh`. Confirm both
  `Examples/Android/app/src/main/jniLibs/arm64-v8a/libSheetMusicJNI.so`
  and `Examples/Android/app/src/main/jniLibs/x86_64/libSheetMusicJNI.so`
  exist.
- App starts but shows "test.mscz is not bundled." — run
  `Scripts/android-bundle-test-score.sh` after putting a MuseScore file
  at `~/Desktop/test.mscz`. Then rebuild and reinstall.
- `'semaphore.h' file not found` during Swift cross-compile — the NDK
  sysroot symlink wasn't set up. See root `CLAUDE.md` "One-time NDK
  sysroot setup".
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
│       ├── jniLibs/<abi>/*.so      (built by Scripts/android-build-libs.sh)
│       └── java/com/example/sheetmusic/
│           ├── MainActivity        # entry point
│           ├── SheetMusicApp       # state routing
│           ├── ScoreViewModel      # load / parse / layout pipeline
│           ├── ScoreState          # sealed state machine
│           ├── ScoreView           # ScoreCanvas + PageControls
│           ├── ScoreCanvas         # Compose Canvas + pan/zoom
│           ├── PageControls        # prev / next / disabled play
│           ├── draw/DrawProgramDecoder    # parses the binary stream
│           └── jni/SheetMusicBridge       # external fun + System.loadLibrary
```
