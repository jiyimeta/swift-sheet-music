import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expansion of `@WireFormat` on a struct: emits one extension that adds
/// `WireFormatEncodable` + `WireFormatDecodable` conformance whose encoded
/// layout is each stored property in declaration order.
public struct WireFormatMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext,
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: WireFormatDiagnostic.notAStruct,
            ))
            return []
        }

        let properties = collectStoredProperties(of: structDecl, context: context)

        let encodeLines = properties.map { property in
            "self.\(property.name).encode(into: &writer)"
        }
        let decodeLines = properties.map { property in
            "self.\(property.name) = try \(property.typeText)(from: &reader)"
        }

        // 4-space indent so the rendered body matches the surrounding source style.
        let encodeBody = encodeLines.joined(separator: "\n        ")
        let decodeBody = decodeLines.joined(separator: "\n        ")

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

    private static func collectStoredProperties(
        of structDecl: StructDeclSyntax,
        context: some MacroExpansionContext,
    ) -> [(name: String, typeText: String)] {
        var out: [(name: String, typeText: String)] = []

        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

            let isStatic = varDecl.modifiers.contains { modifier in
                modifier.name.text == "static" || modifier.name.text == "class"
            }
            if isStatic { continue }

            for binding in varDecl.bindings {
                if isComputed(binding: binding) { continue }

                guard let identPattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    continue
                }
                let name = identPattern.identifier.text

                guard let typeAnnotation = binding.typeAnnotation else {
                    context.diagnose(Diagnostic(
                        node: Syntax(binding),
                        message: WireFormatDiagnostic.missingTypeAnnotation(propertyName: name),
                    ))
                    continue
                }

                let typeText = typeAnnotation.type.trimmedDescription
                out.append((name: name, typeText: typeText))
            }
        }
        return out
    }

    private static func isComputed(binding: PatternBindingSyntax) -> Bool {
        guard let accessorBlock = binding.accessorBlock else { return false }
        switch accessorBlock.accessors {
        case .getter:
            return true
        case let .accessors(list):
            return list.contains { accessor in
                let name = accessor.accessorSpecifier.text
                return name == "get" || name == "set" || name == "_modify" || name == "_read"
            }
        }
    }
}
