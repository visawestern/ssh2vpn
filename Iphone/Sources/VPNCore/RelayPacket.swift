import Foundation

// MARK: - TCP flags

public struct TCPFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let fin = TCPFlags(rawValue: 0x01)
    public static let syn = TCPFlags(rawValue: 0x02)
    public static let rst = TCPFlags(rawValue: 0x04)
    public static let psh = TCPFlags(rawValue: 0x08)
    public static let ack = TCPFlags(rawValue: 0x10)
}

// MARK: - Parsed segments

public struct ParsedTCPSegment: Sendable {
    public var seq: UInt32
    public var ack: UInt32
    public var flags: TCPFlags
    public var window: UInt16
    public var payload: Data
    /// TCP options parsed from the header (only populated when needed).
    public var options: TCPOptions
}

/// Parsed TCP options from a segment.  Zero values mean "not present".
public struct TCPOptions: Sendable {
    public var mss: UInt16 = 0
    public var windowScale: UInt8 = 0
    public var sackPermitted: Bool = false
}

public enum TCPParser {
    public static func parse(_ data: Data) throws -> ParsedTCPSegment {
        guard data.count >= 20 else { throw IPPacketError.truncated }
        let dataOffset = Int((data[12] >> 4) & 0x0F) * 4
        guard dataOffset >= 20, data.count >= dataOffset else { throw IPPacketError.invalidHeaderLength }
        let options = parseOptions(Data(data[20..<dataOffset]))
        return ParsedTCPSegment(
            seq: u32(data, 4),
            ack: u32(data, 8),
            flags: TCPFlags(rawValue: data[13]),
            window: u16(data, 14),
            payload: Data(data[dataOffset...]),
            options: options
        )
    }

    /// Parses TCP options from the bytes between the fixed 20-byte header
    /// and the start of payload.  Options are a sequence of TLV tuples:
    ///   kind (1B) | length (1B, includes kind+length) | value (length-2 B)
    static func parseOptions(_ data: Data) -> TCPOptions {
        var opts = TCPOptions()
        var i = data.startIndex
        while i < data.endIndex {
            let kind = data[i]
            if kind == 0 { break }       // EOL
            if kind == 1 { i += 1; continue }  // NOP
            guard i + 1 < data.endIndex else { break }
            let len = Int(data[i + 1])
            guard len >= 2, i + len <= data.endIndex else { break }
            switch kind {
            case 2: // MSS
                if len == 4, i + 4 <= data.endIndex {
                    opts.mss = u16(data, i + 2)
                }
            case 3: // Window Scale
                if len == 3, i + 3 <= data.endIndex {
                    opts.windowScale = data[i + 2]
                }
            case 4: // SACK Permitted
                opts.sackPermitted = true
            default:
                break
            }
            i += len
        }
        return opts
    }

    static func u16(_ d: Data, _ i: Int) -> UInt16 { (UInt16(d[i]) << 8) | UInt16(d[i + 1]) }

    static func u32(_ d: Data, _ i: Int) -> UInt32 {
        (UInt32(d[i]) << 24) | (UInt32(d[i + 1]) << 16) | (UInt32(d[i + 2]) << 8) | UInt32(d[i + 3])
    }
}

public struct ParsedUDPDatagram: Sendable {
    public var length: Int
    public var payload: Data
}

public enum UDPParser {
    public static func parse(_ data: Data) throws -> ParsedUDPDatagram {
        guard data.count >= 8 else { throw IPPacketError.truncated }
        let length = Int(TCPParser.u16(data, 4))
        guard length >= 8, data.count >= length else { throw IPPacketError.truncated }
        return ParsedUDPDatagram(length: length, payload: Data(data[8..<length]))
    }
}

// MARK: - Relay flow identity

/// A transport flow as seen on utun, keyed by raw address bytes (4 for IPv4,
/// 16 for IPv6, network order) so no string conversion can corrupt identity.
public struct RelayFlow: Hashable, Sendable {
    public var srcAddr: [UInt8]
    public var srcPort: UInt16
    public var dstAddr: [UInt8]
    public var dstPort: UInt16
    public var transport: IPTransport

    public init(srcAddr: [UInt8], srcPort: UInt16, dstAddr: [UInt8], dstPort: UInt16, transport: IPTransport) {
        self.srcAddr = srcAddr
        self.srcPort = srcPort
        self.dstAddr = dstAddr
        self.dstPort = dstPort
        self.transport = transport
    }

