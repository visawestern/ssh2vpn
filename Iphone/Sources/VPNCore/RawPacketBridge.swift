import Foundation

public enum RawPacketBridgeError: Error, Equatable {
    case wrongFrameType
    case nonZeroStreamID
    case emptyPacket
    case packetTooLarge
}

/// Pure protocol boundary used by Network Extension and the SSH transport.
/// Keeping it free of NetworkExtension makes packet semantics fully testable on
/// macOS before a device run.
public enum RawPacketBridge {
    public static let maxPacketSize = 65_535

    public static func outboundFrame(for packet: Data) throws -> TransportFrame {
        guard !packet.isEmpty else { throw RawPacketBridgeError.emptyPacket }
        guard packet.count <= maxPacketSize else { throw RawPacketBridgeError.packetTooLarge }
        return try TransportFrame(type: .packet, streamID: 0, payload: packet)
    }

    public static func inboundPacket(from frame: TransportFrame) throws -> Data {
        guard frame.type == .packet else { throw RawPacketBridgeError.wrongFrameType }
        guard frame.streamID == 0 else { throw RawPacketBridgeError.nonZeroStreamID }
        guard !frame.payload.isEmpty else { throw RawPacketBridgeError.emptyPacket }
        return frame.payload
    }
}
