import Foundation

public enum FrameType: UInt8, Sendable {
    case open = 1
    case data = 2
    case fin = 3
    case reset = 4
    case close = 5
    case ping = 6
    case pong = 7
    /// Raw IP packet mode used by the system-wide packet tunnel.
    case packet = 8
    case hello = 9
    case helloAck = 10
}

public struct TransportFrame: Equatable, Sendable {
    public static let protocolVersion: UInt8 = 1
    public static let headerSize = 16
    public static let maxPayloadSize = 1_048_576

    public let type: FrameType
    public let streamID: UInt64
    public let payload: Data

    public init(type: FrameType, streamID: UInt64 = 0, payload: Data = Data()) throws {
        guard payload.count <= Self.maxPayloadSize else { throw FrameError.payloadTooLarge }
        self.type = type
        self.streamID = streamID
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data([Self.protocolVersion, type.rawValue, 0, 0])
        data.append(contentsOf: withBigEndian(streamID))
        data.append(contentsOf: withBigEndian(UInt32(payload.count)))
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> TransportFrame {
        guard data.count >= headerSize else { throw FrameError.incomplete }
        guard data[0] == protocolVersion else { throw FrameError.unsupportedVersion }
        guard let type = FrameType(rawValue: data[1]) else { throw FrameError.unknownType }
        guard data[2] == 0, data[3] == 0 else { throw FrameError.nonZeroReservedBits }
        let streamID = data[4..<12].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let length = data[12..<16].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= maxPayloadSize else { throw FrameError.payloadTooLarge }
        guard data.count == headerSize + Int(length) else { throw FrameError.incomplete }
        return try TransportFrame(type: type, streamID: streamID, payload: data.subdata(in: headerSize..<data.count))
    }

    private func withBigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

public enum FrameError: Error, Equatable {
    case incomplete
    case unsupportedVersion
    case unknownType
    case payloadTooLarge
    case nonZeroReservedBits
}

/// Decodes frames from arbitrary SSH read boundaries. SSH reads are not frame
/// aligned, so this type must tolerate half a header, half a payload, and many
/// frames in one read.
public struct TransportFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [TransportFrame] {
        buffer.append(bytes)
        var frames: [TransportFrame] = []

        while true {
            guard buffer.count >= TransportFrame.headerSize else { break }
            guard buffer[0] == TransportFrame.protocolVersion else { throw FrameError.unsupportedVersion }
            guard FrameType(rawValue: buffer[1]) != nil else { throw FrameError.unknownType }
            guard buffer[2] == 0, buffer[3] == 0 else { throw FrameError.nonZeroReservedBits }
            let length = buffer[12..<16].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= TransportFrame.maxPayloadSize else { throw FrameError.payloadTooLarge }
            let frameSize = TransportFrame.headerSize + Int(length)
            guard buffer.count >= frameSize else { break }
            let frameData = buffer.prefix(frameSize)
            frames.append(try TransportFrame.decode(Data(frameData)))
            // Re-materialize the remainder so its collection indices always
            // start at zero after consuming a frame.
            buffer = Data(buffer.dropFirst(frameSize))
        }
        return frames
    }

    public var bufferedByteCount: Int { buffer.count }
}
