import SwiftSyntax

enum AttributeArgumentExtractor {
    /// Returns the `kotlin:` argument value if present on the attribute,
    /// recognising literal forms `.auto`, `.skip`, `.explicit("...")`.
    static func kotlinTarget(of attribute: AttributeSyntax) -> KotlinTarget {
        guard case let .argumentList(args) = attribute.arguments else {
            return .auto
        }
        for arg in args where arg.label?.text == "kotlin" {
            return parseKotlinTarget(from: arg.expression)
        }
        return .auto
    }

    private static func parseKotlinTarget(from expr: ExprSyntax) -> KotlinTarget {
        if let member = expr.as(MemberAccessExprSyntax.self) {
            switch member.declName.baseName.text {
            case "auto": return .auto
            case "skip": return .skip
            default: return .auto
            }
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "explicit",
           let first = call.arguments.first,
           let strLit = first.expression.as(StringLiteralExprSyntax.self),
           let segment = strLit.segments.first?.as(StringSegmentSyntax.self)
        {
            return .explicit(segment.content.text)
        }
        return .auto
    }
}
