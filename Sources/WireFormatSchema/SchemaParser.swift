import Foundation
import SwiftParser
import SwiftSyntax

public enum SchemaParser {
    public static func parse(source: String, fileName: String) -> Schema {
        let tree = Parser.parse(source: source)
        let visitor = WireTypeVisitor(viewMode: .sourceAccurate)
        visitor.walk(tree)
        return Schema(types: visitor.types)
    }
}

final class WireTypeVisitor: SyntaxVisitor {
    var types: [WireType] = []

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        for attribute in node.attributes {
            guard
                let attr = attribute.as(AttributeSyntax.self),
                attr.attributeName.trimmedDescription == "WireFormat"
            else { continue }
            let fields = collectFields(from: node)
            let target = AttributeArgumentExtractor.kotlinTarget(of: attr)
            types.append(.struct(WireStruct(
                name: node.name.text,
                fields: fields,
                kotlinTarget: target,
            )))
        }
        return .skipChildren
    }

    private func collectFields(from struct: StructDeclSyntax) -> [WireField] {
        var out: [WireField] = []
        for member in `struct`.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isStatic = varDecl.modifiers.contains { mod in
                mod.name.text == "static" || mod.name.text == "class"
            }
            if isStatic { continue }
            for binding in varDecl.bindings {
                guard binding.accessorBlock == nil else { continue }
                guard
                    let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                    let typeAnno = binding.typeAnnotation
                else { continue }
                out.append(WireField(
                    name: ident.identifier.text,
                    typeText: typeAnno.type.trimmedDescription,
                ))
            }
        }
        return out
    }
}
