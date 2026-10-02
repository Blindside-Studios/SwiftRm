//
//  RmFileParser.swift
//  SwiftRm
//

import Foundation

public struct RmFile: Sendable {
    public let version: RmVersion
    public let layers: [RmLayer]
}

public enum RmVersion: Sendable {
    case v3, v5, v6
}

public struct RmLayer: Sendable {
    public let lines: [RmLine]
}

public struct RmLine: Sendable {
    public let brushType: UInt32
    public let brushColor: UInt32
    public let brushSize: Float32
    public let points: [RmPoint]
}

public struct RmPoint: Sendable {
    public let x: Float32
    public let y: Float32
    public let speed: Float32
    public let direction: Float32
    public let width: Float32
    public let pressure: Float32
}

public enum RmFileParser {
    public static let deviceWidth: Float = 1404
    public static let deviceHeight: Float = 1872

    private static let headerV3 = "reMarkable .lines file, version=3          "
    private static let headerV5 = "reMarkable .lines file, version=5          "
    private static let headerV6 = "reMarkable .lines file, version=6          "
    private static let headerLen = 43
    private static let headerLenV3V5 = headerLen
    private static let headerLenV6 = headerLen //44

    /*public static func parse(_ data: Data) throws -> RmFile {
        guard data.count >= headerLenV6 else {
            guard data.count >= headerLenV3V5 else { throw RmParseError.tooShort }
            return try parseV3V5(data)
        }

        let h6 = String(data: data[0..<headerLenV6], encoding: .ascii) ?? ""
        if h6 == headerV6 {
            return try parseV6(data)
        }
        return try parseV3V5(data)
    }*/
    
    public static func parse(_ data: Data) throws -> RmFile {
        guard data.count >= headerLen else { throw RmParseError.tooShort }
        let header = String(data: data[0..<headerLen], encoding: .ascii) ?? ""
        if header == headerV6 { return try parseV6(data) }
        return try parseV3V5(data)
    }

    // MARK: - v3/v5 parser

    private static func parseV3V5(_ data: Data) throws -> RmFile {
        var offset = 0
        guard data.count >= headerLenV3V5 else { throw RmParseError.tooShort }
        let header = String(data: data[0..<headerLenV3V5], encoding: .ascii) ?? ""
        offset = headerLenV3V5

        let version: RmVersion
        if header == headerV5 { version = .v5 }
        else if header == headerV3 { version = .v3 }
        else { throw RmParseError.unknownHeader }

        let layerCount = try readUInt32(data, &offset)
        var layers: [RmLayer] = []

        for _ in 0..<layerCount {
            let lineCount = try readUInt32(data, &offset)
            var lines: [RmLine] = []

            for _ in 0..<lineCount {
                let brushType = try readUInt32(data, &offset)
                let brushColor = try readUInt32(data, &offset)
                _ = try readUInt32(data, &offset)
                let brushSize = try readFloat32(data, &offset)

                if version == .v5 {
                    _ = try readFloat32(data, &offset)
                }

                let pointCount = try readUInt32(data, &offset)
                var points: [RmPoint] = []

                for _ in 0..<pointCount {
                    let x = try readFloat32(data, &offset)
                    let y = try readFloat32(data, &offset)
                    let speed = try readFloat32(data, &offset)
                    let direction = try readFloat32(data, &offset)
                    let width = try readFloat32(data, &offset)
                    let pressure = try readFloat32(data, &offset)
                    points.append(RmPoint(x: x, y: y, speed: speed, direction: direction, width: width, pressure: pressure))
                }

                lines.append(RmLine(brushType: brushType, brushColor: brushColor, brushSize: brushSize, points: points))
            }
            layers.append(RmLayer(lines: lines))
        }

        return RmFile(version: version, layers: layers)
    }

    // MARK: - v6 tagged block parser

    private static func parseV6(_ data: Data) throws -> RmFile {
        var offset = headerLenV6
        var allLines: [RmLine] = []

        while offset < data.count {
            guard offset + 8 <= data.count else { break }

            let blockLength = Int(try readUInt32(data, &offset))
            _ = try readUInt8(data, &offset) // unknown
            _ = try readUInt8(data, &offset) // min_version
            let currentVersion = try readUInt8(data, &offset)
            let blockType = try readUInt8(data, &offset)

            let blockStart = offset
            let blockEnd = blockStart + blockLength

            guard blockEnd <= data.count else { break }

            if blockType == 0x05 {
                if let line = try? parseSceneLineItemBlock(data, &offset, blockEnd: blockEnd, version: Int(currentVersion)) {
                    allLines.append(line)
                }
            }

            offset = blockEnd
        }

        return RmFile(version: .v6, layers: [RmLayer(lines: allLines)])
    }

    private static func parseSceneLineItemBlock(_ data: Data, _ offset: inout Int, blockEnd: Int, version: Int) throws -> RmLine? {
        // CRDT sequence item wrapper: tags 1-5
        try skipTag(data, &offset, blockEnd: blockEnd) // tag 1: parent_id (ID)
        try skipTag(data, &offset, blockEnd: blockEnd) // tag 2: item_id (ID)
        try skipTag(data, &offset, blockEnd: blockEnd) // tag 3: left_id (ID)
        try skipTag(data, &offset, blockEnd: blockEnd) // tag 4: right_id (ID)
        try skipTag(data, &offset, blockEnd: blockEnd) // tag 5: deleted_length (Byte4)

        guard offset < blockEnd else { return nil }

        // Check if subblock 6 exists
        let savedOffset = offset
        let tagValue = try readVarUInt(data, &offset)
        let tagIndex = tagValue >> 4
        let tagType = tagValue & 0xF

        guard tagIndex == 6 && tagType == 0xC else {
            offset = savedOffset
            return nil
        }

        let subblockLength = Int(try readUInt32(data, &offset))
        let subblockEnd = offset + subblockLength
        guard subblockEnd <= blockEnd else { return nil }

        let itemType = try readUInt8(data, &offset)
        guard itemType == 0x03 else { return nil }

        return try parseLineValue(data, &offset, blockEnd: subblockEnd, version: version)
    }

