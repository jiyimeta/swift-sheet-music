// Sources/SheetMusicAudio/PlaybackState.swift
import SheetMusicFoundation

/// State machine for full-score playback. Drives any UI that
/// needs to switch between play / pause icons.
public enum PlaybackState: Sendable, Equatable {
    case stopped, playing, paused, exporting
}
