/// Fixture for SchemaParserTests. Parsed as text — not compiled.
@WireFormat(kotlin: .skip)
struct AppleOnlyWire {
    var value: Int32
}

@WireFormat(kotlin: .explicit("io.example.legacy.Frame"))
struct CustomLocationWire {
    var tick: Int64
}

@WireFormatChoice(kotlin: .skip)
enum SkippedChoiceWire {
    case a
}
