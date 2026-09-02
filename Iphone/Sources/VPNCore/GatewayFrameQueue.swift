import Foundation

/// Queue-admission decision (Chapter 5, p.96).
public enum FrameQueueDecision: Sendable {
    case accept
    case backpressure
}

/// Bounded frame queue (Chapter 5, p.96).
///
/// Limits the pending packet queue by both packet count and byte size so a
/// stalled handshake cannot grow memory forever. Pure logic: the transport layer
/// owns the actual array; this owns the admission decision and accounting.
public struct GatewayFrameQueue: Sendable {
    public struct Limits: Sendable {
        public let maxPackets: Int
        public let maxBytes: Int

        public static let `default` = Limits(maxPackets: 512, maxBytes: 256 * 1024)

        public init(maxPackets: Int, maxBytes: Int) {
            self.maxPackets = max(0, maxPackets)
            self.maxBytes = max(0, maxBytes)
        }
    }

    public let limits: Limits
    public private(set) var count: Int
    public private(set) var bytes: Int

    public init(limits: Limits, count: Int = 0, bytes: Int = 0) {
        self.limits = limits
        self.count = max(0, count)
        self.bytes = max(0, bytes)
    }

    /// Whether a packet of `packetSize` bytes can be admitted.
    public func accept(packetSize: Int) -> FrameQueueDecision {
        guard packetSize >= 0 else { return .backpressure }
        if count >= limits.maxPackets { return .backpressure }
        if bytes + packetSize > limits.maxBytes { return .backpressure }
        return .accept
    }

    /// Records an admitted packet.
    public mutating func enqueue(packetSize: Int) {
        count += 1
        bytes += max(0, packetSize)
    }

    /// Records a sent/dropped packet.
    public mutating func dequeue(packetSize: Int) {
        count = max(0, count - 1)
        bytes = max(0, bytes - max(0, packetSize))
    }
}
