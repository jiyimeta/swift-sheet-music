import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Sticking {
    /// Build the `<Sticking>` element. Inverse of `MSCXDecoder+Sticking`.
    ///
    /// Child order is only *mostly* free. MuseScore dispatches by tag name, but
    /// `<style>` is a reset: `TextBase::setProperty(Pid::TEXT_STYLE)` runs
    /// `initTextStyleType`, which overwrites every text-style property (face,
    /// size, bold, color, align, frame) with the style's own values — so a
    /// property read BEFORE `<style>` is discarded. MuseScore tripped over this
    /// itself in 4.6.0–4.6.2 (`rw/read460/tread.cpp:625`).
    ///
    /// Preserved markup keeps source order, and the shared trailing writer
    /// emits `<color>` after that markup. A preserved `<style>` therefore lands
    /// before `<color>` and cannot reset the author color on the next read.
    ///
    /// `<Sticking>` has been readable since MuseScore 3.3; 3.2 and earlier drop
    /// it as unknown. Every target this encoder emits is at or above that, so
    /// there is no version branch.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children = [XMLTreeNode(name: "text", text: text)]
        children += elementProperties.mscxChildren()
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Sticking", children: children)
    }
}
