#if os(macOS)
    import AppKit
    import SwiftUI

    /// A transparent AppKit text field whose editor can style its opaque
    /// caret independently from its translucent selection background.
    @available(macOS 15.0, *)
    struct EngravedTextField: NSViewRepresentable {
        @Binding var text: String
        let font: PlatformFont
        let alignment: NSTextAlignment
        let focus: FocusState<Bool>.Binding
        let onSubmit: () -> Void
        let onCancel: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> WindowAwareTextField {
            let field = WindowAwareTextField(frame: .zero)
            field.cell = IndependentSelectionTextFieldCell(textCell: "")
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.isEditable = true
            field.isSelectable = true
            field.lineBreakMode = .byClipping
            field.cell?.usesSingleLineMode = true
            field.appearance = NSAppearance(named: .aqua)
            field.delegate = context.coordinator
            field.onInitialWindowAttachment = { [weak field, weak coordinator = context.coordinator] in
                guard let field, let coordinator else { return }
                coordinator.restoreInitialFocus(to: field)
            }
            field.setContentHuggingPriority(.required, for: .horizontal)
            field.setContentCompressionResistancePriority(
                .required,
                for: .horizontal,
            )
            configure(field)
            return field
        }

        func updateNSView(
            _ field: WindowAwareTextField,
            context: Context,
        ) {
            context.coordinator.update(parent: self)
            configure(field)
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView field: WindowAwareTextField,
            context: Context,
        ) -> CGSize? {
            field.intrinsicContentSize
        }

        static func dismantleNSView(
            _ field: WindowAwareTextField,
            coordinator: Coordinator,
        ) {
            coordinator.stopObservingFieldEditor()
            field.wantsFirstResponder = false
            field.onInitialWindowAttachment = nil
            field.delegate = nil
        }

        private func configure(_ field: WindowAwareTextField) {
            let editor = field.currentEditor() as? NSTextView
            if editor?.hasMarkedText() != true,
               field.stringValue != text
            {
                field.stringValue = text
            }
            field.font = font
            field.alignment = alignment
            field.textColor = .clear
            field.sizingText = editor?.string ?? text
            field.wantsFirstResponder = focus.wrappedValue
        }

        @MainActor
        final class Coordinator: NSObject, NSTextFieldDelegate {
            private var parent: EngravedTextField

            private var fieldEditorObservers: [NSObjectProtocol] = []
            private var lastPublishedText: String

            init(parent: EngravedTextField) {
                self.parent = parent
                lastPublishedText = parent.text
            }

            func update(parent: EngravedTextField) {
                self.parent = parent
                lastPublishedText = parent.text
            }

            func restoreInitialFocus(to field: WindowAwareTextField) {
                parent.focus.wrappedValue = true
                field.wantsFirstResponder = true
            }

            func controlTextDidBeginEditing(_ notification: Notification) {
                parent.focus.wrappedValue = true
                guard let field = notification.object as? WindowAwareTextField,
                      let editor = field.currentEditor() as? NSTextView
                else { return }
                observe(fieldEditor: editor, for: field)
                publishCurrentText(from: field)
                // Keep the field editor's own select-all on focus. The
                // observation above only reads its string; it never changes
                // selection or marked-text state.
                //
                // MuseScore selects the existing text on arrival too, in
                // every path that lands on an element that already has
                // some: `addText` calls `cursor()->selectWord()` for
                // rehearsal marks and tempo text, `navigateToLyrics`
                // selects the whole syllable it steps onto, and
                // `navigateToNextSyllable` / `addMelisma` end with
                // `selectAll()`. Typing replaces, which is what you want
                // walking note to note; appending is one arrow key away.
                //
                // This only became viable once the selection stopped
                // painting the engraved glyph out — see the translucent
                // `selectedTextAttributes` below.
            }

            func controlTextDidChange(_ notification: Notification) {
                guard let field = notification.object as? WindowAwareTextField else {
                    return
                }
                publishCurrentText(from: field)
            }

            func controlTextDidEndEditing(_ notification: Notification) {
                if let field = notification.object as? WindowAwareTextField {
                    publishCurrentText(from: field)
                }
                stopObservingFieldEditor()
                parent.focus.wrappedValue = false
            }

            func stopObservingFieldEditor() {
                for observer in fieldEditorObservers {
                    NotificationCenter.default.removeObserver(observer)
                }
                fieldEditorObservers.removeAll()
            }

            func control(
                _ control: NSControl,
                textView: NSTextView,
                doCommandBy commandSelector: Selector,
            ) -> Bool {
                switch commandSelector {
                case #selector(NSResponder.insertNewline(_:)):
                    parent.onSubmit()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    parent.onCancel()
                    return true
                default:
                    return false
                }
            }

            private func observe(
                fieldEditor editor: NSTextView,
                for field: WindowAwareTextField,
            ) {
                stopObservingFieldEditor()
                let center = NotificationCenter.default
                // AppKit does not post `NSText.didChangeNotification` for
                // every marked-text replacement. It does post the public
                // selection notification as the marked range is updated, so
                // observe both and deduplicate in `publishCurrentText`.
                fieldEditorObservers = [
                    center.addObserver(
                        forName: NSText.didChangeNotification,
                        object: editor,
                        queue: .main,
                    ) { [weak self, weak field] _ in
                        MainActor.assumeIsolated {
                            guard let self, let field else { return }
                            self.publishCurrentText(from: field)
                        }
                    },
                    center.addObserver(
                        forName: NSTextView.didChangeSelectionNotification,
                        object: editor,
                        queue: .main,
                    ) { [weak self, weak field] _ in
                        MainActor.assumeIsolated {
                            guard let self, let field else { return }
                            self.publishCurrentText(from: field)
                        }
                    },
                ]
            }

            private func publishCurrentText(from field: WindowAwareTextField) {
                let editor = field.currentEditor() as? NSTextView
                let currentText = editor?.string ?? field.stringValue
                field.sizingText = currentText
                guard lastPublishedText != currentText else { return }
                lastPublishedText = currentText
                if parent.text != currentText {
                    parent.text = currentText
                }
            }
        }
    }

    @available(macOS 15.0, *)
    private final class IndependentSelectionTextFieldCell: NSTextFieldCell {
        override func setUpFieldEditorAttributes(_ textObject: NSText) -> NSText {
            let configured = super.setUpFieldEditorAttributes(textObject)
            guard let editor = configured as? NSTextView else {
                return configured
            }
            editor.appearance = NSAppearance(named: .aqua)
            editor.textColor = .clear
            editor.insertionPointColor = .controlAccentColor
            var selectedAttributes = editor.selectedTextAttributes
            selectedAttributes[.foregroundColor] = NSColor.clear
            selectedAttributes[.backgroundColor] = NSColor
                .selectedTextBackgroundColor
                .withAlphaComponent(0.55)
            editor.selectedTextAttributes = selectedAttributes
            return editor
        }
    }

    @available(macOS 15.0, *)
    final class WindowAwareTextField: NSTextField {
        var onInitialWindowAttachment: (() -> Void)?
        var sizingText = "" {
            didSet {
                if sizingText != oldValue {
                    invalidateIntrinsicContentSize()
                }
            }
        }

        var wantsFirstResponder = false {
            didSet { synchronizeFirstResponder() }
        }

        private var hasAttachedToWindow = false

        override var intrinsicContentSize: NSSize {
            let measured: NSSize
            if let cell,
               cell.stringValue != sizingText,
               let sizingCell = cell.copy() as? NSTextFieldCell
            {
                sizingCell.stringValue = sizingText
                measured = sizingCell.cellSize
            } else {
                measured = cell?.cellSize ?? super.intrinsicContentSize
            }
            return NSSize(
                width: max(measured.width, 1),
                height: measured.height,
            )
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            synchronizeFirstResponder()
            guard window != nil, !hasAttachedToWindow else { return }
            hasAttachedToWindow = true
            // The previous identity's field editor can resign later in the
            // same update and write the shared FocusState back to false.
            // Retry after that teardown, while this view has a real window.
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil else { return }
                onInitialWindowAttachment?()
            }
        }

        private func synchronizeFirstResponder() {
            guard let window else { return }
            if wantsFirstResponder {
                if let editor = currentEditor(),
                   window.firstResponder === editor
                {
                    return
                }
                window.makeFirstResponder(self)
            } else if let editor = currentEditor(),
                      window.firstResponder === editor
            {
                window.makeFirstResponder(nil)
            }
        }
    }
#endif