    public var isV6: Bool { srcAddr.count == 16 }

    /// Reversed direction (server -> phone) for crafting replies.
    public var reversed: RelayFlow {
        RelayFlow(srcAddr: dstAddr, srcPort: dstPort, dstAddr: srcAddr, dstPort: srcPort, transport: transport)
    }
}

public struct ParsedIPv6Packet: Sendable {
    public let flow: RelayFlow
    public let header: Data
    public let payload: Data
}

public enum IPv6Parser {
    public static func parse(_ packet: Data) throws -> ParsedIPv6Packet {
        guard packet.count >= 40 else { throw IPPacketError.truncated }
        guard packet[0] >> 4 == 6 else { throw IPPacketError.unsupportedVersion }
        let payloadLength = Int(TCPParser.u16(packet, 4))
        guard let transport = IPTransport(rawValue: packet[6]) else { throw IPPacketError.unsupportedProtocol }
        let srcAddr = Array(packet[8..<24])
        let dstAddr = Array(packet[24..<40])
        let total = 40 + payloadLength
        guard packet.count >= total else { throw IPPacketError.truncated }
        if transport == .tcp {
            guard total >= 60 else { throw IPPacketError.truncated }
            let dataOffset = Int((packet[52] >> 4) & 0x0F) * 4
            guard dataOffset >= 20, 40 + dataOffset <= total else { throw IPPacketError.invalidHeaderLength }
            let flow = RelayFlow(
                srcAddr: srcAddr, srcPort: TCPParser.u16(packet, 40),
                dstAddr: dstAddr, dstPort: TCPParser.u16(packet, 42), transport: .tcp)
            return ParsedIPv6Packet(flow: flow, header: Data(packet.prefix(40 + dataOffset)), payload: Data(packet[(40 + dataOffset)..<total]))
        } else {
            guard total >= 48 else { throw IPPacketError.truncated }
            let flow = RelayFlow(
                srcAddr: srcAddr, srcPort: TCPParser.u16(packet, 40),
                dstAddr: dstAddr, dstPort: TCPParser.u16(packet, 42), transport: .udp)
            return ParsedIPv6Packet(flow: flow, header: Data(packet.prefix(48)), payload: Data(packet[48..<total]))
        }
    }
}

// MARK: - Checksums (RFC 1071 ones-complement)

public enum Checksum {
    static func fold(_ total: UInt32) -> UInt16 {
        var t = total
        while t >> 16 != 0 { t = (t & 0xFFFF) + (t >> 16) }
        return ~UInt16(t)
    }

    static func words(_ bytes: [UInt8]) -> UInt32 {
        var total: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            total += (UInt32(bytes[i]) << 8) | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { total += UInt32(bytes[i]) << 8 }
        return total
    }

    /// Checksum of an IP header whose checksum field is zeroed.
    public static func ipHeader(_ header: [UInt8]) -> UInt16 {
        fold(words(header))
    }

