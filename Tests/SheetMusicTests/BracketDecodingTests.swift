import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct BracketDecodingTests {
    @Test func decodeBraceWithSpanAndColumn() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="1" span="2" col="0" visible="1"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, _, staff) = Staff.declared(node)
        #expect(staff.brackets.count == 1)
        let b = staff.brackets[0]
        #expect(b.type == .brace)
        #expect(b.span == 2)
        #expect(b.column == 0)
        #expect(b.visible == true)
    }

    @Test func decodeMultipleBracketsOnOneStaff() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="0" span="2" col="0"/>
          <bracket type="2" span="2" col="1"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, _, staff) = Staff.declared(node)
        #expect(staff.brackets.count == 2)
        #expect(staff.brackets[0].type == .normal)
        #expect(staff.brackets[0].column == 0)
        #expect(staff.brackets[1].type == .square)
        #expect(staff.brackets[1].column == 1)
    }

    @Test func decodeOmitsCol() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="2" span="2"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, _, staff) = Staff.declared(node)
        #expect(staff.brackets.count == 1)
        #expect(staff.brackets[0].column == 0)
    }

    @Test func decodeOmitsVisible() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="1" span="2"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, _, staff) = Staff.declared(node)
        #expect(staff.brackets[0].visible == true)
    }

    @Test func decodeVisibleZeroParsesAsFalse() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="1" span="2" visible="0"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, _, staff) = Staff.declared(node)
        #expect(staff.brackets[0].visible == false)
    }

    @Test func decodeUnknownTypeIgnored() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="99" span="1"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, _, staff) = Staff.declared(node)
        #expect(staff.brackets.isEmpty)
    }

    @Test func decodeNegativeSpanClampedToOne() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="0" span="-3"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, _, staff) = Staff.declared(node)
        #expect(staff.brackets.count == 1)
        #expect(staff.brackets[0].span == 1)
    }

    @Test func decodeMissingTypeIgnored() throws {
        // Permissive policy: a <bracket> with no type attribute is dropped.
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket span="2"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, _, staff) = Staff.declared(node)
        #expect(staff.brackets.isEmpty)
    }

    /// MuseScore 5 writes a bracket as `<BracketItem>` (`TWrite::write(const BracketItem*)`): it reads into the same
    /// `Staff.brackets` as the 4.x `<bracket>` and is consumed, so the encoder's `<bracket>` does not double it.
    @Test func decodeMuseScore5BracketItem() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <BracketItem><type>Brace</type><bracketSpan>2</bracketSpan><level>1</level></BracketItem>
          <BracketItem><type>Square</type><bracketSpan>3</bracketSpan><level>2</level><visible>0</visible></BracketItem>
        </Staff>
        """
        let (_, _, staff) = try Staff.declared(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(staff.brackets == [
            BracketItem(type: .brace, span: 2, column: 1),
            BracketItem(type: .square, span: 3, column: 2, visible: false),
        ])
        #expect(staff.preservedMarkup.isEmpty)
    }

    @Test func decodeMuseScore5GroupBracketStaysPreserved() throws {
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <BracketItem><type>Group</type><bracketSpan>2</bracketSpan><level>0</level></BracketItem>
        </Staff>
        """
        let (_, _, staff) = try Staff.declared(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(staff.brackets.isEmpty)
        #expect(staff.preservedMarkup.map(\.name) == ["BracketItem"])
    }

    @Test func decodeMissingSpanIgnored() throws {
        // No span → can't produce a meaningful bracket. Drop.
        let xml = """
        <Staff id="1">
          <StaffType group="pitched"><name>stdNormal</name></StaffType>
          <bracket type="1"/>
        </Staff>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let (_, _, staff) = Staff.declared(node)
        #expect(staff.brackets.isEmpty)
    }
}
