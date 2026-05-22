import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SheetMusicWireFormatPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        WireFormatMacro.self,
        WireFormatEnumMacro.self,
        WireFormatChoiceMacro.self,
    ]
}
