import Foundation
import NIOCore
import NIOSSH

/// Bridges our framed protocol to an authenticated SSH child channel. The
/// codec owns no socket and never creates forwarding listeners.
public final class SSHFrameCodec: ChannelDuplexHandler, @unchecked Sendable {
    public typealias InboundIn = SSHChannelData
    public typealias InboundOut = TransportFrame
    public typealias OutboundIn = TransportFrame
    public typealias OutboundOut = SSHChannelData

    private var decoder = TransportFrameDecoder()

    public init() {}

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel, case .byteBuffer(var buffer) = channelData.data else {
            // Drain, don't kill: the server sometimes talks outside the framed
            // protocol (stderr warnings, degraded modes). Killing the session
            // on any such bytes turned warnings into tunnel failures. The
            // preview still reaches the app dump for diagnosis, and a truly
            // dead gateway is caught by channel close + heartbeat timeouts.
            let preview = ChannelDataPreview.text(of: channelData)
            ConsoleLogStore.shared.log(level: .warning, tag: "SESSION", message: "drained \(channelData.type): \(preview)")
            return
        }

        do {
            let bytes = buffer.readData(length: buffer.readableBytes) ?? Data()
            for frame in try decoder.append(bytes) {
                context.fireChannelRead(wrapInboundOut(frame))
            }
        } catch {
            context.fireErrorCaught(error)
            context.close(promise: nil)
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = unwrapOutboundIn(data)
        var buffer = context.channel.allocator.buffer(capacity: TransportFrame.headerSize + frame.payload.count)
        buffer.writeBytes(frame.encoded())
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

/// Renders unexpected SSH channel payloads for diagnostics. Pure function —
/// fully unit-testable without a channel pipeline.
public enum ChannelDataPreview {
    public static func text(of data: SSHChannelData, limit: Int = 300) -> String {
        guard case .byteBuffer(var buffer) = data.data else {
            return "<non-buffer payload>"
        }
        let total = buffer.readableBytes
        guard total > 0 else { return "<empty>" }
        guard let bytes = buffer.readBytes(length: total), !bytes.isEmpty else { return "<empty>" }
        if total <= limit {
            return String(bytes: bytes, encoding: .utf8) ?? hex(bytes)
        }
        // Tracebacks diagnose by head (context) and tail (the exception).
        let headCount = limit / 3
        let tailCount = limit - headCount
        let head = Array(bytes.prefix(headCount))
        let tail = Array(bytes.suffix(tailCount))
        let marker = "\n…[truncated \(total - limit) bytes]…\n"
        let headText = String(bytes: head, encoding: .utf8) ?? hex(head)
        let tailText = String(bytes: tail, encoding: .utf8) ?? hex(tail)
        return headText + marker + tailText
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
