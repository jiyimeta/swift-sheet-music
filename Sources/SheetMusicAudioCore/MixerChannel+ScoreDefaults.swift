extension Collection<MixerChannel> {
    /// The mixer after a score replacement that kept every strip, when the score's own mix changed from `previous` to
    /// `next` (each a `PlaybackChannelLayout.mixerChannels`).
    ///
    /// A setting the score changed is taken from it — a part's level, sound, mute or solo that was just edited or
    /// saved into it. Every other setting stays as the listener left it, and the names always follow the score. A
    /// strip either list does not have is left as it is.
    package func takingChangedDefaults(from previous: [MixerChannel], to next: [MixerChannel]) -> [MixerChannel] {
        map { channel in
            guard let old = previous.first(where: { $0.id == channel.id }),
                  let new = next.first(where: { $0.id == channel.id })
            else { return channel }
            return MixerChannel(
                id: channel.id,
                name: new.name,
                partName: new.partName,
                instrumentName: new.instrumentName,
                volume: old.volume == new.volume ? channel.volume : new.volume,
                isMuted: old.isMuted == new.isMuted ? channel.isMuted : new.isMuted,
                isSoloed: old.isSoloed == new.isSoloed ? channel.isSoloed : new.isSoloed,
                program: old.program == new.program ? channel.program : new.program,
                isDrums: new.isDrums,
            )
        }
    }
}
