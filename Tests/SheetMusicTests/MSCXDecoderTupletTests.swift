import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Verifies the mscx Voice decoder scales chord/rest durations according to the
/// enclosing `<Tuplet>`…`<endTuplet/>` bracket. The format we accept matches
/// what MuseScore 4's writer emits (see `TWrite::writeTupletStart` /
/// `writeTupletEnd`): a `<Tuplet>` element (no id attribute required, may carry
/// `<linkedMain/>`, `<Number>`, …) before the first member, and `<endTuplet/>`
/// after the last. Membership is positional — chords/rests don't need a
/// `<Tuplet>N</Tuplet>` back-reference.
@Suite struct MSCXDecoderTupletTests {
    private static func totalChordRestTicks(_ voice: Voice, division: Int) -> Int {
        voice.elements.reduce(0) { acc, el in
            switch el {
            case let .chord(c): return acc + c.duration.ticks(division: division)
            default: return acc
            }
        }
    }

    @Test func scalesTripletEighthChords() throws {
        // Three triplet-eighth chords should collectively last one quarter note,
        // not a dotted quarter (which is what you'd get if tuplets were ignored).
        let xml = """
        <voice>
          <Tuplet>
            <linkedMain/>
            <normalNotes>2</normalNotes>
            <actualNotes>3</actualNotes>
            <baseNote>eighth</baseNote>
            <Number><style>Tuplet</style><text>3</text></Number>
          </Tuplet>
          <Chord><durationType>eighth</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>64</pitch><tpc>18</tpc></Note></Chord>
          <endTuplet/>
        </voice>
        """
        let voice = try Voice.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 3)
        #expect(Self.totalChordRestTicks(voice, division: 480) == 480)
    }

    @Test func scalesTripletRestInsideTuplet() throws {
        let xml = """
        <voice>
          <Tuplet>
            <normalNotes>2</normalNotes>
            <actualNotes>3</actualNotes>
            <baseNote>eighth</baseNote>
          </Tuplet>
          <Rest><durationType>eighth</durationType></Rest>
          <Chord><durationType>eighth</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
          <endTuplet/>
        </voice>
        """
        let voice = try Voice.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 3)
        #expect(Self.totalChordRestTicks(voice, division: 480) == 480)
    }

    @Test func chordsAfterEndTupletAreNotScaled() throws {
        // Regression guard: chords after <endTuplet/> keep their nominal durations.
        let xml = """
        <voice>
          <Tuplet>
            <normalNotes>2</normalNotes>
            <actualNotes>3</actualNotes>
            <baseNote>eighth</baseNote>
          </Tuplet>
          <Chord><durationType>eighth</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>64</pitch><tpc>18</tpc></Note></Chord>
          <endTuplet/>
          <Chord><durationType>quarter</durationType><Note><pitch>67</pitch><tpc>15</tpc></Note></Chord>
        </voice>
        """
        let voice = try Voice.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 4)
        // triplet-eighths (=quarter) + plain quarter = 2 quarters
        #expect(Self.totalChordRestTicks(voice, division: 480) == 960)
    }

    /// Nested triplet inside a triplet. Each inner chord = 1/8 × 2/3 × 2/3 = 1/18 whole;
    /// three of them = 1/6 whole. Use a division cleanly divisible by 18 so integer
    /// tick truncation doesn't muddy the assertion.
    @Test func scalesNestedTriplets() throws {
        let xml = """
        <voice>
          <Tuplet>
            <normalNotes>2</normalNotes>
            <actualNotes>3</actualNotes>
            <baseNote>quarter</baseNote>
          </Tuplet>
          <Tuplet>
            <normalNotes>2</normalNotes>
            <actualNotes>3</actualNotes>
            <baseNote>eighth</baseNote>
          </Tuplet>
          <Chord><durationType>eighth</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>64</pitch><tpc>18</tpc></Note></Chord>
          <endTuplet/>
          <endTuplet/>
        </voice>
        """
        let voice = try Voice.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 3)
        let division = 1440
        #expect(Self.totalChordRestTicks(voice, division: division) == (4 * division) / 6)
    }

    /// Quintuplet 5:4 eighths — each = 1/8 × 4/5 = 1/10 whole; five of them = 1/2 whole.
    /// Clean at division=480 (4*480/10 = 192 ticks per chord).
    @Test func scalesQuintupletEighths() throws {
        let xml = """
        <voice>
          <Tuplet>
            <linkedMain/>
            <normalNotes>4</normalNotes>
            <actualNotes>5</actualNotes>
            <baseNote>eighth</baseNote>
            <Number><style>Tuplet</style><text>5</text></Number>
          </Tuplet>
          <Chord><durationType>eighth</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>64</pitch><tpc>18</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>65</pitch><tpc>13</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>67</pitch><tpc>15</tpc></Note></Chord>
          <endTuplet/>
        </voice>
        """
        let voice = try Voice.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 5)
        #expect(Self.totalChordRestTicks(voice, division: 480) == 960)
    }

    /// Sextuplet 6:4 sixteenths — each = 1/16 × 4/6 = 1/24 whole; six of them = 1/4 whole.
    @Test func scalesSextupletSixteenths() throws {
        let xml = """
        <voice>
          <Tuplet>
            <normalNotes>4</normalNotes>
            <actualNotes>6</actualNotes>
            <baseNote>16th</baseNote>
          </Tuplet>
          <Chord><durationType>16th</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
          <Chord><durationType>16th</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
          <Chord><durationType>16th</durationType><Note><pitch>64</pitch><tpc>18</tpc></Note></Chord>
          <Chord><durationType>16th</durationType><Note><pitch>65</pitch><tpc>13</tpc></Note></Chord>
          <Chord><durationType>16th</durationType><Note><pitch>67</pitch><tpc>15</tpc></Note></Chord>
          <Chord><durationType>16th</durationType><Note><pitch>69</pitch><tpc>17</tpc></Note></Chord>
          <endTuplet/>
        </voice>
        """
        let voice = try Voice.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 6)
        #expect(Self.totalChordRestTicks(voice, division: 480) == 480)
    }

    /// Septuplet 7:4 eighths — each = 1/8 × 4/7 = 1/14 whole; seven of them = 1/2 whole.
    /// Use division=1680 so 4×1680/14 = 480 ticks per chord lands cleanly; at PPQ=480
    /// this shape has unavoidable 1-tick rounding (MuseScore itself has the same).
    @Test func scalesSeptupletEighths() throws {
        let xml = """
        <voice>
          <Tuplet>
            <normalNotes>4</normalNotes>
            <actualNotes>7</actualNotes>
            <baseNote>eighth</baseNote>
            <Number><style>Tuplet</style><text>7</text></Number>
          </Tuplet>
          <Chord><durationType>eighth</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>64</pitch><tpc>18</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>65</pitch><tpc>13</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>67</pitch><tpc>15</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>69</pitch><tpc>17</tpc></Note></Chord>
          <Chord><durationType>eighth</durationType><Note><pitch>71</pitch><tpc>19</tpc></Note></Chord>
          <endTuplet/>
        </voice>
        """
        let voice = try Voice.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 7)
        let division = 1680
        #expect(Self.totalChordRestTicks(voice, division: division) == division * 2)
    }
}
