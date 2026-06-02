cmake_minimum_required(VERSION 3.22)
project(sheetmusicaudio)

# The fluidsynth module is exposed via the Prefab package named
# "fluidsynth-android" (see prefab/prefab.json in the .aar). Prefab
# generates a CMake config package under that name, and the imported
# target is fluidsynth-android::fluidsynth.
find_package(fluidsynth-android REQUIRED CONFIG)

add_library(sheetmusicaudio SHARED sheetmusicaudio_jni.cpp)
target_link_libraries(sheetmusicaudio
    fluidsynth-android::fluidsynth
    log
)
target_compile_features(sheetmusicaudio PRIVATE cxx_std_17)

# Align ELF LOAD segments to 16 KB so the library loads on Android 15+ devices
# with 16 KB memory pages. The NDK shipped with AGP (r26) still defaults the
# linker to a 4 KB max-page-size; newer NDKs (r28+) make this a no-op.
# See https://developer.android.com/16kb-page-size.
target_link_options(sheetmusicaudio PRIVATE "-Wl,-z,max-page-size=16384")
