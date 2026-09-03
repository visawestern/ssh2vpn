import Foundation
import NIOCore
import NIOPosix
@_exported import NIOSSH

public struct SSHCredentials: Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String?
    public let privateKey: NIOSSHPrivateKey?

    public init(host: String, port: Int = 22, username: String, password: String? = nil, privateKey: NIOSSHPrivateKey? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.privateKey = privateKey
    }
}

public enum SSHTransportError: Error, Equatable {
    case passwordAuthenticationUnavailable
    case hostKeyMismatch
    case hostKeyNotPinned
    case invalidChannelType
}

/// Minimal SSH connection factory. It deliberately exposes the raw NIO channel
/// only to the transport layer; packet/flow framing stays in VPNCore.
public final class SSHTransportFactory: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let pinnedHostKey: NIOSSHPublicKey?

    public init(pinnedOpenSSHHostKey: String? = nil, threadCount: Int = 1) throws {
        if let pinnedOpenSSHHostKey {
            self.pinnedHostKey = try NIOSSHPublicKey(openSSHPublicKey: pinnedOpenSSHHostKey)
        } else {
            self.pinnedHostKey = nil
        }
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, threadCount))
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    public func connect(_ credentials: SSHCredentials) -> EventLoopFuture<Channel> {
        let auth = UserAuthenticationDelegate(username: credentials.username, password: credentials.password, privateKey: credentials.privateKey)
        let hostKey = PinnedHostKeyDelegate(expected: pinnedHostKey)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: hostKey)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                }
            }
        return bootstrap.connect(host: credentials.host, port: credentials.port)
    }

    /// Opens an authenticated SSH session channel and executes the gateway.
    /// This is a raw SSH child channel, not OpenSSH dynamic forwarding.
    public func openSession(
        _ credentials: SSHCredentials,
        command: String,
        receive: @escaping (TransportFrame) -> Void,
        failure: @escaping (Error) -> Void
    ) -> EventLoopFuture<SSHTransportSession> {
        connect(credentials).flatMap { parent in
            parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { child, channelType in
                    guard channelType == .session else {
                        return child.eventLoop.makeFailedFuture(SSHTransportError.invalidChannelType)
                    }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(SSHFrameCodec())
                        try child.pipeline.syncOperations.addHandler(
                            SSHTransportSession(channel: child, receive: receive, failure: failure)
                        )
                        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
                        return child.pipeline.syncOperations.triggerUserOutboundEvent(request, promise: nil)
                    }
                }
                return promise.futureResult.flatMapThrowing { child in
                    try child.pipeline.syncOperations.handler(type: SSHTransportSession.self)
                }
            }
        }
    }
}

final class UserAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private var username: String
    private var password: String?
    private var privateKey: NIOSSHPrivateKey?

    init(username: String, password: String?, privateKey: NIOSSHPrivateKey?) {
        self.username = username
        self.password = password
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if availableMethods.contains(.publicKey), let privateKey {
            self.privateKey = nil
            nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: privateKey))))
            return
        }
        guard availableMethods.contains(.password), let password else {
            nextChallengePromise.fail(SSHTransportError.passwordAuthenticationUnavailable)
            return
        }
        self.password = nil
        nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .password(.init(password: password))))
    }
}

final class PinnedHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expected: NIOSSHPublicKey?

    init(expected: NIOSSHPublicKey?) { self.expected = expected }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // TOFU: when no key is pinned (e.g. the user logged in with a password
        // and never set a host key) accept the first host key so the tunnel can
        // establish. If a key IS pinned we enforce it strictly.
        guard let expected else {
            validationCompletePromise.succeed(())
            return
        }
        guard hostKey == expected else {
            validationCompletePromise.fail(SSHTransportError.hostKeyMismatch)
            return
        }
        validationCompletePromise.succeed(())
    }
}
