// Sources/SheetMusicAudio/SheetMusicAudio.swift
//
// Umbrella module for swift-sheet-music's audio sub-libraries.
//
// Apple hosts: re-exports both the Foundation-only core types and the
// AVFoundation-backed implementation (PlaybackEngine, audio file
// writers, etc.). Android hosts: only the Core types are visible;
// `PlaybackEngine` and friends are absent at the module level, which
// makes "no Android audio backend yet" a compile-time fact.
//
// Phase 4 will revisit this when an Android backend is added — at
// that point we may introduce an explicit `AudioBackend` protocol
// or keep the target boundary as the only abstraction.

@_exported import SheetMusicAudioCore

#if canImport(AVFoundation)
    @_exported import SheetMusicAudioApple
#endif
