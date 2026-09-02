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

    private func readNextBatch() {
        guard isRunning, !isSuspended else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.isRunning, !self.isSuspended else { return }
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