    /// Transport checksum over the segment (checksum field zeroed) plus the
    /// pseudo-header derived from the endpoint addresses. `proto` is 6 (TCP)
    /// or 17 (UDP); address family is inferred from length (4 = v4, 16 = v6).
    public static func transport(segment: [UInt8], srcAddr: [UInt8], dstAddr: [UInt8], proto: UInt8) -> UInt16 {
        var pseudo: [UInt8]
        if srcAddr.count == 4 {
            let len = segment.count
            pseudo = srcAddr + dstAddr + [0, proto,
                UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
        } else {
            let len = segment.count
            pseudo = srcAddr + dstAddr + [
                UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF),
                UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF),
                0, 0, 0, proto]
        }
        return fold(words(pseudo) + words(segment))
    }

    /// TCP checksum over the segment (checksum field zeroed) plus the
    /// pseudo-header derived from the endpoint addresses.
    public static func tcp(segment: [UInt8], srcAddr: [UInt8], dstAddr: [UInt8]) -> UInt16 {
        transport(segment: segment, srcAddr: srcAddr, dstAddr: dstAddr, proto: 6)
    }

    /// True when a received full IPv4 packet's header checksum is valid.
    public static func isValidIPv4Packet(_ packet: [UInt8]) -> Bool {
        guard packet.count >= 20, packet[0] >> 4 == 4 else { return false }
        let ihl = Int(packet[0] & 0x0F) * 4
        guard ihl >= 20, packet.count >= ihl else { return false }
        return ipHeader(Array(packet[0..<ihl])) == 0
    }

    /// True when a received full IP packet's UDP checksum verifies. A stored
    /// zero means "no checksum" (legal for IPv4) and is accepted.
    public static func isValidUDPDatagram(packet: [UInt8]) -> Bool {
        guard packet.count >= 20, packet[0] >> 4 == 4 else { return false }
        let ihl = Int(packet[0] & 0x0F) * 4
        let total = Int(UInt16(packet[2]) << 8 | UInt16(packet[3]))
        guard ihl >= 20, total >= ihl + 8, packet.count >= total, packet[9] == 17 else { return false }
        let dgram = Array(packet[ihl..<total])
        guard dgram.count >= 8 else { return false }
        let stored = UInt16(dgram[6]) << 8 | UInt16(dgram[7])
        if stored == 0 { return true }
        return transport(segment: dgram, srcAddr: Array(packet[12..<16]), dstAddr: Array(packet[16..<20]), proto: 17) == 0
    }

    /// True when a received full IP packet's TCP checksum (including the
    /// stored value) verifies. Supports v4 and v6.
    public static func isValidTCPSegment(packet: [UInt8]) -> Bool {
        guard !packet.isEmpty else { return false }
        if packet[0] >> 4 == 4 {
            guard packet.count >= 20 else { return false }
            let ihl = Int(packet[0] & 0x0F) * 4
            let total = Int(UInt16(packet[2]) << 8 | UInt16(packet[3]))
            guard total >= ihl, packet.count >= total, packet[9] == 6 else { return false }
            let seg = Array(packet[ihl..<total])
            let src = Array(packet[12..<16])
            let dst = Array(packet[16..<20])
            return tcp(segment: seg, srcAddr: src, dstAddr: dst) == 0
        } else if packet[0] >> 4 == 6 {
            guard packet.count >= 40 else { return false }
            let len = Int(UInt16(packet[4]) << 8 | UInt16(packet[5]))
            guard packet[6] == 6, packet.count >= 40 + len else { return false }
            let seg = Array(packet[40..<(40 + len)])
            return tcp(segment: seg, srcAddr: Array(packet[8..<24]), dstAddr: Array(packet[24..<40])) == 0
        }
        return false
    }
}

// MARK: - Reply builders (server -> phone direction)

/// Callers always pass the flow in the PHONE -> SERVER direction (as read
/// from utun); `build` reverses it internally. Passing an already-reversed
/// flow double-reverses it: the "reply" then carries phone->server address
/// pairs and iOS drops it on the floor (observed on-device as SYN storms
/// and a total egress blackhole while utun counters kept climbing).
public enum TCPReplyBuilder {
    /// SYN-ACK answering a SYN: acknowledges peerSeq+1 (SYN consumes one).
    public static func synAck(flow: RelayFlow, isn: UInt32, peerSeq: UInt32,
                              mss: UInt16 = 1400, windowScale: UInt8 = 0,
                              identification: UInt16 = 0) throws -> [UInt8] {
        try build(flow: flow, seq: isn, ack: peerSeq &+ 1, flags: [.syn, .ack],
                  payload: [], window: 65535, identification: identification,
                  mss: mss, windowScale: windowScale)
    }

    /// RST with explicit sequence/ack numbers supplied by the relay, which
    /// owns the flow state and knows what is in window.
    public static func rst(flow: RelayFlow, seq: UInt32, ack: UInt32, identification: UInt16 = 0) throws -> [UInt8] {
        try build(flow: flow, seq: seq, ack: ack, flags: [.rst, .ack],
                  payload: [], window: 0, identification: identification, mss: nil, windowScale: nil)
    }

    /// FIN closing our side toward the phone (server side went away).
    public static func fin(flow: RelayFlow, seq: UInt32, ack: UInt32, identification: UInt16 = 0) throws -> [UInt8] {
        try build(flow: flow, seq: seq, ack: ack, flags: [.fin, .ack],
                  payload: [], window: 65535, identification: identification, mss: nil, windowScale: nil)
    }

