import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expansion of `@WireFormatChoice` on a sum-type enum: emits one
/// extension that adds `WireFormat` conformance whose encoded layout is
/// a single `UInt8` discriminator (= case's declaration order index)
/// followed by the chosen case's associated values, each encoded as
/// `WireFormat` in declaration order.
///
/// All associated value types must themselves conform to `WireFormat`.
/// The compiler will reject the macro-generated code at type-check time
/// if a payload type does not conform.
///
/// Wire-stable as long as case declaration order is preserved. Adding a
/// new case at the end is forward-compatible (old readers reject it
/// with `invalidCount`); reordering or removing cases breaks the wire.
public struct WireFormatChoiceMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext,
    ) throws -> [ExtensionDeclSyntax] {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: WireFormatDiagnostic.notAnEnum,
            ))
            return []
        }

        let cases = collectCases(of: enumDecl)

        let encodeBody = renderEncodeBody(cases: cases)
        let decodeBody = renderDecodeBody(cases: cases)

        let extensionSource: DeclSyntax = """
        extension \(type.trimmed): WireFormatEncodable, WireFormatDecodable {
            public func encode(into writer: inout WireFormatWriter) {
                \(raw: encodeBody)
            }

            public init(from reader: inout WireFormatReader) throws {
                \(raw: decodeBody)
            }
        }
        """

        guard let extensionDecl = extensionSource.as(ExtensionDeclSyntax.self) else {
            return []
        }
        return [extensionDecl]
    }

    // MARK: - Case collection

    struct CaseInfo {
        let name: String
        let parameters: [Parameter]

        struct Parameter {
            let label: String?
            let typeText: String
        }
    }

    private static func collectCases(of enumDecl: EnumDeclSyntax) -> [CaseInfo] {
        var out: [CaseInfo] = []
        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                let parameters: [CaseInfo.Parameter]
                if let clause = element.parameterClause {
                    parameters = clause.parameters.map { param in
                        let label = labelFor(param: param)
                        let typeText = param.type.trimmedDescription
                        return CaseInfo.Parameter(label: label, typeText: typeText)
                    }
                } else {
                    parameters = []
                }
                out.append(CaseInfo(name: element.name.text, parameters: parameters))
            }
        }
        return out
    }

    private static func labelFor(param: EnumCaseParameterSyntax) -> String? {
        // For `case .beat(measureIndex: Int, tickInMeasure: Int)`:
        //   firstName.text == "measureIndex" — that's the external label.
        // For `case .explicit(VoiceElementID)`: firstName == nil.
        // For `case .foo(_ x: Int)`: firstName.text == "_" — treat as no label.
        guard let name = param.firstName?.text, name != "_" else { return nil }
        return name
    }

    // MARK: - Body rendering

    private static func renderEncodeBody(cases: [CaseInfo]) -> String {
        if cases.isEmpty {
            // An empty enum can't be inhabited; emit `switch self {}` for exhaustiveness.
            return "switch self {}"
        }
        var lines = ["switch self {"]
        for (index, c) in cases.enumerated() {
            if c.parameters.isEmpty {
                lines.append("case .\(c.name):")
                lines.append("    writer.appendInteger(UInt8(\(index)))")
            } else {
                let bindings = c.parameters.indices.map { "let v\($0)" }.joined(separator: ", ")
                lines.append("case .\(c.name)(\(bindings)):")
                lines.append("    writer.appendInteger(UInt8(\(index)))")
                for valueIndex in c.parameters.indices {
                    lines.append("    v\(valueIndex).encode(into: &writer)")
                }
            }
        }
        lines.append("}")
        return lines.joined(separator: "\n        ")
    }

    private static func renderDecodeBody(cases: [CaseInfo]) -> String {
        var lines: [String] = [
            "let discriminator = try reader.readInteger(UInt8.self)",
            "switch discriminator {",
        ]
        for (index, c) in cases.enumerated() {
            lines.append("case \(index):")
            if c.parameters.isEmpty {
                lines.append("    self = .\(c.name)")
            } else {
                for (valueIndex, param) in c.parameters.enumerated() {
                    lines.append("    let v\(valueIndex) = try \(param.typeText)(from: &reader)")
                }
                let construction = c.parameters.enumerated().map { idx, param -> String in
                    if let label = param.label {
                        return "\(label): v\(idx)"
                    } else {
                        return "v\(idx)"
                    }
                }.joined(separator: ", ")
                lines.append("    self = .\(c.name)(\(construction))")
            }
        }
        lines.append("default:")
        lines.append("    throw WireFormatError.invalidCount(Int32(discriminator))")
        lines.append("}")
        return lines.joined(separator: "\n        ")
    }
}
