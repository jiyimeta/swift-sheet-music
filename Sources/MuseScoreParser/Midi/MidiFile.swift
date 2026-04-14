import Foundation

/// In-memory SMF representation. The renderer fills this; the writer turns it into bytes.
public struct MidiFile: Sendable, Equatable {
    public var division: Int
    public var format: Int
    public var tracks: [MidiTrack]

    public init(division: Int, format: Int = 1, tracks: [MidiTrack] = []) {
        self.division = division
        self.format = format
        self.tracks = tracks
    }
}
