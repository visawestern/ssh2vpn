import Foundation

public enum FlowTransport: UInt8, Sendable {
    case tcp = 1
    case udp = 2
}

public struct FlowOpen: Equatable, Sendable {
    public let transport: FlowTransport
    public let host: String
    public let port: UInt16

    public init(transport: FlowTransport, host: String, port: UInt16) throws {
        guard !host.isEmpty, host.utf8.count <= UInt16.max else { throw FlowOpenError.invalidHost }
        guard port > 0 else { throw FlowOpenError.invalidPort }
        self.transport = transport
        self.host = host
        self.port = port
    }

    public func encoded() -> Data {
        let hostBytes = Data(host.utf8)
        var output = Data([transport.rawValue, UInt8(hostBytes.count >> 8), UInt8(hostBytes.count & 0xff)])
        output.append(hostBytes)
        output.append(UInt8(port >> 8))
        output.append(UInt8(port & 0xff))
        return output
    }

    public static func decode(_ data: Data) throws -> FlowOpen {
        guard data.count >= 5 else { throw FlowOpenError.truncated }
        guard let transport = FlowTransport(rawValue: data[0]) else { throw FlowOpenError.unsupportedTransport }
        let hostLength = (Int(data[1]) << 8) | Int(data[2])
        guard hostLength > 0, data.count == hostLength + 5 else { throw FlowOpenError.invalidHost }
        guard let host = String(data: data[3..<(3 + hostLength)], encoding: .utf8) else { throw FlowOpenError.invalidHost }
        let portIndex = 3 + hostLength
        let port = (UInt16(data[portIndex]) << 8) | UInt16(data[portIndex + 1])
        return try FlowOpen(transport: transport, host: host, port: port)
    }
}

public enum FlowOpenError: Error, Equatable {
    case truncated
    case unsupportedTransport
    case invalidHost
    case invalidPort
}
