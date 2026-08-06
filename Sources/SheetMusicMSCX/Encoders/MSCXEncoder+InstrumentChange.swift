import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension InstrumentChange {
    /// Build the `<InstrumentChange>` element. Body is completed in the
    /// encode task; this stub keeps `encodeSystem` exhaustive.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        XMLTreeNode(
            name: "InstrumentChange",
            children: [XMLTreeNode(name: "text", text: text)],
        )
    }
}
