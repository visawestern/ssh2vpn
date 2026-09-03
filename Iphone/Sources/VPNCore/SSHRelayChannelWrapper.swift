import Foundation
import NIOCore
import NIOSSH

public final class SSHRelayChannelWrapper: RelayChannel, ChannelInboundHandler {
    public typealias InboundIn = SSHChannelData
    public typealias OutboundOut = SSHChannelData

    public var onData: ((Data) -> Void)?
    public var onClosed: (() -> Void)?

    private var channel: Channel?
    private var pendingSends = [Data]()
    private var isAttached = false

    public init(onData: ((Data) -> Void)? = nil, onClosed: (() -> Void)? = nil) {
        self.onData = onData
        self.onClosed = onClosed
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        isAttached = true
        ConsoleLogStore.shared.log(level: .info, tag: "RELAY", message: "direct-tcpip channel attached (ready for splice)")
        context.channel.closeFuture.whenComplete { [weak self] _ in
            self?.onClosed?()
        }
        for data in pendingSends {
            var buf = context.channel.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            context.channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buf)), promise: nil)
        }
        pendingSends.removeAll()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel, case .byteBuffer(var buffer) = channelData.data else { return }
        if let bytes = buffer.readData(length: buffer.readableBytes), !bytes.isEmpty {
            onData?(bytes)
        }
        context.fireChannelRead(data)
    }

    public func send(_ data: Data) {
        if isAttached, let channel {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
        } else {
            pendingSends.append(data)
        }
    }

    public func close() {
        // Never block: fire-and-forget close. A .wait() here would stall the
        // caller (often the packet path or a state-machine tick).
        channel?.close(mode: .all, promise: nil)
    }
}
