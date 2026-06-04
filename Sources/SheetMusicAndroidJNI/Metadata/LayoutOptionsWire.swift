import Foundation
import SheetMusicCore
import SheetMusicLayout
import Wirelet

/// Display settings passed from the Android Reader to the layout bridge across JNI.
/// Self-contained (no cross-directory @WireFormat references) so the SheetMusicAndroid
/// wirelet codegen can emit its Kotlin model + codec from this file alone.
@WireFormat
public struct LayoutOptionsWire {
    public var layoutMode: UInt8 // 0 = vertical, 1 = horizontal, 2 = page
    public var staffSize: Double
    public var honorLayoutBreaks: UInt8 // 0/1
    public var collapseMultiMeasureRests: UInt8 // 0/1
    public var showsInvisibleElements: UInt8 // 0/1
    public var hiddenStaves: [HiddenStaffWire]
    public var clefOverrides: [ClefOverrideWire]
}

@WireFormat
public struct HiddenStaffWire {
    public var partIndex: Int32
    public var staffIndexInPart: Int32
}

@WireFormat
public struct ClefOverrideWire {
    public var partIndex: Int32
    public var staffIndexInPart: Int32
    public var rawType: String
}

extension LayoutOptionsWire {
    public enum Mode: UInt8 { case vertical = 0, horizontal = 1, page = 2 }
    public var mode: Mode {
        Mode(rawValue: layoutMode) ?? .vertical
    }

    public var hiddenStaffAddresses: Set<StaffAddress> {
        Set(hiddenStaves.map { StaffAddress(partIndex: Int($0.partIndex), staffIndexInPart: Int($0.staffIndexInPart)) })
    }

    public var clefOverrideMap: [StaffAddress: String] {
        Dictionary(uniqueKeysWithValues: clefOverrides.map {
            (StaffAddress(partIndex: Int($0.partIndex), staffIndexInPart: Int($0.staffIndexInPart)), $0.rawType)
        })
    }

    /// Default for the legacy no-options LayoutBridge.compute path + tests.
    public static var verticalDefault: LayoutOptionsWire {
        LayoutOptionsWire(
            layoutMode: 0, staffSize: 28,
            honorLayoutBreaks: 1, collapseMultiMeasureRests: 0, showsInvisibleElements: 0,
            hiddenStaves: [], clefOverrides: [],
        )
    }
}

public enum LayoutOptionsCodec {
    public static func decode(_ data: Data) throws -> LayoutOptionsWire {
        try LayoutOptionsWire(decoding: data)
    }
}
