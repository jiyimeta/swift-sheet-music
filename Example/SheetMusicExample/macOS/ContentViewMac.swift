#if os(macOS)
import AppKit
import SheetMusic
import SheetMusicAudio
import SheetMusicPDF
import SheetMusicUI
import SwiftUI
import UniformTypeIdentifiers

enum MacLayoutMode: String {
    case horizontal = "Horizontal"
    case vertical = "Vertical"
    case paged = "Page"
    /// Mirrors the PDF export's pagination — same page size, margin,
    /// and packing logic as `PDFExporter` — but laid out side-by-side
    /// in a horizontal scroll view so you can review what the PDF
    /// will look like before saving.
    case pdf = "PDF"
}

@available(macOS 15.0, *)
struct ContentViewMac: View {
    @State private var score: Score?
    @State private var sourceName = "(none)"
    @State private var errorMessage: String?
    @State private var magnification: CGFloat = 1.0
    @State private var layoutMode: MacLayoutMode = .horizontal
    @State private var pageIndex = 0
    @State private var totalPages = 1
    @State private var selection: ScoreSelection = .none
    /// Pre-computed layout for the current vertical viewport width.
    /// Rebuilt on width / score / mode changes; passed into both
    /// ScoreView (for rendering) and ScoreHitTester (for tap
    /// mapping), so layout runs at most once per change instead of
    /// twice per click.
    @State private var verticalDoc: LayoutDocument?
    /// Pre-computed layout for horizontal mode (one long system at
    /// natural content width). Rebuilt on mode / score changes.
    @State private var horizontalDoc: LayoutDocument?
    /// Reused across `adoptEditedScore` calls so `LayoutEngine.layout`
    /// can skip per-measure work for measures unchanged by the edit.
    /// Reset on every `adoptLoadedScore` (a fresh score has no cache
    /// continuity with the previous one).
    @State private var layoutCache = LayoutCache()
    /// When non-nil, the lyric editor TextField is shown anchored to
    /// the chord at this location. Set by ⌘L on a selected note,
    /// cleared on submit / cancel.
    @State private var lyricEditTarget: VoiceElementID?
    @State private var lyricEditText: String = ""
    @FocusState private var lyricEditFocused: Bool
    /// Per-measure clef / key / time / part-label state. Cached so
    /// the sticky header doesn't recompute it on every body re-eval
    /// (an O(measures × staves) walk that adds up during pinch /
    /// scroll). Refilled when a new score loads.
    @State private var horizontalContexts: [LayoutMeasureContext] = []
    /// Live document-space X of the visible left edge in horizontal
    /// mode. Drives the sticky header overlay.
    @State private var horizontalScrollX: CGFloat = 0
    /// Live document-space Y of the visible top edge. When the user
    /// has zoomed in past the viewport height, the score scrolls
    /// vertically; the sticky pane offsets by this value so its
    /// clef stays attached to the staff.
    @State private var horizontalScrollY: CGFloat = 0
    /// Bumped whenever a new score is loaded so that `.task(id:)`
    /// observers know to rebuild their layouts even if width and
    /// mode did not change.
    @State private var scoreVersion = UUID()
    /// Audio engine for single-note preview + full-score playback.
    /// Held as `@StateObject` so SwiftUI re-evaluates the play / pause
    /// button label and the playback cursor whenever the engine's
    /// `@Published` `state` / `currentCursor` change.
    @StateObject private var playbackEngine = PlaybackEngine(
        soundfontResolver: BundledSoundfontResolver())
    /// Edit-mode controller. Lives across score reloads —
    /// `reset(score:)` is called from `adoptLoadedScore`.
    @State private var inputController: NoteInputController?
    /// Live size of the horizontal score viewport. Populated by
    /// `HorizontalScoreContainer.onViewportSizeChange` on first
    /// layout / resize. Used by the edit-time scroll helper to
    /// decide whether the affected measure is already in view.
    /// `.zero` until the container reports a real value.
    @State private var horizontalViewportSize: CGSize = .zero
    @Environment(\.undoManager) private var undoManager
    /// Local NSEvent monitor that turns the spacebar into a play /
    /// pause toggle (MuseScore convention). Stored so we can remove
    /// it on disappear.
    @State private var keyMonitor: Any?
    /// Live magnification factor for PDF preview mode (driven by
    /// pinch-to-zoom). Persists across score / mode changes so the
    /// user doesn't lose their zoom level when switching tabs.
    /// Current magnification of the PDF preview, driven by
    /// `NSScrollView.magnification` via `MagnifyingPDFScrollView`.
    /// Persists across mode / score swaps so the user's zoom level
    /// survives.
    @State private var pdfScale: CGFloat = 1.0
    /// Cached PDF-mode layout. Recomputed via `.task(id:)` only on
    /// score change, NOT on every pinch frame — `LayoutEngine.layout`
    /// is expensive on large scores and re-running it per frame
    /// makes the pinch crawl.
    @State private var pdfLayout: PDFPreviewLayout?

    /// Pending programmatic scroll target for the horizontal
    /// `MagnifyingScoreScrollView`, in document coords. The wrapper
    /// animates to it and resets the binding to nil. Set by the
    /// auto-scroll path during playback.
    @State private var pendingHorizontalScroll: CGPoint?
    /// When ON, drags inside vertical / horizontal score viewports
    /// resolve to a marquee selection instead of falling through to
    /// scroll or click. Toggled from the sidebar.
    @State private var isMarqueeMode = false

