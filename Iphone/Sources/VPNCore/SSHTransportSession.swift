import NIOCore
import NIOSSH

/// A single SSH session carrying our framed protocol over stdin/stdout of the
/// remote gateway process. The session intentionally has no listener and no
/// destination-forwarding semantics.
public final class SSHTransportSession: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = TransportFrame

    private let channel: Channel
    private let receive: (TransportFrame) -> Void
    private let failure: (Error) -> Void
    private var didFail = false

    public init(
        channel: Channel,
        receive: @escaping (TransportFrame) -> Void,
        failure: @escaping (Error) -> Void
    ) {
        self.channel = channel
        self.receive = receive
        self.failure = failure
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        receive(unwrapInboundIn(data))
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        fail(SSHTransportSessionError.closed)
        context.fireChannelInactive()
    }

    public func send(_ frame: TransportFrame, completion: @escaping (Error?) -> Void = { _ in }) {
        let write = {
            self.channel.writeAndFlush(frame).whenComplete { result in
                switch result {
                case .success: completion(nil)
                case .failure(let error):
                    self.fail(error)
                    completion(error)
                }
            }
        }
        if channel.eventLoop.inEventLoop {
            write()
        } else {
            channel.eventLoop.execute(write)
        }
    }

    public func close() {
        channel.close(promise: nil)
    }

    public var isActive: Bool { channel.isActive }

    private func fail(_ error: Error) {
        guard !didFail else { return }
        didFail = true
        failure(error)
    }
}

public enum SSHTransportSessionError: Error, Equatable {
    case closed
}
