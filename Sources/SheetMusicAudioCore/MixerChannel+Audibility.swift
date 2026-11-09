/// The live mixer's audibility rule, shared by every engine.
extension MixerChannel {
    /// Whether the channel is silent in playback: muted, or — for a channel on the solo bus — another channel is
    /// soloed and this one is not. The metronome is off the solo bus (`isSoloable`) and answers to its own mute alone,
    /// so soloing a part to practise against the click does not take the click with it.
    package func isSilenced(soloing: Bool) -> Bool {
        guard isSoloable else { return isMuted }
        return isMuted || (soloing && !isSoloed)
    }

    /// The linear gain the channel plays the score at: its slider, or nothing while `isSilenced(soloing:)`.
    package func playbackGain(soloing: Bool) -> Float {
        isSilenced(soloing: soloing) ? 0 : volume
    }

    /// The linear gain a note preview — a tapped or entered note, a held key — sounds on the channel at.
    ///
    /// With the transport stopped or paused it is the slider alone, whatever the mute and solo say: those choose what
    /// the playback is heard with, and a preview is the user asking to hear this one note, so a part muted or shut out
    /// by a solo still answers the tap. While the score plays it is `playbackGain(soloing:)`: the preview strikes the
    /// channel the music is playing on, and opening it would bring the muted part back in under the music.
    ///
    /// An engine sends this on the channels before a preview's note-on, and puts `playbackGain(soloing:)` back before
    /// its transport starts.
    package func previewGain(soloing: Bool, isPlaying: Bool) -> Float {
        isPlaying ? playbackGain(soloing: soloing) : volume
    }
}

extension Collection<MixerChannel> {
    /// Whether the solo bus is engaged — at least one channel that is on it is soloed.
    package var isSoloing: Bool {
        contains { $0.isSoloable && $0.isSoloed }
    }
}