    // systemGap targets MuseScore's `Sid::minSystemDistance` of
    // 8.5 sp; with our staff-distance pads contributing ~3.5 sp
    // below the last lyric staff, ~5 sp here (≈ 1.25 × staffSize)
    // lands the visible system-to-system gap in MuseScore range.
    private static let verticalOptions = ScoreViewOptions(
        staffSize: 18, systemGap: 22, wrapToViewWidth: true)
    private static let horizontalOptions = ScoreViewOptions(
        staffSize: 28, systemGap: 40, wrapToViewWidth: false,
        includeTitleFrame: false)

    var body: some View {
        NavigationSplitView {
            ContentSidebar(
                playbackEngine: playbackEngine,
                sourceName: sourceName,
                score: score,
                errorMessage: errorMessage,
                layoutMode: $layoutMode,
                pageIndex: $pageIndex,
                totalPages: totalPages,
                magnification: $magnification,
                isMarqueeMode: $isMarqueeMode,
                onLoadBundled: loadBundled,
                onOpenFile: showOpenPanel,
                onTogglePlayback: togglePlayback,
                onExportPDF: exportPDF)
        } detail: {
            if let score {
                scoreContent(score: score)
            } else {
                ContentUnavailableView(
                    "No score loaded",
                    systemImage: "music.note.list",
                    description: Text(
                        "Load the bundled test.mscx from the sidebar."))
            }
        }
        .onAppear(perform: loadBundled)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    inputController?.isInputModeOn.toggle()
                } label: {
                    let on = inputController?.isInputModeOn ?? false
                    Label(
                        on ? "Input Mode (on)" : "Input Mode",
                        systemImage: on ? "pencil.tip.crop.circle.fill" : "pencil.tip")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(on ? Color.accentColor : .primary)
                }
                .disabled(inputController == nil)
                .help("Toggle note input mode. Then click a rest and type C/D/E/F/G/A/B; ↑/↓ shifts octave; ⌘Z undoes.")
            }
        }
    }

    private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ScoreFileType.allUTTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Score"
        guard panel.runModal() == .OK,
              let url = panel.url else { return }
        openUserURL(url)
    }

    private func exportPDF() {
        guard let score else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (sourceName as NSString)
            .deletingPathExtension + ".pdf"
        panel.canCreateDirectories = true
        panel.title = "Save Score as PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PDFExporter.export(
                score: score,
                to: url,
                options: PDFExporter.Options(
                    title: (sourceName as NSString).deletingPathExtension))
            // Reveal the resulting file so the user can inspect it
            // without hunting through Finder.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = "PDF export failed: \(error.localizedDescription)"
        }
    }

    private func togglePlayback() {
        guard let score else { return }
        playbackEngine.togglePlayback(
            score: score, selection: selection)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // keyCode 49 is spacebar on every keyboard layout (it's a
        // physical-key code). Skip auto-repeat so a held space
        // doesn't toggle dozens of times per second.
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            // Space (keyCode 49). Inside the lyric editor it
            // advances to the next chord's syllable; otherwise it
            // toggles playback. The editor takes priority so the
            // user can type lyrics rapidly without leaving keyboard
            // focus.
            if event.keyCode == 49,
               !event.isARepeat,
               event.modifierFlags
                .intersection([.command, .control, .option])
                .isEmpty {
                if lyricEditTarget != nil {
                    advanceLyricToNextChord()
                    return nil
                }
                togglePlayback()
                return nil
            }
            // ⌘Z / ⌘⇧Z routed to our editor directly. SwiftUI's
            // `@Environment(\.undoManager)` requires the focused
            // responder to also expose one; our score viewport is
            // not a text-input responder, so the Edit menu's Undo
            // never reaches us. Catching the chord here works
            // regardless of focus state. The `UndoManager`
            // registration in `NoteInputController` is kept for
            // future Edit-menu integration.
            if event.modifierFlags.contains(.command),
               !event.isARepeat,
               let chars = event.charactersIgnoringModifiers,
               chars.first?.lowercased() == "z" {
                if let controller = inputController {
                    handleEditorUndoRedo(
                        controller: controller,
                        redo: event.modifierFlags.contains(.shift))
                    return nil
                }
            }
            // ⌘L on a selected note opens the lyric editor.
            // Independent of input mode — editing existing lyrics is
            // a normal browse-mode action too. Caught here (alongside
            // ⌘Z) for the same reason: the score viewport isn't a
            // text-input responder.
            if event.modifierFlags.contains(.command),
               !event.isARepeat,
               let chars = event.charactersIgnoringModifiers,
               chars.first?.lowercased() == "l" {
                if openLyricEditorForSelection() {
                    return nil
                }
            }
            if let controller = inputController, controller.isInputModeOn {
                if handleInputModeKey(event, controller: controller) {
                    return nil
                }
            }
            return event
        }
    }

    private func handleEditorUndoRedo(
        controller: NoteInputController,
        redo: Bool
    ) {
        do {
            if redo {
                try controller.redo()
            } else {
                try controller.undo()
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // Defer @State mutations to the next runloop tick.
        // Repeatedly mutating @State from inside an `NSEvent`
        // monitor closure (e.g. holding ⌘Z) doesn't reliably
        // invalidate the SwiftUI view: the second-and-onward
        // writes to the same property within one event-handling
        // pass can be no-ops (Equatable check), and `scoreVersion`
        // alone hasn't been enough to nudge body re-eval.
        // `DispatchQueue.main.async` puts the mutations on the
        // next runloop iteration, fully outside the NSEvent
        // dispatch path, where SwiftUI's normal update cycle
        // applies. The same fix shape can later be applied to
        // the apply path if the rapid-typing case shows similar
        // staleness.
        let edited = controller.score
        let isRedo = redo
        let affectedMeasure = controller.editor.lastAffectedLocation?.measureIndex
        DispatchQueue.main.async {
            errorMessage = isRedo ? "Redo" : "Undo"
            selection = .none
            adoptEditedScore(edited)
            if let mi = affectedMeasure {
                scrollToAffectedMeasure(measureIndex: mi)
            }
        }
    }

    /// Scroll the horizontal viewport so `measureIndex`'s leading
    /// edge sits at the visible left edge. No-ops in non-horizontal
    /// modes (vertical / paged / pdf each have their own pathway,
    /// and editing them isn't supported in this slice yet).
    private func scrollToAffectedMeasure(measureIndex: Int) {
        guard layoutMode == .horizontal,
              let doc = horizontalDoc,
              horizontalViewportSize.width > 0
        else { return }
        scrollToMeasureMac(
            measureIndex: measureIndex,
            doc: doc,
            viewportWidth: horizontalViewportSize.width,
            magnification: magnification,
            horizontalScrollX: horizontalScrollX,
            horizontalScrollY: horizontalScrollY,
            pendingScroll: $pendingHorizontalScroll)
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    /// Routes a keydown while input mode is on. Returns `true` when
    /// the event has been consumed (caller returns `nil` to AppKit
    /// so no beep plays); `false` when it should propagate (e.g. a
    /// letter unrelated to note input, leaving other shortcuts
    /// reachable).
    private func handleInputModeKey(
        _ event: NSEvent,
        controller: NoteInputController
    ) -> Bool {
        // We only filter out the "real" modifier keys (cmd / ctrl /
        // option / shift). Arrow keys themselves carry `.function`
        // and `.numericPad` flags on macOS — testing against the
        // full `deviceIndependentFlagsMask` for `.isEmpty` rejects
        // every plain arrow press.
        let blockingMods: NSEvent.ModifierFlags =
            [.command, .control, .option, .shift]

        // Backspace (keyCode 51) / forward Delete (keyCode 117):
        // replace the selected chord/rest with a rest of the same
        // duration. Drum notes included — DeleteVoiceElement just
        // calls into ReplaceVoiceElement at the library level.
        if event.modifierFlags
            .intersection(blockingMods).isEmpty,
           event.keyCode == 51 || event.keyCode == 117 {
            deleteSelectedElement(controller: controller)
            return true
        }
        // Up / down arrow: shift the selected note by ±1 semitone
        // when a note is selected; otherwise shift the input
        // octave (used for the next letter typed onto a rest).
        // Always consume so AppKit doesn't beep on unhandled events.
        if event.modifierFlags
            .intersection(blockingMods).isEmpty,
           event.keyCode == 126 || event.keyCode == 125 {
            let delta = event.keyCode == 126 ? 1 : -1
            if case .single(.note(let noteID)) = selection {
                shiftSelectedNote(
                    noteID: noteID, by: delta, controller: controller)
            } else if !event.isARepeat {
                // Octave shift only fires on the initial press —
                // holding the key shouldn't crank the octave through
                // the whole keyboard.
                controller.inputOctave = max(
                    0, min(8, controller.inputOctave + delta))
                errorMessage = "Input octave: \(controller.inputOctave)"
            }
            return true
        }
        // `+` (shift+; on JIS, shift+= on US) toggles a tie from the
        // selected note to the next same-pitch chord in its voice.
        // Checked BEFORE the letter-key insertion path so `+` never
        // lands in a note-input lookup that doesn't know about it.
        if event.characters == "+",
           event.modifierFlags
            .intersection([.command, .control, .option]).isEmpty,
           case .single(.note(let noteID)) = selection {
            toggleTieForward(
                noteID: noteID, controller: controller)
            return true
        }
        // Number keys 1–7 with a note OR rest selected → change
        // that element's duration. Mapping mirrors MuseScore:
        //   1=64th, 2=32nd, 3=16th, 4=8th, 5=quarter, 6=half, 7=whole.
        // Notes route through SetChordDuration; rests through
        // SetRestDuration (both share the same shorten / lengthen
        // / chord-overshoot algorithm).
        if event.modifierFlags
            .intersection([.command, .control, .option]).isEmpty,
           let duration = NoteInputKeyMap.duration(
            forCharacter: event.characters ?? "") {
            switch selection {
            case .single(.note(let noteID)):
                setSelectedChordDuration(
                    noteID: noteID, duration: duration,
                    controller: controller)
                return true
            case .single(.rest(let restID)):
                setSelectedRestDuration(
                    restID: restID, duration: duration,
                    controller: controller)
                return true
            default:
                break
            }
        }
        guard let chars = event.charactersIgnoringModifiers,
              let letter = chars.first
        else {
            return false
        }
        guard let mapped = NoteInputKeyMap.pitch(
            forLetter: letter,
            octave: controller.inputOctave)
        else {
            // Letter unrelated to note entry — let other shortcuts /
            // text inputs through. (No beep risk because the system
            // will deliver it to whatever responder is appropriate.)
            return false
        }
        // Shift+letter on a selected note → add the letter's pitch
        // to that note's chord. Mirrors MuseScore's chord-input
        // shortcut. The accidental glyph is computed against the
        // active key sig so the new note's spelling matches what
        // the staff already shows for that letter.
        if event.modifierFlags.contains(.shift),
           case .single(.note(let noteID)) = selection {
            addNoteToChord(
                noteID: noteID, mapped: mapped,
                controller: controller)
            return true
        }
        guard case let .single(.rest(restID)) = selection else {
            // Letter is mapped but there's no rest to drop it onto.
            // Consume it so the user doesn't get a beep, and give
            // visible feedback.
            errorMessage = "Click a rest to insert a note. Current selection: \(describeSelection(selection))."
            return true
        }
        do {
            try controller.apply(
                InputNote(
                    at: restID,
                    pitch: mapped.pitch,
                    tpc: mapped.tpc),
                undoManager: undoManager)
            // After successful insertion the rest is gone — select
            // the freshly-inserted note so the user sees what they
            // just typed.
            let noteID = NoteID(
                staffIndex: restID.staffIndex,
                measureIndex: restID.measureIndex,
                voiceIndex: restID.voiceIndex,
                elementIndex: restID.elementIndex,
                noteIndexInChord: 0)
            selection = .single(.note(noteID))
            adoptEditedScore(controller.score)
            // Match the click-on-note feedback path: brief preview
            // of the just-inserted pitch via the playback engine.
            playbackEngine.playPreview(
                noteID: noteID, in: controller.score)
            // Pull the affected measure into view if it isn't
            // already (handles fast typing past the visible window
            // and edits on offscreen rests).
            scrollToAffectedMeasure(
                measureIndex: restID.measureIndex)
            errorMessage = "Inserted \(String(letter).uppercased())\(controller.inputOctave) (MIDI \(mapped.pitch)). Click another rest to keep typing."
        } catch {
            errorMessage = error.localizedDescription
        }
        return true
    }

    /// Build the in-document overlay shown when the lyric editor is
    /// open. Returns nil when no chord is being edited; otherwise a
    /// small TextField positioned (in document coords) at the chord's
    /// stem X / lyric-line Y, so it scrolls + magnifies along with
    /// the staff. Mirrors MuseScore's inline lyric input.
    private func inlineLyricEditorOverlay(
        document: LayoutDocument
    ) -> AnyView? {
        guard let target = lyricEditTarget,
              let stemOrigin = document.chordStemOrigin(at: target),
              let lyricY = document.lyricLineY(at: target)
        else { return nil }
        // Match the rendered lyric: same system-font size as
        // `ScoreCanvas`'s `drawLyricText` (sp × 2.2), centered both
        // horizontally and vertically on the chord stem X / lyric
        // line Y so the field sits exactly where the rendered
        // syllable would.
        let sp = document.metrics.sp
        let lyricFontSize = sp * 2.2
        let fieldWidth: CGFloat = sp * 12
        return AnyView(
            TextField("", text: $lyricEditText)
                .textFieldStyle(.plain)
                .font(.system(size: lyricFontSize, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .frame(width: fieldWidth)
                .padding(.horizontal, 2)
                .background(Color.white)
                // Force light-mode resolution so the text colour
                // (`.primary`) lands on black against the forced
                // white background regardless of system theme —
                // matches the lyric glyph colour the renderer
                // uses on a light score canvas.
                .colorScheme(.light)
                .focused($lyricEditFocused)
                .onSubmit { submitLyricEdit() }
                .onExitCommand { closeLyricEditor() }
                .position(x: stemOrigin.x, y: lyricY))
    }

    /// Populate the lyric-editor state from the currently-selected
    /// note (if any) and surface the TextField overlay. Returns
    /// `true` when the lyric editor was opened so the caller can
    /// suppress the originating event.
    @discardableResult
    private func openLyricEditorForSelection() -> Bool {
        let chordID: VoiceElementID
        switch selection {
        case .single(.note(let noteID)):
            chordID = VoiceElementID(noteID)
        default:
            return false
        }
        guard let controller = inputController,
              case .chord(let chord) = controller.score[chordID] else {
            return false
        }
        lyricEditText = chord.lyrics.first?.text ?? ""
        lyricEditTarget = chordID
        lyricEditFocused = true
        return true
    }

    /// Commit the editor's current text to the target chord via
    /// `SetLyrics`. Empty text clears the lyric. Returns `true` on
    /// successful apply (caller can then advance / close).
    @discardableResult
    private func applyLyricEdit() -> Bool {
        guard let target = lyricEditTarget,
              let controller = inputController else { return false }
        let newLyrics: [Lyric] = lyricEditText.isEmpty
            ? []
            : [Lyric(text: lyricEditText)]
        do {
            try controller.apply(
                SetLyrics(at: target, lyrics: newLyrics),
                undoManager: undoManager)
            adoptEditedScore(controller.score)
            errorMessage = lyricEditText.isEmpty
                ? "Lyric cleared"
                : "Lyric set"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Apply current text and close the editor (Enter / OK).
    private func submitLyricEdit() {
        applyLyricEdit()
        closeLyricEditor()
    }

    /// Apply current text, then move the editor to the next chord
    /// in the same voice (Space key flow). Closes the editor when
    /// no further chord exists in the staff.
    private func advanceLyricToNextChord() {
        guard let current = lyricEditTarget,
              let controller = inputController else {
            closeLyricEditor()
            return
        }
        applyLyricEdit()
        guard let next = controller.score.nextChord(after: current),
              case .chord(let chord) = controller.score[next] else {
            closeLyricEditor()
            return
        }
        // Pre-fill with any existing first-verse lyric and re-focus.
        lyricEditText = chord.lyrics.first?.text ?? ""
        lyricEditTarget = next
        lyricEditFocused = true
        // Selection follows the editor so other shortcuts (⌘L,
        // arrow-shift, Delete) target the same chord.
        if let firstNote = chord.notes.first {
            selection = .single(.note(NoteID(
                staffIndex: next.staffIndex,
                measureIndex: next.measureIndex,
                voiceIndex: next.voiceIndex,
                elementIndex: next.elementIndex,
                noteIndexInChord: 0)))
            _ = firstNote
        }
        scrollToAffectedMeasure(measureIndex: next.measureIndex)
    }

    private func closeLyricEditor() {
        lyricEditTarget = nil
        lyricEditText = ""
        lyricEditFocused = false
    }

    /// Add a new note (Shift+letter mapping → pitch in input
    /// octave) to the chord that contains the currently-selected
    /// note. The accidental is auto-computed against the active key
    /// signature; the chord's other metadata (duration, lyrics,
    /// arpeggio) is preserved by `AddNoteToChord`.
    private func addNoteToChord(
        noteID: NoteID,
        mapped: (pitch: Int, tpc: Int),
        controller: NoteInputController
    ) {
        let chordID = VoiceElementID(noteID)
        let activeKey = controller.score.activeKey(at: noteID)
        let accidental: Accidental? = isDrumStaff(noteID: noteID,
                                                  controller: controller)
            ? nil
            : PitchSpelling.displayedAccidental(
                forTpc: mapped.tpc, in: activeKey)
        // Capture the chord's prior note count so we can address
        // the freshly-appended note after the apply.
        let priorNoteCount: Int
        if case .chord(let c) = controller.score[chordID] {
            priorNoteCount = c.notes.count
        } else {
            priorNoteCount = 0
        }
        do {
            try controller.apply(
                AddNoteToChord(
                    at: chordID,
                    pitch: mapped.pitch,
                    tpc: mapped.tpc,
                    accidental: accidental),
                undoManager: undoManager)
            adoptEditedScore(controller.score)
            // Move selection to the freshly-added note (it sits at
            // the end of `chord.notes` per AddNoteToChord) and
            // preview that pitch — matches the rest-input flow's
            // "select what you just typed + play it" feedback.
            let newNoteID = NoteID(
                staffIndex: noteID.staffIndex,
                measureIndex: noteID.measureIndex,
                voiceIndex: noteID.voiceIndex,
                elementIndex: noteID.elementIndex,
                noteIndexInChord: priorNoteCount)
            selection = .single(.note(newNoteID))
            playbackEngine.playPreview(
                noteID: newNoteID, in: controller.score)
            errorMessage = "Added \(mapped.pitch) to chord"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isDrumStaff(
        noteID: NoteID,
        controller: NoteInputController
    ) -> Bool {
        let staffIdx = noteID.staffIndex
        return staffIdx < controller.score.parts.count
            && controller.score.parts[staffIdx]
                .instrument.useDrumset
    }

    /// Set the duration of the chord that contains the currently-
    /// selected note via `SetChordDuration`. Maps MuseScore-style
    /// shortenings to leftover rests and lengthenings to consumed
    /// following elements. Surfaces `invalidEdit` reasons (tuplet,
    /// measure boundary, non-timed element in path) as user-visible
    /// `errorMessage` text.
    private func setSelectedChordDuration(
        noteID: NoteID,
        duration: NoteDuration,
        controller: NoteInputController
    ) {
        let chordID = VoiceElementID(noteID)
        do {
            try controller.apply(
                SetChordDuration(at: chordID, duration: duration),
                undoManager: undoManager)
            adoptEditedScore(controller.score)
            errorMessage = "Duration changed"
            scrollToAffectedMeasure(measureIndex: noteID.measureIndex)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Same as `setSelectedChordDuration` but for the
    /// `SetRestDuration` command.
    private func setSelectedRestDuration(
        restID: RestID,
        duration: NoteDuration,
        controller: NoteInputController
    ) {
        let veID = VoiceElementID(restID)
        do {
            try controller.apply(
                SetRestDuration(at: veID, duration: duration),
                undoManager: undoManager)
            adoptEditedScore(controller.score)
            errorMessage = "Duration changed"
            scrollToAffectedMeasure(measureIndex: restID.measureIndex)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Toggle a tie from the currently-selected note to the next
    /// chord in the same voice that contains a note of the same
    /// pitch. Adds the tie when none is present, removes it when
    /// one is.
    private func toggleTieForward(
        noteID: NoteID,
        controller: NoteInputController
    ) {
        guard let source = controller.score[noteID] else {
            errorMessage = "Selected note not found in score"
            return
        }
        guard let target = controller.score
            .nextTieTarget(after: noteID) else {
            errorMessage = "No tie target — the next chord in this "
                + "voice must contain a note of the same pitch."
            return
        }
        let alreadyTied = source.tieForward != nil
        let cmd = SetTie(
            from: noteID, to: target,
            sourceTieForward: alreadyTied ? nil : 1,
            targetTieBack: alreadyTied ? nil : 1)
        do {
            try controller.apply(cmd, undoManager: undoManager)
            adoptEditedScore(controller.score)
            errorMessage = alreadyTied ? "Tie removed" : "Tied"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Replace the currently-selected chord/rest with a rest of the
    /// same duration via `DeleteVoiceElement`. Selection moves to
    /// the resulting rest so subsequent edits (transpose, retype)
    /// target the new element. No-op when nothing actionable is
    /// selected.
    private func deleteSelectedElement(
        controller: NoteInputController
    ) {
        let target: VoiceElementID
        switch selection {
        case .single(.note(let noteID)):
            target = VoiceElementID(noteID)
        case .single(.rest(let restID)):
            target = VoiceElementID(restID)
        default:
            errorMessage = "Select a note or rest to delete."
            return
        }
        do {
            try controller.apply(
                DeleteVoiceElement(at: target),
                undoManager: undoManager)
            adoptEditedScore(controller.score)
            // Select the freshly-created rest so the user can keep
            // editing at the same beat.
            let newRest = RestID(
                staffIndex: target.staffIndex,
                measureIndex: target.measureIndex,
                voiceIndex: target.voiceIndex,
                elementIndex: target.elementIndex)
            selection = .single(.rest(newRest))
            errorMessage = "Deleted"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Apply a ±semitone shift to the currently-selected note.
    /// Routed through `SetNotePitch` so undo / redo work the same
    /// way as letter-key insertion. The new TPC is computed by
    /// `PitchSpelling.shiftedTpc` using the active key signature
    /// at the note's location, matching MuseScore's
    /// `EditNote::upDownChromatic` behaviour.
    private func shiftSelectedNote(
        noteID: NoteID,
        by semitones: Int,
        controller: NoteInputController
    ) {
        guard let original = controller.score[noteID] else {
            errorMessage = "Selected note not found in score"
            return
        }
        // Drum staves: shift by pitch but ignore the staff's key
        // signature for spelling, and never paint an accidental glyph.
        // Drum noteheads are positioned by the part's drum-line map,
        // not by chromatic spelling, and accidentals on a drum staff
        // are nonsensical even when the staff happens to carry a
        // KeySig element from the source file.
        let isDrumStaff = noteID.staffIndex
            < controller.score.parts.count
            && controller.score.parts[noteID.staffIndex]
                .instrument.useDrumset
        let keySigForSpelling = isDrumStaff
            ? 0
            : controller.score.activeKey(at: noteID)
        guard let shifted = original.shifted(
            bySemitones: semitones, in: keySigForSpelling)
        else {
            errorMessage = "Pitch out of MIDI range (0…127)"
            return
        }
        let accidentalToWrite = isDrumStaff ? nil : shifted.accidental
        do {
            try controller.apply(
                SetNotePitch(
                    at: noteID,
                    pitch: shifted.pitch,
                    tpc: shifted.tpc,
                    accidental: accidentalToWrite),
                undoManager: undoManager)
            adoptEditedScore(controller.score)
            playbackEngine.playPreview(
                noteID: noteID, in: controller.score)
            scrollToAffectedMeasure(measureIndex: noteID.measureIndex)
            errorMessage = "Shifted to MIDI \(shifted.pitch)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func describeSelection(_ s: ScoreSelection) -> String {
        switch s {
        case .none: return "none"
        case .single(.rest): return "rest"
        case .single(.note): return "note"
        case .range: return "range"
        case .multi: return "multi"
        }
    }

    @ViewBuilder
    private func scoreContent(score: Score) -> some View {
        switch layoutMode {
        case .vertical:
            VerticalScoreContainer(
                score: score,
                verticalDoc: $verticalDoc,
                options: Self.verticalOptions,
                scoreVersion: scoreVersion,
                selection: selection,
                voiceColors: exampleVoiceColors,
                playbackCursor: playbackEngine.currentCursor,
                isPlaying: playbackEngine.state == .playing,
                isMarqueeMode: isMarqueeMode,
                onTap: { loc, doc in
                    handleTap(at: loc, document: doc)
                },
                onMarqueeEnd: { rect, doc in
                    applyMarquee(rect: rect, document: doc)
                })
        case .horizontal:
            // Native NSScrollView handles pinch-zoom-around-cursor
            // reliably; a SwiftUI-only implementation fought
            // ScrollPosition's asynchronous updates.
            if let doc = horizontalDoc {
                HorizontalScoreContainer(
                    score: score,
                    document: doc,
                    measureContexts: horizontalContexts,
                    magnification: $magnification,
                    horizontalScrollX: $horizontalScrollX,
                    horizontalScrollY: $horizontalScrollY,
                    pendingHorizontalScroll: $pendingHorizontalScroll,
                    selection: selection,
                    voiceColors: exampleVoiceColors,
                    playbackCursor: playbackEngine.currentCursor,
                    isMarqueeMode: isMarqueeMode,
                    onTap: { loc in
                        handleTap(at: loc, document: doc)
                    },
                    onMarqueeEnd: { rect, doc in
                        applyMarquee(rect: rect, document: doc)
                    },
                    onCursorChange: { newCursor, viewportWidth in
                        autoScrollHorizontalMac(
                            cursor: newCursor, doc: doc,
                            score: score,
                            isPlaying: playbackEngine.state == .playing,
                            viewportWidth: viewportWidth,
                            magnification: magnification,
                            horizontalScrollX: horizontalScrollX,
                            horizontalScrollY: horizontalScrollY,
                            pendingScroll: $pendingHorizontalScroll)
                    },
                    contentVersion: AnyHashable(scoreVersion),
                    inDocumentOverlay: inlineLyricEditorOverlay(
                        document: doc),
                    inDocumentOverlayKey: lyricEditTarget
                        .map { AnyHashable($0) },
                    onViewportSizeChange: { size in
                        horizontalViewportSize = size
                    })
            }
        case .paged:
            PagedScoreContainer(
                score: score,
                options: ScoreViewOptions(
                    staffSize: 18, systemGap: 16,
                    wrapToViewWidth: true),
                pageIndex: $pageIndex,
                totalPages: $totalPages)
        case .pdf:
            pdfPreview(score: score)
        }
    }

    @ViewBuilder
    private func pdfPreview(score: Score) -> some View {
        Group {
            if let layout = pdfLayout {
                pdfPreviewContent(
                    doc: layout.doc, pages: layout.pages,
                    page: layout.page)
            } else {
                ProgressView("Laying out…")
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.92))
            }
        }
        .task(id: scoreVersion) {
            pdfLayout = PDFPreviewLayout.build(score: score)
        }
    }

    @ViewBuilder
    private func pdfPreviewContent(
        doc: LayoutDocument,
        pages: [PDFExporter.PageBatch],
        page: EngravingPage
    ) -> some View {
        // Hosting the page deck inside an `NSScrollView` with
        // `allowsMagnification = true` mirrors how horizontal mode
        // stays sharp during pinch: AppKit re-rasterises the layer
        // tree at the new contents scale instead of bitmap-
        // upscaling a fixed-resolution snapshot. PDFPageView's own
        // `renderScale` stays at 1 — the scroll view supplies the
        // zoom.
        MagnifyingPDFScrollView(
            magnification: $pdfScale,
            doc: doc,
            pages: pages,
            page: page)
    }

    private func handleTap(at location: CGPoint, document: LayoutDocument) {
        let tester = ScoreHitTester(document: document)
        let target = tester.hitTest(at: location)

        // While playing: tap-to-seek. Audio jumps to the tapped
        // note while continuing to play; selection (single or
        // range) and any in-flight shift gesture are left alone.
        if playbackEngine.state == .playing {
            if let id = primaryItemID(of: target) {
                playbackEngine.seek(to: .item(id))
            }
            return
        }

        guard let target else {
            selection = .none
            return
        }
        // A fresh, deliberate selection drops the playback cursor
        // (no-op while playing — we already returned above). The next
        // `togglePlayback` then reads the selection instead of the
        // stale cursor.
        playbackEngine.clearCursor()
        let shift = NSEvent.modifierFlags.contains(.shift)

        // Beam without shift: range-select every note under the beam
        // run. This is our app-side policy — MuseScore would instead
        // let you edit the beam's length; we don't need that here.
        if case let .beam(notes) = target, !shift,
           let first = notes.first, let last = notes.last {
            selection = .range(
                anchor: .note(first), target: .note(last))
            return
        }

        // Everything else resolves to one "primary" ScoreItemID:
        //   - note/rest: themselves
        //   - stem/flag: the chord's first notehead
        //   - beam (with shift): the chord's first notehead
        let primary: ScoreItemID
        switch target {
        case .note(let id): primary = .note(id)
        case .rest(let id): primary = .rest(id)
        case .stem(let notes), .flag(let notes), .beam(let notes):
            guard let first = notes.first else {
                selection = .none
                return
            }
            primary = .note(first)
        }

        if shift {
            switch selection {
            case .none:
                selection = .single(primary)
            case .single(let anchor):
                selection = .range(anchor: anchor, target: primary)
            case .range(let anchor, _):
                selection = .range(anchor: anchor, target: primary)
            case .multi:
                // Multi has no obvious anchor for range extension;
                // shift-click after a marquee starts a fresh single.
                selection = .single(primary)
            }
        } else {
            selection = .single(primary)
            // MuseScore-style: a click on a single note triggers a
            // brief preview playback of just that note. Skip when
            // shift is held (extending a range) or for non-note
            // targets (rests, stems on chords without notes).
            if case .note(let id) = primary, let score {
                playbackEngine.playPreview(
                    noteID: id, in: score)
            }
        }
    }

    /// Resolve a marquee drag's rect against the score's hit-test
    /// columns and reflect the result into `selection`. An empty
    /// rect (no events overlap) clears the selection — same
    /// behaviour as a tap on empty space.
    private func applyMarquee(
        rect: CGRect, document: LayoutDocument
    ) {
        let tester = ScoreHitTester(document: document)
        let ids = tester.itemIDs(in: rect)
        if ids.isEmpty {
            selection = .none
        } else {
            selection = .multi(Set(ids))
        }
        // A fresh marquee selection drops the playback cursor for
        // the same reason `handleTap` does.
        playbackEngine.clearCursor()
    }

    private func loadBundled() {
        do {
            let loaded = try ScoreLoader.loadBundled()
            adoptLoadedScore(loaded, sourceName: "test.mscx")
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
        }
    }

    /// User-triggered "Open…" via NSOpenPanel. Reads the file at
    /// `url` (any of the formats `ScoreFileType` recognises),
    /// adopts it as the active score.
    func openUserURL(_ url: URL) {
        do {
            let loaded = try ScoreLoader.load(from: url)
            adoptLoadedScore(
                loaded, sourceName: url.lastPathComponent)
        } catch {
            errorMessage =
                "Could not load \(url.lastPathComponent): "
                + error.localizedDescription
        }
    }

    /// Replace the active score with `loaded`, reset cached
    /// per-score view state, kick off background sampler prep.
    /// Mirrors iOS's `adoptLoadedScore` but also rebuilds the
    /// horizontal layout synchronously (macOS uses it in the
    /// horizontal-mode entry path).
    private func adoptLoadedScore(
        _ loaded: Score, sourceName name: String
    ) {
        // Pre-build the horizontal layout synchronously. It
        // doesn't depend on the viewport (uses the score's
        // natural content width), so there's no reason to defer
        // it to a .task — and an if-let gated Group can fail
        // to trigger .task(id:) when it starts empty.
        let hOpts = Self.horizontalOptions
        // New score → drop the old cache; per-measure entries from
        // a previous score have no validity here.
        layoutCache = LayoutCache()
        horizontalDoc = LayoutEngine.layout(
            score: loaded, options: hOpts,
            availableWidth: LayoutEngine.naturalContentWidth(
                score: loaded, options: hOpts),
            cache: layoutCache)
        horizontalContexts = LayoutEngine.measureContexts(
            for: loaded)
        // Vertical layout still needs the viewport width, so it's
        // built by a .task in the .vertical case.
        verticalDoc = nil
        pdfLayout = nil
        score = loaded
        if let inputController {
            inputController.reset(score: loaded)
        } else {
            let controller = NoteInputController(score: loaded)
            controller.onScoreEdited = handleControllerEdit
            inputController = controller
        }
        sourceName = name
        errorMessage = nil
        scoreVersion = UUID()
        selection = .none
        pendingHorizontalScroll = nil
        playbackEngine.prepareInBackground(score: loaded)
    }

    /// Wired into `NoteInputController.onScoreEdited`. Runs after
    /// every successful apply / undo / redo — including from inside
    /// the `UndoManager` closure (⌘Z), which executes outside
    /// SwiftUI's normal update cycle and so can't be picked up
    /// reliably by `.onChange(of:)`. Inline @State writes from this
    /// callback DO propagate, since `adoptEditedScore` mutates
    /// stored `@State` properties directly via the captured view
    /// struct's State backing storage.
    private func handleControllerEdit() {
        if let edited = inputController?.score {
            adoptEditedScore(edited)
        }
    }

    /// Adopt a score edited via `inputController`.
    ///
    /// Optimised vs `adoptLoadedScore` to keep keystrokes responsive
    /// on large scores (`test.mscx` is ~1356 measures):
    ///   * `horizontalContexts` is NOT recomputed — a single-note
    ///     edit can't change clef / key / time / part metadata.
    ///   * The horizontal layout's `availableWidth` reuses the
    ///     existing `horizontalDoc.contentWidth`. The width *might*
    ///     drift by a glyph's worth on note-vs-rest swaps, but the
    ///     layout engine renormalises within the system on its own
    ///     pass — saving the full-score `naturalContentWidth` walk.
    private func adoptEditedScore(_ edited: Score) {
        let t0 = Date()
        let hOpts = Self.horizontalOptions
        // Reuse the previously-laid-out total width as the
        // `availableWidth` input. For a single-note edit this is
        // within a glyph's width of the true natural content width,
        // and the layout engine renormalises systems internally —
        // saves a full-score width walk.
        let availableWidth = horizontalDoc?.size.width
            ?? LayoutEngine.naturalContentWidth(
                score: edited, options: hOpts)
        let tLayoutStart = Date()
        horizontalDoc = LayoutEngine.layout(
            score: edited, options: hOpts,
            availableWidth: availableWidth,
            cache: layoutCache)
        let layoutMs = Date().timeIntervalSince(tLayoutStart) * 1000
        verticalDoc = nil
        pdfLayout = nil
        score = edited
        scoreVersion = UUID()
        let stateDoneMs = Date().timeIntervalSince(t0) * 1000
        // Schedule probes at three milestones:
        //   - tick:  next runloop iteration (~SwiftUI commit done)
        //   - paint: after Core Animation flushes the next frame
        //            (closest proxy for "user sees it")
        DispatchQueue.main.async {
            let tickMs = Date().timeIntervalSince(t0) * 1000
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                let paintMs = Date().timeIntervalSince(t0) * 1000
                print(String(
                    format: "edit: layout=%.1f state=%.1f tick=%.1f paint=%.1f ms (total %.1fms)",
                    layoutMs,
                    stateDoneMs - layoutMs,
                    tickMs - stateDoneMs,
                    paintMs - tickMs,
                    paintMs))
            }
            CATransaction.commit()
        }
    }
}
#endif
