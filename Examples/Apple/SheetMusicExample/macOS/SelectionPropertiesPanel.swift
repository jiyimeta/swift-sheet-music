#if os(macOS)
    import SheetMusic
    import SwiftUI

    /// Small command surface for exercising authored text, note and beam properties in the example.
    @available(macOS 15.0, *)
    struct SelectionPropertiesPanel: View {
        enum Action {
            case placement(Placement?)
            case color(ScoreColor?)
            case font(SetTextFont.Patch)
            case verse(Int)
            case offset(ScoreOffset?)
            case autoplace(Bool?)
            case noteSmall(Bool)
            case notePlay(Bool)
            case beamVisible(Bool)
            case deselect
        }

        /// The selected note's per-note flags and beam-group state.
        struct NoteSelection: Equatable {
            let isSmall: Bool
            let play: Bool
            /// `nil` when the note belongs to no beam group at all — a rest, a quarter or longer, a lone eighth.
            /// The panel must render no beam row in that case, never an unchecked one: nil is not "hidden".
            let beamVisible: Bool?
        }

        let text: ScoreTextID?
        let properties: ElementProperties?
        let note: NoteSelection?
        let isEditingText: Bool
        let onAction: (Action) -> Void

        @State private var offsetXText = ""
        @State private var offsetYText = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(headline).font(.headline)
                if let text, let properties {
                    textRows(text: text, properties: properties)
                } else if let note {
                    noteRows(note)
                } else {
                    Text("Click a note, lyric, staff / system text, chord symbol, or rehearsal mark.")
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

        private var headline: String {
            if text != nil {
                "Text Properties"
            } else if note != nil {
                "Note Properties"
            } else {
                "Selection Properties"
            }
        }

        @ViewBuilder
        private func textRows(text: ScoreTextID, properties: ElementProperties) -> some View {
            Text(title(for: text)).font(.subheadline)
            Menu("Placement: \(placementLabel(properties.placement))") {
                Button("Default") { onAction(.placement(nil)) }
                Button("Above") { onAction(.placement(.above)) }
                Button("Below") { onAction(.placement(.below)) }
            }
            offsetRow(offset: properties.offset)
            Menu("Auto-place: \(autoplaceLabel(properties.autoplace))") {
                Button("Default (On)") { onAction(.autoplace(nil)) }
                Button("On") { onAction(.autoplace(true)) }
                Button("Off") { onAction(.autoplace(false)) }
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
        }

        @ViewBuilder
        private func noteRows(_ note: NoteSelection) -> some View {
            Toggle(isOn: Binding(
                get: { note.isSmall },
                set: { onAction(.noteSmall($0)) },
            )) { Text("Small") }
            Toggle(isOn: Binding(
                get: { note.play },
                set: { onAction(.notePlay($0)) },
            )) { Text("Play") }
            if let beamVisible = note.beamVisible {
                Toggle(isOn: Binding(
                    get: { beamVisible },
                    set: { onAction(.beamVisible($0)) },
                )) { Text("Beam Visible") }
            }
            Button("Deselect") { onAction(.deselect) }
            Text("⌘Z undoes each change.")
                .font(.caption).foregroundStyle(.secondary)
        }

        private func offsetRow(offset: ScoreOffset?) -> some View {
            HStack(spacing: 6) {
                Text("Offset")
                TextField("X", text: $offsetXText)
                    .frame(width: 44)
                    .onSubmit { commitOffset() }
                TextField("Y", text: $offsetYText)
                    .frame(width: 44)
                    .onSubmit { commitOffset() }
                Button("Set") { commitOffset() }
                Button("Default") {
                    offsetXText = ""
                    offsetYText = ""
                    onAction(.offset(nil))
                }
            }
            .textFieldStyle(.roundedBorder)
            .onAppear { syncOffsetText(offset) }
            .onChange(of: offset) { _, newValue in syncOffsetText(newValue) }
        }

        private func syncOffsetText(_ offset: ScoreOffset?) {
            offsetXText = offset.map { Self.formattedOffsetComponent($0.x) } ?? ""
            offsetYText = offset.map { Self.formattedOffsetComponent($0.y) } ?? ""
        }

        private func commitOffset() {
            let x = Double(offsetXText) ?? 0
            let y = Double(offsetYText) ?? 0
            onAction(.offset(ScoreOffset(x: x, y: y)))
        }

        private static func formattedOffsetComponent(_ value: Double) -> String {
            value.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(value)) : String(format: "%.2f", value)
        }

        private func placementLabel(_ placement: Placement?) -> String {
            switch placement {
            case .above: "Above"
            case .below: "Below"
            case nil: "Default"
            }
        }

        private func autoplaceLabel(_ autoplace: Bool?) -> String {
            switch autoplace {
            case true: "On"
            case false: "Off"
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
            note: nil,
            isEditingText: false,
            onAction: { _ in },
        )
        .frame(height: 440)
    }

    #Preview("Note properties") {
        SelectionPropertiesPanel(
            text: nil,
            properties: nil,
            note: SelectionPropertiesPanel.NoteSelection(isSmall: false, play: true, beamVisible: true),
            isEditingText: false,
            onAction: { _ in },
        )
        .frame(height: 440)
    }
#endif
