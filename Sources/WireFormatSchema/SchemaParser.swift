import Foundation
import SwiftParser
import SwiftSyntax

public enum SchemaParser {
    /// Parses a WireFormat schema from Swift source. The `fileName` parameter is retained for
    /// future per-file diagnostic output in Task 11 (EmitKotlinCodecs CLI).
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
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        for attribute in node.attributes {
            guard
                let attr = attribute.as(AttributeSyntax.self)
            else { continue }
            let attrName = attr.attributeName.trimmedDescription
            let target = AttributeArgumentExtractor.kotlinTarget(of: attr)
            switch attrName {
            case "WireFormatChoice":
                types.append(.choice(WireChoice(
                    name: node.name.text,
                    cases: collectChoiceCases(from: node),
                    kotlinTarget: target,
                )))
            case "WireFormatEnum":
                types.append(.rawEnum(WireRawEnum(
                    name: node.name.text,
                    cases: collectRawCases(from: node),
                    kotlinTarget: target,
                )))
            default:
                continue
            }
        }
        return .visitChildren
    }

    private func collectChoiceCases(from enumDecl: EnumDeclSyntax) -> [WireChoiceCase] {
        var out: [WireChoiceCase] = []
        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                let payload: [PayloadField] = element.parameterClause?.parameters.map { param in
                    PayloadField(
                        label: param.firstName?.text,
                        typeText: param.type.trimmedDescription,
                    )
                } ?? []
                out.append(WireChoiceCase(
                    name: element.name.text,
                    payload: payload,
                ))
            }
        }
        return out
    }

    private func collectRawCases(from enumDecl: EnumDeclSyntax) -> [String] {
        var out: [String] = []
        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                out.append(element.name.text)
            }
        }
        return out
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
