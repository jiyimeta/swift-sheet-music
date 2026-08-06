import Foundation

/// Identity of one rendered SMF channel.
///
/// MuseScore allocates channels per **(port, channel)** pair, not per
/// channel number: a score with mid-piece instrument changes routinely
/// spills onto `midiPort 1`, where channel 0 is a different destination
/// from port 0's channel 0. A port-blind identity makes those collide —
/// exactly the failure the driving fixture exhibits (22 channels across
/// 2 ports, port 1's channels 0-6 aliasing the part-level channels 0-4).
public struct MidiChannelKey: Sendable, Hashable {
    public let port: Int
    public let channel: Int

    public init(port: Int, channel: Int) {
        self.port = port
        self.channel = channel
    }
}
