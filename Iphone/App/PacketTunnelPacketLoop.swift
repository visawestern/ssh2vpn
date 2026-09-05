import Foundation
import NetworkExtension

protocol PacketTunnelTransport: AnyObject {
    func start(receive: @escaping (Data) -> Void, failure: @escaping (Error) -> Void, ready: @escaping (Error?) -> Void)
    func send(packet: Data, completion: @escaping (Error?) -> Void)
    func stop()
}

/// Owns only the NetworkExtension packetFlow lifecycle. Framing, SSH, and
/// gateway behavior stay behind PacketTunnelTransport so they can be tested
/// independently from Apple's extension process.
final class PacketTunnelPacketLoop: @unchecked Sendable {
    private let packetFlow: NEPacketTunnelFlow
    private let transport: PacketTunnelTransport
    private var isRunning = false
    private var isSuspended = false
    private var onReady: ((Error?) -> Void)?
    /// Diagnostic counters: packets read from utun (iOS routed them to us)
    /// vs written back to utun (replies). Plain Ints on purpose — aligned
    /// access is practically atomic and these are read-only diagnostics.
    private(set) var packetsRead = 0
    private(set) var packetsWritten = 0
    /// Per-protocol received split (diagnostic only): proves WHAT iOS feeds
    /// us — e.g. v6-arrives-but-v4-doesn't means the v4 default route lost.
    /// Counted pre-transport, so drops inside the relay can't skew it.
    private(set) var v4tcp = 0
    private(set) var v4udp = 0
    private(set) var v4other = 0
    private(set) var v6 = 0
    private(set) var nonIP = 0
    /// "v4tcp=N v4udp=M v6=K ..." snapshot for status reporting.
    var protoSummary: String {
        "v4tcp=\(v4tcp) v4udp=\(v4udp) v4other=\(v4other) v6=\(v6) nonIP=\(nonIP)"
    }
    /// Last time a non-empty batch arrived from utun. The stall watchdog
    /// (app side) uses this to tell "user idle" apart from "iOS stopped
    /// feeding the tunnel": the minutely ping guarantees traffic, so a
    /// frozen timestamp across cycles means a dead packet flow.
    private(set) var lastReadAt: Date?

    init(packetFlow: NEPacketTunnelFlow, transport: PacketTunnelTransport) {
        self.packetFlow = packetFlow
        self.transport = transport
    }

    func start(ready: @escaping (Error?) -> Void = { _ in }) {
        guard !isRunning else { return }
        isRunning = true
        isSuspended = false
        onReady = ready
        transport.start(
            receive: { [weak self] packet in
                guard let self, self.isRunning else { return }
                self.packetsWritten += 1
                let protocolNumber = packet.first.map { ($0 >> 4) == 6 ? AF_INET6 : AF_INET } ?? AF_INET
                self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: protocolNumber)])
            },
            failure: { [weak self] _ in self?.stop() },
            ready: { [weak self] error in
                if error != nil { self?.stop() }
                self?.onReady?(error)
            }
        )
        readNextBatch()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        transport.stop()
    }

    func suspend() { isSuspended = true }

    func resume() {
        if !isRunning {
            // The transport died while the device slept; rebuild it instead of
            // leaving the tunnel up but dead.
            start()
        } else {
            isSuspended = false
            readNextBatch()
        }
    }

    /// Cheap L3/L4 classifier for the diagnostic split (bounds-checked;
    /// never throws — a malformed packet just lands in nonIP/v4other).
    private func countProtocol(_ packet: Data) {
        guard packet.count >= 20 else { nonIP += 1; return }
        let version = packet[0] >> 4
        if version == 4 {
            guard packet.count >= 20 else { v4other += 1; return }
            switch packet[9] {
            case 6: v4tcp += 1
            case 17: v4udp += 1
            default: v4other += 1
            }
        } else if version == 6 {
            v6 += 1
        } else {
            nonIP += 1
        }
    }

    private func readNextBatch() {        guard isRunning, !isSuspended else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.isRunning, !self.isSuspended else { return }
            self.packetsRead += packets.count
            if !packets.isEmpty { self.lastReadAt = Date() }
            for packet in packets { self.countProtocol(packet) }
            for packet in packets {
                self.transport.send(packet: packet) { _ in
                    // Transient send failures (backpressure while the gateway
                    // is still starting, an interim session hiccup) must not
                    // tear the whole tunnel down. Fatal failures arrive via
                    // the transport's `failure` callback instead.
                }
            }
            self.readNextBatch()
        }
    }
}