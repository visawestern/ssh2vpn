import Foundation
import NIOCore

// MARK: - IPv4 packet wrapper

public struct IPv4Packet: Sendable {
    public let bytes: [UInt8]
    public init(_ bytes: [UInt8]) { self.bytes = bytes }
}

// MARK: - Relay channel abstraction

public protocol RelayChannel: AnyObject {
    func send(_ data: Data)
    func close()
}

public protocol RelayChannelFactory: AnyObject {
    func open(flow: RelayFlow, onData: @escaping (Data) -> Void, onClosed: @escaping () -> Void) -> RelayChannel
}

public protocol ISNGenerator: Sendable {
    func next() -> UInt32
}

// MARK: - State machine

public enum RelayFlowState: Sendable {
    case synReceived
    case established
    case closing
    case closed
}

public struct TCPRelayStateMachine {
    public var factory: RelayChannelFactory
    public var isnGenerator: ISNGenerator
    public var idleTimeout: TimeInterval
    /// Transport-level sinks, set once by the owner. Invoked from channel
    /// callbacks (arbitrary threads); the owner hops onto its serial queue.
    public var onChannelData: ((RelayFlow, Data) -> Void)?
    public var onChannelClose: ((RelayFlow) -> Void)?

    private var flows: [RelayFlow: FlowState] = [:]

    private struct FlowState {
        var channel: RelayChannel
        var state: RelayFlowState
        var lastActivity: Date
        var isn: UInt32
        var peerSeq: UInt32
        var localSeq: UInt32
        var localAck: UInt32
        /// Server bytes that arrived before the phone's ACK; flushed on
        /// handshake completion so nothing is lost to the race.
        var pendingToPhone: [Data] = []
    }

    public init(factory: RelayChannelFactory, isnGenerator: ISNGenerator, idleTimeout: TimeInterval = 60) {
        self.factory = factory
        self.isnGenerator = isnGenerator
        self.idleTimeout = idleTimeout
    }

    /// Live flow census for status reporting (replaces placeholder counts).
    public var flowCount: Int { flows.count }

    public func state(for flow: IPv4Flow) -> RelayFlowState? {
        let key = RelayFlow(srcAddr: flow.sourceAddressBytes, srcPort: flow.sourcePort,
                            dstAddr: flow.destinationAddressBytes, dstPort: flow.destinationPort, transport: .tcp)
        return flows[key]?.state
    }

    public mutating func handle(packet: IPv4Packet) throws -> [[UInt8]] {
        let parsed = try IPv4Parser.parse(Data(packet.bytes))
        guard parsed.flow.transport == .tcp else { return [] }
        // TCP segment starts after the IP header (may include options, so use
        // the actual header length from the IP version/IHL byte — never assume 20).
        let ipHeaderLen = Int(packet.bytes[0] & 0x0F) * 4
        let totalLength = Int(UInt16(packet.bytes[2]) << 8 | UInt16(packet.bytes[3]))
        guard ipHeaderLen >= 20, totalLength >= ipHeaderLen, packet.bytes.count >= totalLength else { return [] }
        let tcpSegment = Data(packet.bytes[ipHeaderLen..<totalLength])
        let seg = try TCPParser.parse(tcpSegment)
        let flow = parsed.flow

        let key = RelayFlow(srcAddr: flow.sourceAddressBytes, srcPort: flow.sourcePort,
                            dstAddr: flow.destinationAddressBytes, dstPort: flow.destinationPort, transport: .tcp)

        if seg.flags.contains(.rst) {
            if var st = flows[key] {
                st.channel.close()
                st.state = .closed
                flows[key] = st
            }
            return []
        }

        if var st = flows[key] {
            st.lastActivity = Date()
            switch st.state {
            case .synReceived:
                if seg.flags.contains(.ack) && !seg.flags.contains(.syn) {
                    st.state = .established
                    st.peerSeq = seg.seq
                    // Flush anything the server sent before the handshake
                    // finished (fast servers beat the phone's ACK).
                    var out = [[UInt8]]()
                    for chunk in st.pendingToPhone {
                        if let pkt = try? TCPReplyBuilder.data(flow: key, seq: st.localSeq, ack: st.peerSeq, payload: Array(chunk)) {
                            out.append(pkt)
                            st.localSeq += UInt32(chunk.count)
                        }
                    }
                    st.pendingToPhone.removeAll()
                    flows[key] = st
                    return out
                } else if seg.flags.contains(.syn) {
                    // Duplicate SYN: resend SYN-ACK (client may have missed it)
                    flows[key] = st
                    return [try TCPReplyBuilder.synAck(flow: key.reversed, isn: st.isn, peerSeq: seg.seq)]
                }
            case .established:
                if seg.flags.contains(.fin) {
                    st.state = .closing
                    st.channel.close()
                    flows[key] = st
                    return [try TCPReplyBuilder.data(flow: key.reversed, seq: st.localSeq, ack: st.peerSeq + 1, payload: [])]
                }
                if !seg.payload.isEmpty {
                    st.channel.send(seg.payload)
                    st.peerSeq = seg.seq + UInt32(seg.payload.count)
                }
            case .closing, .closed:
                break
            }
            flows[key] = st
            return []
        }

        guard seg.flags.contains(.syn) else { return [] }

        let isn = isnGenerator.next()
        let onData = onChannelData
        let onClose = onChannelClose
        let channel = factory.open(flow: key,
                                   onData: { data in onData?(key, data) },
                                   onClosed: { onClose?(key) })
        let st = FlowState(channel: channel, state: .synReceived, lastActivity: Date(),
                           isn: isn, peerSeq: seg.seq, localSeq: isn + 1, localAck: seg.seq + 1)
        flows[key] = st

        return [try TCPReplyBuilder.synAck(flow: key.reversed, isn: isn, peerSeq: seg.seq)]
    }

    // MARK: - server-to-phone splice

    /// Feeds bytes received on a channel back toward the phone as data
    /// packet(s). Unknown flows are dropped; pre-handshake bytes are buffered
    /// and flushed when the phone's ACK completes the handshake.
    public mutating func channelData(_ data: Data, for flow: RelayFlow) -> [[UInt8]] {
        guard var st = flows[flow] else { return [] }
        st.lastActivity = Date()
        switch st.state {
        case .established:
            guard let pkt = try? TCPReplyBuilder.data(flow: flow, seq: st.localSeq, ack: st.peerSeq, payload: Array(data)) else {
                flows[flow] = st
                return []
            }
            st.localSeq += UInt32(data.count)
            flows[flow] = st
            return [pkt]
        case .synReceived:
            st.pendingToPhone.append(data)
            flows[flow] = st
            return []
        case .closing, .closed:
            return []
        }
    }

    /// The channel died: send FIN to the phone so its stack closes promptly
    /// instead of hanging until retransmit timeouts.
    public mutating func channelClosed(flow: RelayFlow) -> [[UInt8]] {
        guard var st = flows[flow], st.state != .closed else { return [] }
        st.state = .closing
        st.lastActivity = Date()
        flows[flow] = st
        guard let pkt = try? TCPReplyBuilder.fin(flow: flow, seq: st.localSeq, ack: st.peerSeq) else { return [] }
        st.localSeq += 1
        flows[flow] = st
        return [pkt]
    }

    public mutating func expireIdle() -> Int {
        var expired = 0
        let now = Date()
        for (key, var st) in flows {
            if now.timeIntervalSince(st.lastActivity) > idleTimeout && st.state != .closed {
                st.channel.close()
                st.state = .closed
                flows[key] = st
                expired += 1
            }
        }
        return expired
    }
}