    /// Data segment (ACK set, PSH when carrying payload).
    public static func data(flow: RelayFlow, seq: UInt32, ack: UInt32, payload: [UInt8],
                            window: UInt16 = 65535, identification: UInt16 = 0) throws -> [UInt8] {
        var flags: TCPFlags = [.ack]
        if !payload.isEmpty { flags.insert(.psh) }
        return try build(flow: flow, seq: seq, ack: ack, flags: flags,
                         payload: payload, window: window, identification: identification,
                         mss: nil, windowScale: nil)
    }

    private static func build(flow: RelayFlow, seq: UInt32, ack: UInt32, flags: TCPFlags,
                              payload: [UInt8], window: UInt16, identification: UInt16,
                              mss: UInt16?, windowScale: UInt8?) throws -> [UInt8] {
        let r = flow.reversed
        guard r.srcAddr.count == r.dstAddr.count, (r.srcAddr.count == 4 || r.srcAddr.count == 16) else {
            throw IPPacketError.invalidHeaderLength
        }
        // --- TCP options ---
        var opts = [UInt8]()
        if let mss {
            opts += [2, 4, UInt8(mss >> 8), UInt8(mss & 0xFF)]   // MSS (kind=2, len=4)
        }
        if let ws = windowScale, ws > 0 {
            opts += [3, 3, ws]                                     // Window Scale (kind=3, len=3)
        }
        let headerWords: UInt8 = UInt8((20 + opts.count + 3) / 4)

        // --- TCP segment (checksum zeroed for now) ---
        var seg = [UInt8](repeating: 0, count: 20)
        seg[0] = UInt8(r.srcPort >> 8); seg[1] = UInt8(r.srcPort & 0xFF)
        seg[2] = UInt8(r.dstPort >> 8); seg[3] = UInt8(r.dstPort & 0xFF)
        seg[4] = UInt8(seq >> 24); seg[5] = UInt8((seq >> 16) & 0xFF)
        seg[6] = UInt8((seq >> 8) & 0xFF); seg[7] = UInt8(seq & 0xFF)
        seg[8] = UInt8(ack >> 24); seg[9] = UInt8((ack >> 16) & 0xFF)
        seg[10] = UInt8((ack >> 8) & 0xFF); seg[11] = UInt8(ack & 0xFF)
        seg += opts
        // Pad to 4-byte boundary if needed.
        while seg.count % 4 != 0 { seg.append(0) }
        seg[12] = headerWords << 4
        seg[13] = flags.rawValue
        seg[14] = UInt8(window >> 8); seg[15] = UInt8(window & 0xFF)
        let csum = Checksum.tcp(segment: seg + payload, srcAddr: r.srcAddr, dstAddr: r.dstAddr)
        seg[16] = UInt8(csum >> 8); seg[17] = UInt8(csum & 0xFF)
        let segment = seg + payload

        // --- IP header ---
        if !r.isV6 {
            var ip = [UInt8](repeating: 0, count: 20)
            ip[0] = 0x45
            let total = 20 + segment.count
            ip[2] = UInt8(total >> 8); ip[3] = UInt8(total & 0xFF)
            ip[4] = UInt8(identification >> 8); ip[5] = UInt8(identification & 0xFF)
            ip[8] = 64
            ip[9] = 6
            ip[12..<16] = r.srcAddr[0..<4]
            ip[16..<20] = r.dstAddr[0..<4]
            let c = Checksum.ipHeader(ip)
            ip[10] = UInt8(c >> 8); ip[11] = UInt8(c & 0xFF)
            return ip + segment
        } else {
            var ip = [UInt8](repeating: 0, count: 40)
            ip[0] = 0x60
            ip[4] = UInt8(segment.count >> 8); ip[5] = UInt8(segment.count & 0xFF)
            ip[6] = 6
            ip[7] = 64
            ip[8..<24] = r.srcAddr[0..<16]
            ip[24..<40] = r.dstAddr[0..<16]
            return ip + segment
        }
    }
}

// MARK: - UDP reply builder (server -> phone direction)

