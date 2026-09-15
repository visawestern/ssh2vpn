import NIOCore
import NIOPosix
import NIOSSH
import XCTest
@testable import VPNCore

/// Golden handshake test: what TSPU sees in plaintext (version string +
/// KEXINIT proposal lists) must match the crowd profile. A raw loopback TCP
/// server captures the client's first bytes — no auth, no crypto needed,
/// because the banner and KEXINIT go out BEFORE either.
///
/// RED-first TDD: fails against the stock fork (`SwiftNIOSSH_1.0` banner,
/// P-384-first KEX order, aes256-first ciphers), passes after the fork
/// patch. If this test ever goes red again, the app is fingerprintable.
final class SSHCrowdHandshakeTests: XCTestCase {

    struct CapturedHandshake {
        var versionLine: String
        /// KEXINIT name-lists in order: kex, hostkey, c2s cipher, s2c cipher,
        /// c2s mac, s2c mac, c2s compression, s2c compression.
        var proposals: [[String]]
    }

    /// Accept-any host key: the handshake never gets that far (the fake
    /// server never sends KEXINIT), but the client config requires one.
    final class AcceptAnyHostKey: NIOSSHClientServerAuthenticationDelegate {
        func validateHostKey(hostKey: NIOSSHPublicKey,
                             validationCompletePromise: EventLoopPromise<Void>) {
            validationCompletePromise.succeed(())
        }
    }

    /// Incremental parser: version line, then exactly one SSH binary packet
    /// (the client's KEXINIT). Handles coalesced/split TCP segments.
    final class CaptureHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private enum Phase { case version, packetLength, packetBody(Int) }
        private var phase = Phase.version
        private var stash = ByteBuffer()
        private var version = ""
        private let promise: EventLoopPromise<CapturedHandshake>
        private let serverVersion: String

        init(serverVersion: String, promise: EventLoopPromise<CapturedHandshake>) {
            self.serverVersion = serverVersion
            self.promise = promise
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var incoming = unwrapInboundIn(data)
            stash.writeBuffer(&incoming)
            do { try drain(context: context) } catch {
                promise.fail(error)
                context.close(promise: nil)
            }
        }

        private func drain(context: ChannelHandlerContext) throws {
            while true {
                switch phase {
                case .version:
                    let view = stash.readableBytesView
                    guard let nlPos = view.firstIndex(of: UInt8(ascii: "\n")) else { return }
                    let lineLength = view.distance(from: view.startIndex, to: nlPos) + 1
                    guard let lineData = stash.readBytes(length: lineLength),
                          let line = String(bytes: lineData, encoding: .utf8) else {
                        throw CaptureError.badVersion
                    }
                    version = line.trimmingCharacters(in: .init(charactersIn: "\r\n"))
                    // Answer with our own banner so the client proceeds to KEXINIT.
                    var reply = context.channel.allocator.buffer(capacity: serverVersion.utf8.count + 2)
                    reply.writeString(serverVersion + "\r\n")
                    context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
                    phase = .packetLength
                case .packetLength:
                    guard stash.readableBytes >= 4 else { return }
                    guard let length = stash.readInteger(as: UInt32.self) else {
                        throw CaptureError.shortPacket
                    }
                    phase = .packetBody(Int(length))
                case .packetBody(let length):
                    guard stash.readableBytes >= length else { return }
                    guard var packet = stash.readSlice(length: length),
                          let paddingLength = packet.readInteger(as: UInt8.self),
                          var payload = packet.readSlice(length: length - 1 - Int(paddingLength)) else {
                        throw CaptureError.shortPacket
                    }
                    let proposals = try Self.parseKexInit(&payload)
                    promise.succeed(CapturedHandshake(versionLine: version, proposals: proposals))
                    context.close(promise: nil)
                    return
                }
            }
        }

        /// RFC 4253 §7.1: msg(20) + cookie(16) + 10 name-lists + bool + uint32.
        static func parseKexInit(_ packet: inout ByteBuffer) throws -> [[String]] {
            guard packet.readInteger(as: UInt8.self) == 20 else { throw CaptureError.notKexInit }
            guard packet.readSlice(length: 16) != nil else { throw CaptureError.shortPacket }
            var lists = [[String]]()
            for _ in 0..<10 {
                guard let len = packet.readInteger(as: UInt32.self),
                      let raw = packet.readString(length: Int(len)) else {
                    throw CaptureError.shortPacket
                }
                lists.append(raw.isEmpty ? [] : raw.split(separator: ",").map(String.init))
            }
            return lists
        }

        enum CaptureError: Error { case badVersion, shortPacket, notKexInit }
    }
}

extension SSHCrowdHandshakeTests {
    func testHandshakeMatchesCrowdProfile() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let capturedPromise = group.next().makePromise(of: CapturedHandshake.self)
        let server = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    CaptureHandler(serverVersion: SSHCrowdProfile.clientBanner,
                                   promise: capturedPromise))
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        let port = server.localAddress!.port!

        let config = SSHClientConfiguration(
            userAuthDelegate: SimplePasswordDelegate(username: "u", password: "p"),
            serverAuthDelegate: AcceptAnyHostKey())
        let client = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(NIOSSHHandler(
                    role: .client(config),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil))
            }
            .connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }

        let captured = try capturedPromise.futureResult.wait()

        // 1. Banner: the single most-scanned plaintext fingerprint.
        XCTAssertEqual(captured.versionLine, SSHCrowdProfile.clientBanner)
        XCTAssertFalse(captured.versionLine.contains("NIOSSH"),
                       "fork banner leaks the SwiftNIO implementation")

        // 2. KEXINIT proposal order mirrors OpenSSH 9.6 relative order.
        XCTAssertEqual(captured.proposals.count, 10, "KEXINIT must carry 10 name-lists")
        guard captured.proposals.count == 10 else { return }
        XCTAssertEqual(captured.proposals[0], SSHCrowdProfile.keyExchangeOrder,
                       "KEX order must be curve25519-first like OpenSSH (not P-384-first)")
        XCTAssertEqual(captured.proposals[1], SSHCrowdProfile.hostKeyOrder)
        XCTAssertEqual(captured.proposals[2], SSHCrowdProfile.cipherOrder,
                       "ciphers must be aes128-gcm-first like OpenSSH")
        XCTAssertEqual(captured.proposals[3], SSHCrowdProfile.cipherOrder)
    }
}