    private static func parseLineValue(_ data: Data, _ offset: inout Int, blockEnd: Int, version: Int) throws -> RmLine {
        // tag 1: tool_id (Byte4)
        _ = try readTaggedVarUInt(data, &offset)
        let toolId = try readUInt32(data, &offset)

        // tag 2: color_id (Byte4)
        _ = try readTaggedVarUInt(data, &offset)
        let colorId = try readUInt32(data, &offset)

        // tag 3: thickness_scale (Byte8)
        _ = try readTaggedVarUInt(data, &offset)
        let thicknessScale = try readFloat64(data, &offset)

        // tag 4: starting_length (Byte4)
        _ = try readTaggedVarUInt(data, &offset)
        _ = try readFloat32(data, &offset)

        // tag 5: points subblock (Length4)
        _ = try readTaggedVarUInt(data, &offset)
        let pointsLength = Int(try readUInt32(data, &offset))
        let pointsEnd = offset + pointsLength

        guard pointsEnd <= blockEnd else { throw RmParseError.tooShort }

        let pointSize = version >= 2 ? 14 : 24
        let numPoints = pointsLength / pointSize
        var points: [RmPoint] = []

        for _ in 0..<numPoints {
            let x = try readFloat32(data, &offset) + deviceWidth / 2
            let y = try readFloat32(data, &offset)

            let speed: Float32
            let direction: Float32
            let width: Float32
            let pressure: Float32

            if version >= 2 {
                speed = Float32(try readUInt16(data, &offset))
                width = Float32(try readUInt16(data, &offset))
                direction = Float32(try readUInt8(data, &offset))
                pressure = Float32(try readUInt8(data, &offset))
            } else {
                speed = (try readFloat32(data, &offset)) * 4
                direction = 255 * (try readFloat32(data, &offset)) / (Float32.pi * 2)
                width = (try readFloat32(data, &offset)) * 4
                pressure = (try readFloat32(data, &offset)) * 255
            }

            points.append(RmPoint(x: x, y: y, speed: speed, direction: direction, width: width, pressure: pressure))
        }

        offset = pointsEnd

        let brushSize = Float32(thicknessScale)
        return RmLine(brushType: toolId, brushColor: colorId, brushSize: brushSize, points: points)
    }

    // MARK: - Tag helpers

    private static func skipTag(_ data: Data, _ offset: inout Int, blockEnd: Int) throws {
        guard offset < blockEnd else { throw RmParseError.tooShort }

        let tagValue = try readVarUInt(data, &offset)
        let tagType = tagValue & 0xF

        switch tagType {
        case 0x1: // Byte1
            offset += 1
        case 0x4: // Byte4
            offset += 4
        case 0x8: // Byte8
            offset += 8
        case 0xC: // Length4 (subblock)
            let length = Int(try readUInt32(data, &offset))
            offset += length
        case 0xF: // ID (CrdtId = uint8 + varuint)
            offset += 1
            _ = try readVarUInt(data, &offset)
        default:
            throw RmParseError.unknownHeader
        }
    }

    private static func readTaggedVarUInt(_ data: Data, _ offset: inout Int) throws -> UInt {
        return try readVarUInt(data, &offset)
    }

    private static func readVarUInt(_ data: Data, _ offset: inout Int) throws -> UInt {
        var shift: UInt = 0
        var result: UInt = 0
        while true {
            guard offset < data.count else { throw RmParseError.tooShort }
            let byte = data[offset]
            offset += 1
            result |= UInt(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 { break }
        }
        return result
    }

    // MARK: - Primitive readers

    private static func readUInt8(_ data: Data, _ offset: inout Int) throws -> UInt8 {
        guard offset + 1 <= data.count else { throw RmParseError.tooShort }
        let value = data[offset]
        offset += 1
        return value
    }

    private static func readUInt16(_ data: Data, _ offset: inout Int) throws -> UInt16 {
        guard offset + 2 <= data.count else { throw RmParseError.tooShort }
        let value = data[offset..<offset+2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        offset += 2
        return UInt16(littleEndian: value)
    }

    private static func readUInt32(_ data: Data, _ offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw RmParseError.tooShort }
        let value = data[offset..<offset+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: value)
    }

    private static func readFloat32(_ data: Data, _ offset: inout Int) throws -> Float32 {
        guard offset + 4 <= data.count else { throw RmParseError.tooShort }
        let bits = data[offset..<offset+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        offset += 4
        return Float32(bitPattern: UInt32(littleEndian: bits))
    }

    private static func readFloat64(_ data: Data, _ offset: inout Int) throws -> Float64 {
        guard offset + 8 <= data.count else { throw RmParseError.tooShort }
        let bits = data[offset..<offset+8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        offset += 8
        return Float64(bitPattern: UInt64(littleEndian: bits))
    }
}

public enum RmParseError: Error, LocalizedError {
    case tooShort
    case unknownHeader

    public var errorDescription: String? {
        switch self {
        case .tooShort: "Unexpected end of .rm data"
        case .unknownHeader: "Unknown .rm file header"
        }
    }
}
