import SheetMusicAudio
import SwiftUI

/// Mixer panel: one strip per channel, each with mute, solo, a
/// volume slider, and (for staff channels) a GM program picker.
/// Bound directly to `PlaybackEngine.mixerChannels` so changes
/// from any other UI (toolbar, scripts, …) reflect here and vice
/// versa.
struct MixerView: View {
    let engine: PlaybackEngine

    @State private var a4Hz: Double = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "A4 = %.1f Hz", a4Hz))
                    .font(.caption)
                Slider(value: $a4Hz, in: 415 ... 466)
                    .onChange(of: a4Hz) { _, hz in
                        engine.setMasterTuning(cents: 1200 * log2(hz / 440))
                    }
            }
            .padding(.bottom, 6)

            MasterLevelSection(engine: engine)
                .padding(.bottom, 6)

            ForEach(engine.mixerChannels) { channel in
                MixerStrip(channel: channel, engine: engine)
            }
        }
    }
}

/// Master gain + peak meter. The meter reads `sumMixer` (post gain,
/// pre limiter), so "Hold" is the highest level the mix actually
/// reached before any limiting — which is what tells you how much
/// headroom is left below 0 dBFS. Play the loudest passage with every
/// staff sounding, then read Hold.
private struct MasterLevelSection: View {
    let engine: PlaybackEngine

    @State private var gain: Float = 1.0
    @State private var stage: MasterOutputStage = .none
    @State private var meter = LevelMeter()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "Master gain %.2f× (%@)", gain, Self.dB(gain)))
                .font(.caption)
            Slider(value: $gain, in: 0 ... 4)
                .onChange(of: gain) { _, value in
                    engine.setMasterGain(value)
                }

            Picker("Output stage", selection: $stage) {
                Text("None").tag(MasterOutputStage.none)
                Text("Soft clip").tag(MasterOutputStage.softClip)
                Text("Peak limiter").tag(MasterOutputStage.peakLimiter)
            }
            .pickerStyle(.segmented)
            .font(.caption)
            .onChange(of: stage) { _, value in
                engine.setMasterOutputStage(value)
                meter.resetHold()
            }

            HStack(spacing: 8) {
                Text("Peak \(Self.dB(meter.peak))")
                    .font(.caption.monospacedDigit())
                Text("Hold \(Self.dB(meter.peakHold))")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(meter.peakHold > 1 ? Color.red : .primary)
                Button("Reset") { meter.resetHold() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            // Crest = how far the peak sits above the RMS. A wide crest is
            // why a mix can peak near the ceiling and still sound quiet:
            // there is no gain left to add, but little of the signal is
            // near the top.
            HStack(spacing: 8) {
                Text("RMS \(Self.dB(meter.rmsHold))")
                    .font(.caption.monospacedDigit())
                Text("Crest \(Self.crest(peak: meter.peakHold, rms: meter.rmsHold))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            engine.startLevelMonitoring { [meter] level in
                Task { @MainActor in meter.report(level) }
            }
        }
        .onDisappear {
            engine.stopLevelMonitoring()
        }
    }

    /// Linear amplitude → dBFS. `1.0` is 0 dBFS; silence reads `-∞`.
    private static func dB(_ amplitude: Float) -> String {
        guard amplitude > 0 else { return "-∞ dB" }
        return String(format: "%+.1f dB", 20 * log10(amplitude))
    }

    /// Peak-to-RMS distance in dB.
    private static func crest(peak: Float, rms: Float) -> String {
        guard peak > 0, rms > 0 else { return "— dB" }
        return String(format: "%.1f dB", 20 * log10(peak / rms))
    }
}

/// Peak / RMS with holds, updated from the engine's metering tap. Both
/// hold their maximum so a single pass over the loudest passage is
/// enough to read the numbers off.
@MainActor
@Observable
private final class LevelMeter {
    private(set) var peak: Float = 0
    private(set) var peakHold: Float = 0
    private(set) var rmsHold: Float = 0

    func report(_ level: MixLevel) {
        peak = level.peak
        peakHold = max(peakHold, level.peak)
        rmsHold = max(rmsHold, level.rms)
    }

    func resetHold() {
        peakHold = 0
        rmsHold = 0
    }
}

private struct MixerStrip: View {
    let channel: MixerChannel
    let engine: PlaybackEngine

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
private struct ProgramMenu: View {
    let channelID: MixerChannel.Kind
    let program: UInt8
    let engine: PlaybackEngine
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
