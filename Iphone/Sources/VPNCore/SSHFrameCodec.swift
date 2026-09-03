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
            // The server talked outside the framed protocol — almost always
            // stderr output (e.g. a gateway.py traceback). Carry a preview so
            // the app dump shows WHAT it said, not just that data arrived.
            let preview = ChannelDataPreview.text(of: channelData)
            context.fireErrorCaught(SSHFrameCodecError.unexpectedChannelData(kind: "\(channelData.type)", preview: preview))
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

public enum SSHFrameCodecError: Error, Equatable {
    /// Server sent channel data outside the framed protocol (usually stderr,
    /// e.g. a gateway.py traceback). `preview` carries the first bytes so the
    /// app dump shows what was actually said.
    case unexpectedChannelData(kind: String, preview: String)
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
        let n = min(limit, total)
        guard let bytes = buffer.readBytes(length: n), !bytes.isEmpty else { return "<empty>" }
        let truncated = total > n
        if let text = String(bytes: bytes, encoding: .utf8) {
            return truncated ? text + "…" : text
        }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
