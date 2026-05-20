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
