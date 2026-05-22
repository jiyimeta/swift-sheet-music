import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expansion of `@WireFormatEnum` on a `CaseIterable & Equatable` enum:
/// emits one extension that adds `WireFormat` conformance whose encoded
/// layout is a single `UInt8` carrying the case's `allCases` ordinal.
///
/// The macro does not inspect the enum's case list — it relies on the
/// `CaseIterable.allCases` runtime collection. This keeps the macro
/// agnostic to associated values syntactically (the compiler will reject
/// associated-value enums at the `Equatable` / `CaseIterable` synthesis
/// step instead).
public struct WireFormatEnumMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext,
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(EnumDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: WireFormatDiagnostic.notAnEnum,
            ))
            return []
        }

        let extensionSource: DeclSyntax = """
        extension \(type.trimmed): WireFormatEncodable, WireFormatDecodable {
            public func encode(into writer: inout WireFormatWriter) {
                let cases = Self.allCases
                let index = cases.firstIndex(of: self).map {
                    cases.distance(from: cases.startIndex, to: $0)
                } ?? 0
                writer.appendInteger(UInt8(clamping: index))
            }

            public init(from reader: inout WireFormatReader) throws {
                let ordinal = try reader.readInteger(UInt8.self)
                let cases = Self.allCases
                let index = cases.index(cases.startIndex, offsetBy: Int(ordinal))
                guard index < cases.endIndex else {
                    throw WireFormatError.invalidCount(Int32(ordinal))
                }
                self = cases[index]
            }
        }
        """

        guard let extensionDecl = extensionSource.as(ExtensionDeclSyntax.self) else {
            return []
        }
        return [extensionDecl]
    }
}
