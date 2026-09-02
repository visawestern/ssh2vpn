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
            context.fireErrorCaught(SSHFrameCodecError.unexpectedChannelData)
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
    case unexpectedChannelData
}
