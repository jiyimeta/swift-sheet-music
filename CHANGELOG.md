# Changelog

All notable changes to this project are documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Preparing the first public release. The library already provides:

### Added

- MuseScore `.mscx` / `.mscz` import and export, targeting MuseScore 4
  (default) or MuseScore-3.6.2-flavoured output
  (`MSCXEncoderOptions(targetVersion: .v3)`).
- MusicXML `.musicxml` / `.mxl` import.
- A typed, `Sendable` value-type score model (`SheetMusicCore`) with
  parse diagnostics (`parseWithDiagnostics`).
- Score → Standard MIDI File rendering, verified against MuseScore's own
  `midiexport_tests.cpp` fixtures via semantic-equivalence comparison.
- A pure-geometry layout engine (`SheetMusicLayout`) with a
  `FontMetricsProvider` dependency-injection seam.
- SwiftUI notation viewer (`SheetMusicUI`) with a moving playback cursor,
  and PDF export (`SheetMusicPDF`).
- AVFoundation-backed playback and audio-file export (`SheetMusicAudio`),
  including a configurable count-in / pre-roll click.
- Experimental PDF-score import.
- Android: the Foundation-only subset cross-compiled via the Swift Android
  SDK, plus Kotlin AAR modules for JNI bridging and FluidSynth + Oboe
  playback.

[Unreleased]: https://github.com/jiyimeta/swift-sheet-music/commits/main