/// Builds IPv4/UDP replies (used for relayed DNS answers). v4 only for now —
/// v6 DNS goes through the same path once v6 relay exists.
public enum UDPReplyBuilder {
    public static func reply(flow: RelayFlow, payload: [UInt8], identification: UInt16 = 0) throws -> [UInt8] {
        let r = flow.reversed
        guard !r.isV6, r.srcAddr.count == 4, r.dstAddr.count == 4 else {
            throw IPPacketError.invalidHeaderLength
        }
        // --- UDP datagram (checksum zeroed for now) ---
        var dgram = [UInt8](repeating: 0, count: 8)
        dgram[0] = UInt8(r.srcPort >> 8); dgram[1] = UInt8(r.srcPort & 0xFF)
        dgram[2] = UInt8(r.dstPort >> 8); dgram[3] = UInt8(r.dstPort & 0xFF)
        let udpLen = 8 + payload.count
        dgram[4] = UInt8(udpLen >> 8); dgram[5] = UInt8(udpLen & 0xFF)
        var csum = Checksum.transport(segment: dgram + payload, srcAddr: r.srcAddr, dstAddr: r.dstAddr, proto: 17)
        if csum == 0 { csum = 0xFFFF } // zero means "absent" — never send that
        dgram[6] = UInt8(csum >> 8); dgram[7] = UInt8(csum & 0xFF)
        let datagram = dgram + payload

        // --- IPv4 header ---
        var ip = [UInt8](repeating: 0, count: 20)
        ip[0] = 0x45
        let total = 20 + datagram.count
        ip[2] = UInt8(total >> 8); ip[3] = UInt8(total & 0xFF)
        ip[4] = UInt8(identification >> 8); ip[5] = UInt8(identification & 0xFF)
        ip[8] = 64
        ip[9] = 17
        ip[12..<16] = r.srcAddr[0..<4]
        ip[16..<20] = r.dstAddr[0..<4]
        let c = Checksum.ipHeader(ip)
        ip[10] = UInt8(c >> 8); ip[11] = UInt8(c & 0xFF)
        return ip + datagram
    }
}

// MARK: - DNS multiplexer (many phone queries, one upstream TCP connection)

/// Multiplexes concurrent phone DNS queries over a single upstream TCP
/// connection to port 53. Responses are routed back to the originating flows
/// by DNS query ID (several flows may share one ID — all get the answer).
/// Pure bytes in/out; the transport owns the actual channel.
public struct DNSRelay: Sendable {
    public var upstreamHost: String
    public var upstreamPort: Int
    private var idToFlows: [UInt16: [RelayFlow]] = [:]
    private var buffer = Data()

    public init(upstreamHost: String, upstreamPort: Int = 53) {
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
    }

    /// Registers a query; returns the length-prefixed bytes to send upstream,
    /// or nil when the query is malformed (shorter than a DNS header).
    public mutating func query(_ query: Data, from flow: RelayFlow) -> Data? {
        guard query.count >= 12 else { return nil }
        let id = UInt16(query[0]) << 8 | UInt16(query[1])
        idToFlows[id, default: []].append(flow)
        return DNSOverTCP.encode(query)
    }

    /// Feeds upstream TCP bytes; returns (flow, response) pairs ready to
    /// answer. Unknown IDs are dropped; partial messages stay buffered.
    public mutating func receive(_ bytes: Data) -> [(RelayFlow, Data)] {
        buffer.append(bytes)
        let (messages, rest) = DNSOverTCP.decode(buffer)
        buffer = rest
        var out: [(RelayFlow, Data)] = []
        for m in messages {
            guard m.count >= 2 else { continue }
            let id = UInt16(m[0]) << 8 | UInt16(m[1])
            if let flows = idToFlows.removeValue(forKey: id) {
                for f in flows { out.append((f, m)) }
            }
        }
        return out
    }
}

// MARK: - DNS-over-TCP codec

public enum DNSOverTCP {
    /// Length-prefixes a query for a TCP nameserver.
    public static func encode(_ query: Data) -> Data {
        var out = Data(capacity: query.count + 2)
        out.append(UInt8(query.count >> 8))
        out.append(UInt8(query.count & 0xFF))
        out.append(query)
        return out
    }

    /// Splits a stream into complete messages, keeping the trailing partial
    /// bytes as remainder for the next read.
    public static func decode(_ stream: Data) -> (messages: [Data], remainder: Data) {
        var messages = [Data]()
        var offset = 0
        while offset + 2 <= stream.count {
            let length = Int(stream[offset]) << 8 | Int(stream[offset + 1])
            guard stream.count >= offset + 2 + length else { break }
            messages.append(Data(stream[(offset + 2)..<(offset + 2 + length)]))
            offset += 2 + length
        }
        // Slicing exactly at end-of-data traps on some Data layouts, so copy.
        let remainder = offset < stream.count ? Data(stream[offset...]) : Data()
        return (messages, remainder)
    }
}
