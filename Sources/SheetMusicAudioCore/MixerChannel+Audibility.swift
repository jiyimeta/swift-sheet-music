/// The live mixer's audibility rule, shared by every engine.
extension MixerChannel {
    /// Whether the channel is silent in playback: muted, or — for a channel on the solo bus — another channel is
    /// soloed and this one is not. The metronome is off the solo bus (`isSoloable`) and answers to its own mute alone,
    /// so soloing a part to practise against the click does not take the click with it.
    package func isSilenced(soloing: Bool) -> Bool {
        guard isSoloable else { return isMuted }
        return isMuted || (soloing && !isSoloed)
    }
}

extension Collection<MixerChannel> {
    /// Whether the solo bus is engaged — at least one channel that is on it is soloed.
    package var isSoloing: Bool {
        contains { $0.isSoloable && $0.isSoloed }
    }
}
