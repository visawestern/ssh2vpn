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
    case closing      // server sent FIN or channel closed — phone→server half-closed
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

    /// Per-flow TCP endpoint state.  Naming mirrors RFC 793:
    ///   peerSeq  = RCV.NXT  (next byte expected from phone)
    ///   localSeq = SND.NXT  (next byte we'll send to phone)
    ///   localUna = SND.UNA  (oldest unacknowledged byte)
    private struct FlowState {
        var channel: RelayChannel
        var state: RelayFlowState
        var lastActivity: Date
        var isn: UInt32

        // --- Phone → relay (RCV side) ---
        /// Next contiguous byte we expect from the phone.
        var peerSeq: UInt32
        /// Receive window the phone advertised (raw, before scaling).
        var peerRawWindow: UInt16 = 65535
        /// Window scale factor from phone's SYN (0..14).
        var peerWindowScale: UInt8 = 0

        // --- Relay → phone (SND side) ---
        /// Next byte we will send toward the phone.
        var localSeq: UInt32
        /// Last byte the phone has ACKed toward us (SND.UNA).
        var localAck: UInt32
        /// Our receive window advertised to the phone.
        let localWindow: UInt32 = 1_048_576  // 1 MiB — large enough for benchmarking
        /// Our window scale factor (we advertise this in SYN-ACK).
        let localWindowScale: UInt8 = 7      // 128 → 1 MiB window

        /// Bytes sent to phone but not yet ACKed by phone.  Tracked for
        /// backpressure: we stop sending when this reaches peerWindow.
        var outstandingToPhone: UInt32 = 0

        // --- Half-close tracking ---
        /// Phone sent FIN → phone won't send more data.
        var phoneFinSeen = false
        /// We sent FIN to phone → we won't send more data.
        var localFinSent = false

        // --- Server bytes buffer (pre-handshake) ---
        var pendingToPhone: [Data] = []

        // --- Byte counters ---
        var upBytes: Int = 0
        var downBytes: Int = 0
        var loggedFirstUp = false
        var loggedFirstDown = false

        /// Effective receive window the phone advertised (after scaling).
        var effectivePeerWindow: UInt32 {
            UInt32(peerRawWindow) << peerWindowScale
        }

        /// Available space in the phone's receive window.
        var availablePeerWindow: UInt32 {
            let window = effectivePeerWindow
            return window > outstandingToPhone ? window - outstandingToPhone : 0
        }
    }

    /// Per-flow byte census for status reporting and close/sweep logging.
    public struct RelayFlowStats: Sendable {
        public var flow: RelayFlow
        public var state: RelayFlowState
        public var upBytes: Int
        public var downBytes: Int
    }

    public func flowStats() -> [RelayFlowStats] {
        flows.map { RelayFlowStats(flow: $0.key, state: $0.value.state, upBytes: $0.value.upBytes, downBytes: $0.value.downBytes) }
    }

    private static func describe(_ flow: RelayFlow) -> String {
        let s = flow.srcAddr.map(String.init).joined(separator: ".")
        let d = flow.dstAddr.map(String.init).joined(separator: ".")
        return "\(s):\(flow.srcPort) -> \(d):\(flow.dstPort)"
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

    // MARK: - Main entry point

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

        // RST: tear down immediately, no questions asked.
        if seg.flags.contains(.rst) {
            if var st = flows[key] {
                st.channel.close()
                st.state = .closed
                flows[key] = st
            }
            return []
        }

        // --- Existing flow ---
        if var st = flows[key] {
            st.lastActivity = Date()

            // New incarnation on a live/dead record (port reuse after close):
            // close the old channel and start over — staying dead is worse
            // than the tiny risk of clobbering a simultaneous-open edge.
            if seg.flags.contains(.syn) && st.state != .synReceived {
                st.channel.close()
                let isn = isnGenerator.next()
                let onData = onChannelData
                let onClose = onChannelClose
                let channel = factory.open(flow: key,
                                           onData: { data in onData?(key, data) },
                                           onClosed: { onClose?(key) })
                var fresh = FlowState(channel: channel, state: .synReceived, lastActivity: Date(),
                                      isn: isn, peerSeq: seg.seq, localSeq: isn + 1, localAck: seg.seq &+ 1)
                fresh.peerWindowScale = seg.options.windowScale
                fresh.peerRawWindow = seg.window
                flows[key] = fresh
                ConsoleLogStore.shared.log(level: .info, tag: "RELAY", message: "flow \(Self.describe(key)) new SYN on \(st.state), reopening")
                return [try TCPReplyBuilder.synAck(flow: key.reversed, isn: isn, peerSeq: seg.seq,
                                                   windowScale: fresh.localWindowScale)]
            }

            switch st.state {
            case .synReceived:
                let result = handleSynReceived(&st, key: key, seg: seg)
                flows[key] = st
                return result
            case .established:
                let result = handleEstablished(&st, key: key, seg: seg)
                flows[key] = st
                return result
            case .closing, .closed:
                break
            }
            flows[key] = st
            return []
        }

        // --- No record for this flow ---
        if seg.flags.contains(.rst) {
            // Nothing to tear down; answering RST with RST would loop forever.
            return []
        }
        if seg.flags.contains(.syn) {
            let isn = isnGenerator.next()
            let onData = onChannelData
            let onClose = onChannelClose
            let channel = factory.open(flow: key,
                                       onData: { data in onData?(key, data) },
                                       onClosed: { onClose?(key) })
            var st = FlowState(channel: channel, state: .synReceived, lastActivity: Date(),
                               isn: isn, peerSeq: seg.seq, localSeq: isn + 1, localAck: seg.seq &+ 1)
            st.peerWindowScale = seg.options.windowScale
            st.peerRawWindow = seg.window
            flows[key] = st

            return [try TCPReplyBuilder.synAck(flow: key.reversed, isn: isn, peerSeq: seg.seq,
                                               windowScale: st.localWindowScale)]
        }
        // Anything else on an unknown flow (stray data/ACK after we expired
        // it, app restart, etc.): refuse fast with RST so the phone fails
        // over instead of hanging until its own timeout. RFC 793 §3.4: with
        // ACK set the RST carries their ack as seq, otherwise it acks past
        // their data.
        let (rseq, rack): (UInt32, UInt32) = seg.flags.contains(.ack)
            ? (seg.ack, 0)
            : (0, seg.seq &+ UInt32(seg.payload.count))
        return [try TCPReplyBuilder.rst(flow: key.reversed, seq: rseq, ack: rack)]
    }

    // MARK: - SYN-RECEIVED handler

    private mutating func handleSynReceived(_ st: inout FlowState, key: RelayFlow, seg: ParsedTCPSegment) -> [[UInt8]] {
        if seg.flags.contains(.ack) && !seg.flags.contains(.syn) {
            st.state = .established
            st.peerSeq = seg.seq
            // Flush anything the server sent before the handshake
            // finished (fast servers beat the phone's ACK).
            var out = [[UInt8]]()
            for chunk in st.pendingToPhone {
                out.append(contentsOf: spliceToPhone(chunk, flow: key, state: &st))
            }
            st.pendingToPhone.removeAll()
            return out
        } else if seg.flags.contains(.syn) {
            // Duplicate SYN: resend SYN-ACK (client may have missed it)
            if let pkt = try? TCPReplyBuilder.synAck(flow: key.reversed, isn: st.isn, peerSeq: seg.seq) {
                return [pkt]
            }
        }
        return []
    }

    // MARK: - ESTABLISHED handler (the core)

    /// Returns reply packets for a segment arriving in ESTABLISHED state.
    private mutating func handleEstablished(_ st: inout FlowState, key: RelayFlow, seg: ParsedTCPSegment) -> [[UInt8]] {
        var replies = [[UInt8]]()

        // --- Update phone's advertised window from every segment ---
        st.peerRawWindow = seg.window

        // --- Process phone's ACK of our data (advances SND.UNA) ---
        if seg.flags.contains(.ack) {
            let newUna = seg.ack
            if TCPSequence.greaterThan(newUna, st.localAck) {
                let acked = TCPSequence.distance(from: st.localAck, to: newUna)
                st.outstandingToPhone = acked > 0 && st.outstandingToPhone >= UInt32(acked)
                    ? st.outstandingToPhone - UInt32(acked) : 0
                st.localAck = newUna
                // Window may have opened up — flush any buffered server data.
                replies.append(contentsOf: flushPendingToPhone(&st, flow: key))
            }
        }

        // --- FIN handling (may coexist with payload) ---
        // FIN occupies one sequence number AFTER the payload.
        if seg.flags.contains(.fin) {
            // Process any payload first (before the FIN's seq).
            if !seg.payload.isEmpty {
                let outcome = forwardPhoneData(&st, key: key, seg: seg)
                if case .forwarded = outcome {
                    // Data was new — ACK it as part of the FIN ACK below.
                }
            }
            // ACK the FIN (+ any payload).  FIN consumes 1 extra seq number.
            let finAck = seg.seq &+ UInt32(seg.payload.count) &+ 1
            st.peerSeq = finAck
            st.phoneFinSeen = true
            st.state = .closing
            st.channel.close()
            if let pkt = try? TCPReplyBuilder.data(flow: key.reversed, seq: st.localSeq, ack: st.peerSeq, payload: []) {
                replies.append(pkt)
            }
            return replies
        }

        // --- Pure ACK (no data) ---
        if seg.payload.isEmpty {
            return []
        }

        // --- Data segment ---
        let outcome = forwardPhoneData(&st, key: key, seg: seg)
        switch outcome {
        case .forwarded:
            // New contiguous data was forwarded.  ACK it immediately so
            // the phone's TCP stack doesn't retransmit.
            if let pkt = try? TCPReplyBuilder.data(flow: key.reversed, seq: st.localSeq, ack: st.peerSeq, payload: []) {
                replies.append(pkt)
            }
        case .acked(let ackPkts):
            // Duplicate/out-of-order — the ACK was already generated.
            replies.append(contentsOf: ackPkts)
        }

        return replies
    }

    // MARK: - Phone data forwarding (with duplicate/partial/ooo detection)

    enum ReceiveOutcome {
        /// New contiguous data was forwarded.  Caller should ACK.
        case forwarded
        /// Duplicate/out-of-order — ACK already included.
        case acked([[UInt8]])
    }

    /// Inspects incoming phone data against peerSeq and decides what to
    /// forward to the SSH channel.
    private mutating func forwardPhoneData(_ st: inout FlowState, key: RelayFlow, seg: ParsedTCPSegment) -> ReceiveOutcome {
        let segStart = seg.seq
        let segEnd = seg.seq &+ UInt32(seg.payload.count)

        // Distance from expected to segment start.
        let dist = TCPSequence.distance(from: st.peerSeq, to: segStart)
        let payloadCount = seg.payload.count

        if dist == 0 {
            // Normal case: starts at expected position.
            st.channel.send(seg.payload)
            st.peerSeq = segEnd
            st.upBytes += payloadCount
            if !st.loggedFirstUp {
                st.loggedFirstUp = true
                ConsoleLogStore.shared.log(level: .info, tag: "RELAY", message: "flow \(Self.describe(key)) up: first \(payloadCount)B")
            }
            return .forwarded

        } else if dist > 0 {
            // Gap: segment starts PAST expected.  Out-of-order.
            ConsoleLogStore.shared.log(level: .info, tag: "RELAY",
                message: "flow \(Self.describe(key)) out-of-order: expected \(st.peerSeq) got \(segStart) (gap \(dist))")

        } else {
            // Segment starts BEFORE expected (duplicate or partial overlap).
            let overlap = st.peerSeq &- segStart

            if overlap >= UInt32(payloadCount) {
                // Entire segment is duplicate — nothing new.
                ConsoleLogStore.shared.log(level: .info, tag: "RELAY",
                    message: "flow \(Self.describe(key)) duplicate: seq \(segStart) fully before peerSeq \(st.peerSeq)")
            } else {
                // Partial overlap: trim the duplicate prefix, forward the new suffix.
                let newStart = Int(overlap)
                let newData = seg.payload.subdata(in: newStart..<payloadCount)
                ConsoleLogStore.shared.log(level: .info, tag: "RELAY",
                    message: "flow \(Self.describe(key)) partial overlap: trimming \(newStart)B, forwarding \(newData.count)B")
                st.channel.send(newData)
                st.peerSeq = segEnd
                st.upBytes += newData.count
                if !st.loggedFirstUp {
                    st.loggedFirstUp = true
                    ConsoleLogStore.shared.log(level: .info, tag: "RELAY", message: "flow \(Self.describe(key)) up: first \(newData.count)B")
                }
            }
        }

        // For duplicate/out-of-order/partial, emit an ACK with current peerSeq.
        if let pkt = try? TCPReplyBuilder.data(flow: key.reversed, seq: st.localSeq, ack: st.peerSeq, payload: []) {
            return .acked([pkt])
        }
        return .acked([])
    }

    // MARK: - ACK validation

    /// Checks that the phone's ACK falls within our valid send window.
    /// Logs and drops the segment if invalid (does not RST — the phone
    /// may just be stale or retransmitting an old ACK).
    private func validateACK(st: FlowState, seg: ParsedTCPSegment) {
        // ACK must be in [localAck, localSeq] — i.e., [SND.UNA, SND.NXT].
        // Because we are the server-side sender and localAck tracks the
        // phone's last ACK of our data, valid range is localAck..localSeq.
        //
        // But our localAck is not yet fully maintained (we don't track phone
        // ACKs of our server→phone data in detail).  For now, accept any
        // ACK that doesn't go backwards.  A full implementation would check:
        //   SND.UNA <= ACK <= SND.NXT
        //
        // For robustness we just ensure ACK doesn't exceed localSeq (our
        // highest sent byte + 1) and isn't wildly in the future.
        if TCPSequence.greaterThan(seg.ack, st.localSeq) {
            ConsoleLogStore.shared.log(level: .warning, tag: "RELAY",
                message: "ACK \(seg.ack) ahead of localSeq \(st.localSeq) — stale or future ACK, ignoring")
        }
    }

    // MARK: - server-to-phone splice

    /// Feeds bytes received on a channel back toward the phone as data
    /// packet(s). Unknown flows are dropped; pre-handshake bytes are buffered
    /// and flushed when the phone's ACK completes the handshake.
    public mutating func channelData(_ data: Data, for flow: RelayFlow) -> [[UInt8]] {
        guard var st = flows[flow] else { return [] }
        st.lastActivity = Date()
        var out = [[UInt8]]()
        switch st.state {
        case .established:
            out = spliceToPhone(data, flow: flow, state: &st)
        case .closing:
            if !st.localFinSent {
                out = spliceToPhone(data, flow: flow, state: &st)
            }
        case .synReceived:
            st.pendingToPhone.append(data)
        case .closed:
            break
        }
        flows[flow] = st
        return out
    }

    /// Builds a data packet toward the phone, advancing our sequence numbers
    /// and byte counters. Single choke point for all server->phone splicing.
    /// Respects the phone's advertised receive window — if the window is
    /// full, data is buffered in `pendingToPhone` instead of being sent.
    private mutating func spliceToPhone(_ data: Data, flow: RelayFlow, state: inout FlowState) -> [[UInt8]] {
        // If the phone's window is full, buffer for later delivery.
        if state.availablePeerWindow == 0 && !data.isEmpty {
            state.pendingToPhone.append(data)
            if !state.loggedFirstDown {
                state.loggedFirstDown = true
                ConsoleLogStore.shared.log(level: .info, tag: "RELAY",
                    message: "flow \(Self.describe(flow)) down: first \(data.count)B (window full, buffered)")
            }
            return []
        }

        // Clamp to available window if needed.
        let available = state.availablePeerWindow
        let toSend: Data
        let remainder: Data
        if available > 0 && UInt32(data.count) > available {
            let clamped = Int(available)
            toSend = data.prefix(clamped)
            remainder = data.suffix(from: clamped)
        } else {
            toSend = data
            remainder = Data()
        }

        guard !toSend.isEmpty else { return [] }

        guard let pkt = try? TCPReplyBuilder.data(flow: flow, seq: state.localSeq, ack: state.peerSeq, payload: Array(toSend)) else {
            return []
        }
        state.localSeq += UInt32(toSend.count)
        state.outstandingToPhone += UInt32(toSend.count)
        state.downBytes += toSend.count
        if !state.loggedFirstDown {
            state.loggedFirstDown = true
            ConsoleLogStore.shared.log(level: .info, tag: "RELAY", message: "flow \(Self.describe(flow)) down: first \(toSend.count)B")
        }

        // Buffer anything that didn't fit in the current window.
        if !remainder.isEmpty {
            state.pendingToPhone.append(remainder)
        }

        return [pkt]
    }

    /// Flushes pending server→phone data when the phone ACKs some of our
    /// outstanding data, freeing window space.
    private mutating func flushPendingToPhone(_ st: inout FlowState, flow: RelayFlow) -> [[UInt8]] {
        guard !st.pendingToPhone.isEmpty, st.availablePeerWindow > 0 else { return [] }
        var out = [[UInt8]]()
        // Concatenate all pending into one buffer for simplicity.
        var pending = Data()
        for chunk in st.pendingToPhone { pending.append(chunk) }
        st.pendingToPhone.removeAll()
        out.append(contentsOf: spliceToPhone(pending, flow: flow, state: &st))
        return out
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
        st.localFinSent = true
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
                ConsoleLogStore.shared.log(level: .info, tag: "RELAY",
                    message: "flow \(Self.describe(key)) expired idle (up=\(st.upBytes)B down=\(st.downBytes)B)")
            }
        }
        return expired
    }
}
