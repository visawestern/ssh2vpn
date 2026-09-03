import Foundation

public enum IPPacketError: Error, Equatable {
    case empty
    case unsupportedVersion
    case invalidHeaderLength
    case truncated
    case invalidTotalLength
    case unsupportedProtocol
}

public enum IPTransport: UInt8, Sendable {
    case tcp = 6
    case udp = 17
}

public struct IPv4Flow: Hashable, Sendable {
    public let sourceAddress: UInt32
    public let sourcePort: UInt16
    public let destinationAddress: UInt32
    public let destinationPort: UInt16
    public let transport: IPTransport

    public init(sourceAddress: UInt32, sourcePort: UInt16, destinationAddress: UInt32, destinationPort: UInt16, transport: IPTransport) {
        self.sourceAddress = sourceAddress
        self.sourcePort = sourcePort
        self.destinationAddress = destinationAddress
        self.destinationPort = destinationPort
        self.transport = transport
    }

    /// Raw address bytes (network order) for use as flow keys.
    public var sourceAddressBytes: [UInt8] {
        [UInt8(sourceAddress >> 24), UInt8((sourceAddress >> 16) & 0xFF),
         UInt8((sourceAddress >> 8) & 0xFF), UInt8(sourceAddress & 0xFF)]
    }

    public var destinationAddressBytes: [UInt8] {
        [UInt8(destinationAddress >> 24), UInt8((destinationAddress >> 16) & 0xFF),
         UInt8((destinationAddress >> 8) & 0xFF), UInt8(destinationAddress & 0xFF)]
    }
}

public struct ParsedIPv4Packet: Sendable {
    public let flow: IPv4Flow
    public let header: Data
    public let payload: Data

    public init(flow: IPv4Flow, header: Data, payload: Data) {
        self.flow = flow
        self.header = header
        self.payload = payload
    }
}

public enum IPv4Parser {
    public static func parse(_ packet: Data) throws -> ParsedIPv4Packet {
        guard packet.count >= 20 else { throw IPPacketError.empty }
        let version = packet[0] >> 4
        guard version == 4 else { throw IPPacketError.unsupportedVersion }
        let headerLength = Int(packet[0] & 0x0f) * 4
        guard headerLength >= 20 else { throw IPPacketError.invalidHeaderLength }
        guard packet.count >= headerLength else { throw IPPacketError.truncated }
        let totalLength = Int(readUInt16(packet, at: 2))
        guard totalLength >= headerLength, totalLength <= packet.count else { throw IPPacketError.invalidTotalLength }
        guard let transport = IPTransport(rawValue: packet[9]) else { throw IPPacketError.unsupportedProtocol }

        let transportOffset = headerLength
        let transportHeaderLength = transport == .tcp ? 20 : 8
        guard totalLength >= transportOffset + transportHeaderLength else { throw IPPacketError.truncated }
        let sourcePort = readUInt16(packet, at: transportOffset)
        let destinationPort = readUInt16(packet, at: transportOffset + 2)
        let sourceAddress = readUInt32(packet, at: 12)
        let destinationAddress = readUInt32(packet, at: 16)
        let flow = IPv4Flow(sourceAddress: sourceAddress, sourcePort: sourcePort, destinationAddress: destinationAddress, destinationPort: destinationPort, transport: transport)
        let payloadOffset = transport == .tcp ? transportOffset + Int((packet[transportOffset + 12] >> 4) & 0x0f) * 4 : transportOffset + 8
        guard payloadOffset >= transportOffset + transportHeaderLength, payloadOffset <= totalLength else { throw IPPacketError.invalidHeaderLength }
        return ParsedIPv4Packet(flow: flow, header: Data(packet.prefix(payloadOffset)), payload: Data(packet[payloadOffset..<totalLength]))
    }

    private static func readUInt16(_ data: Data, at index: Int) -> UInt16 {
        (UInt16(data[index]) << 8) | UInt16(data[index + 1])
    }

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        (UInt32(data[index]) << 24) | (UInt32(data[index + 1]) << 16) | (UInt32(data[index + 2]) << 8) | UInt32(data[index + 3])
    }
}
