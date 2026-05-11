import SheetMusicAudio
import SwiftUI

/// Mixer panel: one strip per channel, each with mute, solo, a
/// volume slider, and (for staff channels) a GM program picker.
/// Bound directly to `PlaybackEngine.mixerChannels` so changes
/// from any other UI (toolbar, scripts, …) reflect here and vice
/// versa.
@available(macOS 13.0, iOS 16.0, *)
struct MixerView: View {
    @ObservedObject var engine: PlaybackEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(engine.mixerChannels) { channel in
                MixerStrip(channel: channel, engine: engine)
            }
        }
    }
}

@available(macOS 13.0, iOS 16.0, *)
private struct MixerStrip: View {
    let channel: MixerChannel
    @ObservedObject var engine: PlaybackEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(channel.name)
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize()

                Button {
                    engine.setMuted(
                        forChannel: channel.id, to: !channel.isMuted,
                    )
                } label: {
                    Text("M")
                        .font(.caption.bold())
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .background(channel.isMuted ? Color.red.opacity(0.3) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                Button {
                    engine.setSoloed(
                        forChannel: channel.id, to: !channel.isSoloed,
                    )
                } label: {
                    Text("S")
                        .font(.caption.bold())
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .background(channel.isSoloed ? Color.yellow.opacity(0.4) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                Slider(
                    value: Binding<Float>(
                        get: { channel.volume },
                        set: { newValue in
                            engine.setVolume(
                                forChannel: channel.id, to: newValue,
                            )
                        },
                    ),
                    in: 0 ... 1,
                )
            }
            if let program = channel.program {
                ProgramMenu(
                    channelID: channel.id,
                    program: program,
                    engine: engine,
                )
            }
        }
    }
}

/// GM program picker. 128 programs grouped under the 16 GM
/// families so the menu opens with collapsible sections rather
/// than a flat scroll. Selection is committed via
/// `PlaybackEngine.setProgram(...)` which both reloads the
/// sampler and updates the mixer state.
@available(macOS 13.0, iOS 16.0, *)
private struct ProgramMenu: View {
    let channelID: MixerChannel.Kind
    let program: UInt8
    @ObservedObject var engine: PlaybackEngine
    /// Borderless `Menu` on macOS bakes its own chrome colors into
    /// the label, ignoring `.foregroundStyle(.primary)` — SF
    /// Symbols come out black even in dark mode. Read the
    /// environment directly and pick a `Color` so dark mode lands
    /// on white.
    @Environment(\.colorScheme) private var colorScheme

    private var primaryColor: Color {
        colorScheme == .dark ? .white : .primary
    }

    private var secondaryColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.65)
            : .secondary
    }

    var body: some View {
        // SF Symbols *inside* a `Menu`'s label get template-tinted
        // by NSPopUpButton on macOS, ignoring any `.foregroundStyle`
        // / `.foregroundColor` we set — that's why the music note
        // and chevron stayed black in dark mode while the Mute
        // button's `Text` and the dropdown items rendered the
        // correct white. Hosting the icons as siblings of the
        // `Menu` in an outer `HStack` (so only `Text` lives inside
        // the label) routes them through the normal SwiftUI
        // foreground pipeline, which respects our color choices.
        HStack(spacing: 4) {
            Image(systemName: "music.note.list")
                .foregroundColor(primaryColor)
            Menu {
                ForEach(GMInstrument.Family.allCases, id: \.self) { family in
                    Section(family.rawValue) {
                        ForEach(family.programs) { instrument in
                            Button {
                                engine.setProgram(
                                    forChannel: channelID,
                                    to: instrument.program,
                                )
                            } label: {
                                Text(instrument.name)
                            }
                        }
                    }
                }
            } label: {
                Text(GMInstrument.instrument(for: program).name)
                    .foregroundColor(primaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundColor(secondaryColor)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        .padding(.leading, 16) // small indent so the picker reads as part of its strip
    }
}
