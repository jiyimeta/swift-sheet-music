import SheetMusicFoundation
import SheetMusicMIDI

/// Ticks to seconds and back on one SMF's tempo map.
///
/// Android's player seam speaks the SMF's own (unrolled) ticks — seek to a tick, report the current tick — while
/// SwiftySynth's `MidiFileSequencer` keeps a clock in seconds. This is the translation, built from the very bytes the
/// sequencer plays, so the two integrate the same tempo changes; they still differ by rounding, which is why a seek
/// parks a fraction of a tick early (`HostedSequence.seek(toTick:)`).
///
/// The sequencer's clock runs in score seconds whatever the playback speed (`MidiFileSequencer.speed` scales how fast
/// it advances, not what a position means), so no speed enters here.
public struct SequenceTempoMap: Sendable, Equatable {
    /// One constant-tempo stretch: from `tick` (at `seconds`) on, `secondsPerTick`.
    private struct Segment: Sendable, Equatable {
        let tick: Double
        let seconds: Double
        let secondsPerTick: Double
    }

    /// The SMF default before any tempo event: 120 bpm.
    private static let defaultMicrosecondsPerQuarter = 500_000

    private let segments: [Segment]

    /// - Parameters:
    ///   - division: ticks per quarter note.
    ///   - tempoChanges: tempo events in any order; at one tick the last one listed wins, as a sequencer applying them
    ///     in file order would leave it.
    public init(division: Int, tempoChanges: [(tick: Int, microsecondsPerQuarter: Int)]) {
        let ticksPerQuarter = Double(max(1, division))
        func secondsPerTick(_ microseconds: Int) -> Double {
            Double(microseconds) / 1_000_000 / ticksPerQuarter
        }
        // Stable by tick, so of two changes at one tick the later-listed one is applied last and wins.
        let ordered = tempoChanges.enumerated().sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
        var segments = [
            Segment(tick: 0, seconds: 0, secondsPerTick: secondsPerTick(Self.defaultMicrosecondsPerQuarter)),
        ]
        for (_, change) in ordered where change.microsecondsPerQuarter > 0 {
            let tick = Double(max(0, change.tick))
            let previous = segments[segments.count - 1]
            let seconds = previous.seconds + (tick - previous.tick) * previous.secondsPerTick
            let segment = Segment(
                tick: tick, seconds: seconds, secondsPerTick: secondsPerTick(change.microsecondsPerQuarter),
            )
            if previous.tick == tick {
                segments[segments.count - 1] = segment
            } else {
                segments.append(segment)
            }
        }
        self.segments = segments
    }

    /// The map of the SMF in `smf`: its division and the tempo events of every track. Nil when the bytes do not read as
    /// an SMF or its division is SMPTE time code (the playback renderer never writes one).
    public init?(smf: Data) {
        guard let file = try? MidiReader.read(smf), file.division > 0 else { return nil }
        var changes: [(tick: Int, microsecondsPerQuarter: Int)] = []
        for track in file.tracks {
            for timed in track.events {
                if case let .meta(.tempo(microseconds)) = timed.event {
                    changes.append((timed.tick, microseconds))
                }
            }
        }
        self.init(division: file.division, tempoChanges: changes)
    }

    /// Seconds from the start of the sequence to `tick`; 0 for a tick before it. Past the last tempo event the last
    /// tempo holds.
    public func seconds(atTick tick: Double) -> Double {
        let tick = max(0, tick)
        let segment = segments.last { $0.tick <= tick } ?? segments[0]
        return segment.seconds + (tick - segment.tick) * segment.secondsPerTick
    }

    /// The tick `seconds` into the sequence, fractional; 0 for a time before it.
    public func tick(atSeconds seconds: Double) -> Double {
        let seconds = max(0, seconds)
        let segment = segments.last { $0.seconds <= seconds } ?? segments[0]
        return segment.tick + (seconds - segment.seconds) / segment.secondsPerTick
    }
}
