#if os(macOS)
    import SheetMusic
    import SwiftUI

    /// Small command surface for exercising authored text properties in the example.
    @available(macOS 15.0, *)
    struct SelectionPropertiesPanel: View {
        enum Action {
            case placement(Placement?)
            case color(ScoreColor?)
            case font(SetTextFont.Patch)
            case verse(Int)
            case deselect
        }

        let text: ScoreTextID?
        let properties: ElementProperties?
        let isEditingText: Bool
        let onAction: (Action) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Text Properties").font(.headline)
                if let text, let properties {
                    Text(title(for: text)).font(.subheadline)
                    Menu("Placement: \(placementLabel(properties.placement))") {
                        Button("Default") { onAction(.placement(nil)) }
                        Button("Above") { onAction(.placement(.above)) }
                        Button("Below") { onAction(.placement(.below)) }
                    }
                    Menu("Color") {
                        Button("Default") { onAction(.color(nil)) }
                        Button("Red") { onAction(.color(ScoreColor(red: 200, green: 35, blue: 35))) }
                        Button("Blue") { onAction(.color(ScoreColor(red: 30, green: 90, blue: 210))) }
                        Button("Green") { onAction(.color(ScoreColor(red: 30, green: 130, blue: 70))) }
                    }
                    if case .harmony = text {
                        Menu("Font Style") {
                            Button("Default") { onAction(.font(.init(style: .clear))) }
                            Button("Regular") { onAction(.font(.init(style: .set([])))) }
                            Button("Bold") { onAction(.font(.init(style: .set(.bold)))) }
                            Button("Italic") { onAction(.font(.init(style: .set(.italic)))) }
                            Button("Bold Italic") { onAction(.font(.init(style: .set([.bold, .italic])))) }
                        }
                        Menu("Font Size") {
                            Button("Default") { onAction(.font(.init(size: .clear))) }
                            ForEach([10, 14, 20, 28], id: \.self) { size in
                                Button("\(size) pt") { onAction(.font(.init(size: .set(Double(size))))) }
                            }
                        }
                    }
                    if case let .lyric(_, verse) = text {
                        Menu("Verse: \(verse + 1)") {
                            ForEach(0 ..< 4) { destination in
                                Button("Verse \(destination + 1)") { onAction(.verse(destination)) }
                            }
                        }
                        Text("Moves this syllable only. An occupied verse is kept.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Deselect") { onAction(.deselect) }
                    Text("Deselect to see the authored color. ⌘Z undoes each change.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Click a lyric, staff / system text, chord symbol, or rehearsal mark.")
                        .foregroundStyle(.secondary)
                }
                if isEditingText {
                    Text("Finish inline text entry with Esc before changing properties.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Load editing-demo.mscx from Bundled to try placement and hidden-staff Delete.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .disabled(isEditingText)
            .padding()
            .frame(width: 230)
            .background(.background)
        }

        private func placementLabel(_ placement: Placement?) -> String {
            switch placement {
            case .above: "Above"
            case .below: "Below"
            case nil: "Default"
            }
        }

        private func title(for text: ScoreTextID) -> String {
            switch text {
            case .lyric: "Lyric"
            case let .staffText(_, style): style == .systemText ? "System Text" : "Staff Text"
            case .harmony: "Chord Symbol"
            case .rehearsalMark: "Rehearsal Mark"
            }
        }
    }

    #Preview("Text properties") {
        SelectionPropertiesPanel(
            text: .harmony(anchor: VoiceElementID(
                staff: StaffAddress(partIndex: 1, staffIndexInPart: 0),
                measureIndex: 2, voiceIndex: 0, elementIndex: 0,
            )),
            properties: ElementProperties(placement: .below),
            isEditingText: false,
            onAction: { _ in },
        )
        .frame(height: 440)
    }
#endif
