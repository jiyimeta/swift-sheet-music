#if !os(macOS)
    import SwiftUI
    import UIKit

    /// A transparent UIKit text field whose caret and selection sit over
    /// the separately engraved score text.
    struct EngravedTextField: UIViewRepresentable {
        @Binding var text: String
        let font: PlatformFont
        let alignment: NSTextAlignment
        let focus: FocusState<Bool>.Binding
        let onSubmit: () -> Void
        let onCancel: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeUIView(context: Context) -> WindowAwareTextField {
            let field = WindowAwareTextField(frame: .zero)
            field.borderStyle = .none
            field.backgroundColor = .clear
            field.textColor = .clear
            field.adjustsFontSizeToFitWidth = false
            // UIKit uses tint for both the caret and selection highlight. Its
            // translucent highlight is painted beneath the glyph layer, so the
            // engraved text remains readable without an AppKit-style override.
            field.tintColor = .tintColor
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.autocapitalizationType = .none
            field.returnKeyType = .done
            field.delegate = context.coordinator
            field.onCancel = onCancel
            field.onInitialWindowAttachment = { [weak field, weak coordinator = context.coordinator] in
                guard let field, let coordinator else { return }
                coordinator.restoreInitialFocus(to: field)
            }
            field.setContentHuggingPriority(.required, for: .horizontal)
            field.setContentCompressionResistancePriority(
                .required,
                for: .horizontal,
            )
            context.coordinator.observeTextChanges(from: field)
            configure(field)
            return field
        }

        func updateUIView(
            _ field: WindowAwareTextField,
            context: Context,
        ) {
            context.coordinator.update(parent: self)
            configure(field)
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView field: WindowAwareTextField,
            context: Context,
        ) -> CGSize? {
            field.intrinsicContentSize
        }

        static func dismantleUIView(
            _ field: WindowAwareTextField,
            coordinator: Coordinator,
        ) {
            coordinator.stopObservingTextChanges(from: field)
            field.wantsFirstResponder = false
            field.onInitialWindowAttachment = nil
            field.onCancel = nil
            field.delegate = nil
        }

        private func configure(_ field: WindowAwareTextField) {
            if field.markedTextRange == nil,
               field.text != text
            {
                field.text = text
            }
            field.font = font
            field.textAlignment = alignment
            field.textColor = .clear
            field.sizingText = field.text ?? text
            field.wantsFirstResponder = focus.wrappedValue
            field.onCancel = onCancel
        }

        @MainActor
        final class Coordinator: NSObject, UITextFieldDelegate {
            private var parent: EngravedTextField
            private var textDidChangeObserver: NSObjectProtocol?
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

            func textFieldDidBeginEditing(_ field: UITextField) {
                parent.focus.wrappedValue = true
                field.selectAll(nil)
                // MuseScore selects existing text on arrival too: `addText`
                // selects the word for rehearsal marks and tempo text,
                // `navigateToLyrics` selects the syllable it steps onto, and
                // `navigateToNextSyllable` / `addMelisma` end with `selectAll()`.
                // Typing replaces; appending remains one arrow key away.
            }

            func textFieldShouldReturn(_: UITextField) -> Bool {
                parent.onSubmit()
                return false
            }

            func textFieldDidEndEditing(_ field: UITextField) {
                if let field = field as? WindowAwareTextField {
                    publishCurrentText(from: field)
                }
                parent.focus.wrappedValue = false
            }

            func observeTextChanges(from field: WindowAwareTextField) {
                stopObservingTextChanges(from: field)
                field.addTarget(
                    self,
                    action: #selector(textFieldEditingChanged(_:)),
                    for: .editingChanged,
                )
                let center = NotificationCenter.default
                // UIKit does not send `.editingChanged` for every marked-text
                // replacement. It does post `UITextField.textDidChangeNotification`
                // as the marked run changes, so observe both and deduplicate in
                // `publishCurrentText`.
                textDidChangeObserver = center.addObserver(
                    forName: UITextField.textDidChangeNotification,
                    object: field,
                    queue: .main,
                ) { [weak self, weak field] _ in
                    MainActor.assumeIsolated {
                        guard let self, let field else { return }
                        self.publishCurrentText(from: field)
                    }
                }
            }

            func stopObservingTextChanges(from field: WindowAwareTextField) {
                field.removeTarget(
                    self,
                    action: #selector(textFieldEditingChanged(_:)),
                    for: .editingChanged,
                )
                if let textDidChangeObserver {
                    NotificationCenter.default.removeObserver(
                        textDidChangeObserver,
                    )
                    self.textDidChangeObserver = nil
                }
            }

            @objc private func textFieldEditingChanged(_ field: WindowAwareTextField) {
                publishCurrentText(from: field)
            }

            private func publishCurrentText(from field: WindowAwareTextField) {
                let currentText = field.text ?? ""
                field.sizingText = currentText
                guard lastPublishedText != currentText else { return }
                lastPublishedText = currentText
                if parent.text != currentText {
                    parent.text = currentText
                }
            }
        }
    }

    final class WindowAwareTextField: UITextField {
        var onInitialWindowAttachment: (() -> Void)?
        var onCancel: (() -> Void)?
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

        override var intrinsicContentSize: CGSize {
            let sizingFont = font
                ?? UIFont.systemFont(ofSize: UIFont.systemFontSize)
            let measured = (sizingText as NSString).size(
                withAttributes: [.font: sizingFont],
            )
            return CGSize(
                width: max(measured.width, 1),
                height: sizingFont.lineHeight,
            )
        }

        override var keyCommands: [UIKeyCommand]? {
            // Hardware keyboards on iPad send Escape. The software keyboard has
            // no Escape, so the host also needs a visible cancel affordance.
            [
                UIKeyCommand(
                    input: UIKeyCommand.inputEscape,
                    modifierFlags: [],
                    action: #selector(cancelEditing),
                ),
            ]
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
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
            guard window != nil else { return }
            if wantsFirstResponder {
                if !isFirstResponder {
                    becomeFirstResponder()
                }
            } else if isFirstResponder {
                resignFirstResponder()
            }
        }

        @objc private func cancelEditing() {
            onCancel?()
        }
    }
#endif
