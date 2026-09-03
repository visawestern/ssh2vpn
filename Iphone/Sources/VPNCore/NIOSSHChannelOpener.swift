import Foundation
import NIOCore
import NIOSSH

/// Production SSHChannelOpener that wraps an NIOSSHHandler and opens
/// direct-tcpip channels for relay flows.
public final class NIOSSHChannelOpener: SSHChannelOpener {
    private let handler: NIOSSHHandler
    private let eventLoop: EventLoop

    public init(handler: NIOSSHHandler, eventLoop: EventLoop) {
        self.handler = handler
        self.eventLoop = eventLoop
    }

    public func open(targetHost: String, targetPort: Int, originatorAddress: SocketAddress,
                     onData: @escaping (Data) -> Void, onClosed: @escaping () -> Void) -> RelayChannel? {
        let wrapper = SSHRelayChannelWrapper(onData: onData, onClosed: onClosed)
        let type = SSHChannelType.directTCPIP(.init(targetHost: targetHost, targetPort: targetPort,
                                                     originatorAddress: originatorAddress))
        // Attach the wrapper to the channel as it opens. The wrapper buffers
        // sends until the channel is actually established.
        handler.createChannel(nil, channelType: type) { childChannel, _ in
            childChannel.pipeline.addHandler(wrapper)
        }
        return wrapper
    }
}
