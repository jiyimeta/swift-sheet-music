#if canImport(SheetMusicAudioSwiftySynthCore)
    import Foundation
    import SheetMusicAudioCore
    import SheetMusicMIDI
    import SwiftySynth

    /// Two channels of `frames` samples, zeroed, at addresses that stay put — what a host hands `HostedSynth.render`.
    final class StereoBuffer {
        let frames: Int
        let left: UnsafeMutablePointer<Float>
        let right: UnsafeMutablePointer<Float>

        init(frames: Int) {
            self.frames = frames
            left = .allocate(capacity: frames)
            right = .allocate(capacity: frames)
            left.initialize(repeating: 0, count: frames)
            right.initialize(repeating: 0, count: frames)
        }

        deinit {
            left.deallocate()
            right.deallocate()
        }

        var leftSamples: [Float] {
            Array(UnsafeBufferPointer(start: left, count: frames))
        }

        var rightSamples: [Float] {
            Array(UnsafeBufferPointer(start: right, count: frames))
        }

        /// The largest magnitude in either channel.
        var peak: Float {
            zip(leftSamples, rightSamples).reduce(0) { max($0, abs($1.0), abs($1.1)) }
        }
    }

    /// Fonts, sequences and measurements the SwiftySynth core suites share.
    enum HostedSynthFixtures {
        /// The click font's strong key; the weak one is 77. Both live in a bank-128 preset.
        static let strongKey = 76

        /// GeneralUser GS — the copy in the folino checkout beside this one, or the path the other SwiftySynth suites
        /// read. Suites that need real instruments are enabled only when it is there.
        static let generalUserPath: String? = [
            NSString(
                string: "~/Developer/Personal/ios-apps/folino-ios/App/Resources/Soundfonts/GeneralUser-GS.sf2",
            ).expandingTildeInPath,
            "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/App/Resources/Soundfonts/GeneralUser-GS.sf2",
        ].first { FileManager.default.fileExists(atPath: $0) }

        /// The two-key click font `ClickSoundFontBuilder` writes, with square-wave samples `seconds` long.
        static func clickFontData(seconds: Double = 0.05) -> Data {
            let count = max(1, Int(seconds * 44100))
            let wave = (0 ..< count).map { ($0 / 50) % 2 == 0 ? Int16(12000) : Int16(-12000) }
            return ClickSoundFontBuilder.build(strong: wave, strongRate: 44100, weak: wave, weakRate: 44100)
        }

        static func clickFont(seconds: Double = 0.05) throws -> SoundFont {
            try SoundFont(data: clickFontData(seconds: seconds))
        }

        /// The click font written to a temporary file, for the paths that load by URL.
        static func clickFontFile(seconds: Double = 0.05) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosted-\(UUID()).sf2")
            try clickFontData(seconds: seconds).write(to: url)
            return url
        }

        /// A one-track SMF at `division` ticks per quarter: the tempo changes and the notes given, then end of track.
        static func smf(
            division: Int = 480,
            tempos: [(tick: Int, bpm: Double)] = [],
            notes: [(tick: Int, channel: Int, key: Int, length: Int)] = [],
            controllers: [(tick: Int, channel: Int, controller: Int, value: Int)] = [],
        ) throws -> Data {
            var events: [TimedMidiEvent] = []
            for tempo in tempos {
                events.append(TimedMidiEvent(
                    tick: tempo.tick,
                    event: .meta(.tempo(microsecondsPerQuarter: Int((60_000_000 / tempo.bpm).rounded()))),
                ))
            }
            for change in controllers {
                events.append(TimedMidiEvent(
                    tick: change.tick,
                    event: .controlChange(channel: change.channel, controller: change.controller, value: change.value),
                ))
            }
            for note in notes {
                events.append(TimedMidiEvent(
                    tick: note.tick, event: .noteOn(channel: note.channel, pitch: note.key, velocity: 100),
                ))
                events.append(TimedMidiEvent(
                    tick: note.tick + note.length, event: .noteOff(channel: note.channel, pitch: note.key, velocity: 0),
                ))
            }
            events.sort { $0.tick < $1.tick }
            let end = (events.last?.tick ?? 0) + 1
            events.append(TimedMidiEvent(tick: end, event: .endOfTrack))
            return try MidiWriter.write(MidiFile(division: division, format: 1, tracks: [MidiTrack(events: events)]))
        }

        /// Renders `seconds` of `synth` and throws the audio away.
        static func render(_ synth: Synthesizer, seconds: Double) {
            var left = [Float](repeating: 0, count: Int(seconds * Double(synth.sampleRate)))
            var right = left
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in synth.render(left: l, right: r) }
            }
        }

        /// The peak of the last `lastSeconds` of `seconds` rendered.
        static func peak(of synth: Synthesizer, seconds: Double, lastSeconds: Double) -> Float {
            let total = Int(seconds * Double(synth.sampleRate))
            let tail = Int(lastSeconds * Double(synth.sampleRate))
            var left = [Float](repeating: 0, count: total)
            var right = left
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in synth.render(left: l, right: r) }
            }
            return zip(left.suffix(tail), right.suffix(tail)).reduce(0) { max($0, abs($1.0), abs($1.1)) }
        }
    }
#endif
