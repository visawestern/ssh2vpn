import XCTest
import NIOCore
import NIOSSH
@testable import VPNCore

/// LIVE integration tests against the real VPS. Gated by env so normal runs
/// stay hermetic: set SSH2VPN_TEST_PASSWORD to run, otherwise skipped.
/// These prove (with the exact production code path) that auth completes,
/// direct-tcpip opens work, and DNS answers — the three unknowns behind the
/// on-device hangs. Run: SSH2VPN_TEST_PASSWORD=... swift test --filter LiveRelayTests
final class LiveRelayTests: XCTestCase {

    struct LiveCreds {
        let host: String
        let port: Int
        let username: String
        let password: String
    }

    func liveCreds() throws -> LiveCreds {
        guard let password = ProcessInfo.processInfo.environment["SSH2VPN_TEST_PASSWORD"],
              !password.isEmpty else {
            throw XCTSkip("SSH2VPN_TEST_PASSWORD not set — live tests skipped")
        }
        return LiveCreds(
            host: ProcessInfo.processInfo.environment["SSH2VPN_TEST_HOST"] ?? "192.250.228.44",
            port: Int(ProcessInfo.processInfo.environment["SSH2VPN_TEST_PORT"] ?? "") ?? 22,
            username: ProcessInfo.processInfo.environment["SSH2VPN_TEST_USER"] ?? "browser",
            password: password)
    }

    /// Connects and returns an authenticated-ready handler. The factory MUST
    /// stay alive for the whole test (its deinit shuts the event loop down).
    func liveHandler(creds: LiveCreds) throws -> (NIOSSHHandler, EventLoop, SSHTransportFactory) {
        let factory = try SSHTransportFactory()
        let channel = try factory.connect(SSHCredentials(
            host: creds.host, port: creds.port, username: creds.username, password: creds.password)).wait()
        let handler = try channel.pipeline.handler(type: NIOSSHHandler.self).wait()
        return (handler, channel.eventLoop, factory)
    }

    func testLiveProbeSucceeds() throws {        let creds = try liveCreds()
        let (handler, loop, factory) = try liveHandler(creds: creds)
        // Must not throw: proves auth completed AND forwarding works.
        try SSHChannelProbe.probe(handler: handler, eventLoop: loop,
                                  host: "8.8.8.8", port: 53, timeoutSeconds: 10)
        withExtendedLifetime(factory) {}
    }

    func testLiveDirectTCPIPDNSRoundTrip() throws {
        let creds = try liveCreds()
        let (handler, loop, factory) = try liveHandler(creds: creds)
        defer { withExtendedLifetime(factory) {} }

        // Minimal DNS query for example.com A (ID 0x4242).
        var query = Data(count: 12)
        query[0] = 0x42; query[1] = 0x42
        query[2] = 0x01
        query += Data([0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x03, 0x63, 0x6F, 0x6D, 0x00, 0x00, 0x01, 0x00, 0x01])

        let promise = loop.makePromise(of: Channel.self)
        let type = SSHChannelType.directTCPIP(.init(
            targetHost: "8.8.8.8", targetPort: 53,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)))
        let sem = DispatchSemaphore(value: 0)
        var childResult: Result<Channel, Error>?
        handler.createChannel(promise, channelType: type) { _, _ in
            loop.makeSucceededFuture(())
        }
        promise.futureResult.whenComplete { childResult = $0; sem.signal() }
        guard sem.wait(timeout: .now() + 15) == .success else {
            XCTFail("direct-tcpip open timed out (auth stuck or forwarding refused)")
            return
        }
        guard case .success(let child) = childResult else {
            XCTFail("direct-tcpip open failed")
            return
        }

        // Attach the production wrapper and run a DNS query through it.
        // NOTE: pipeline mutation must happen ON the event loop.
        let wrapper = SSHRelayChannelWrapper()
        try child.eventLoop.submit {
            try child.pipeline.syncOperations.addHandler(wrapper)
        }.wait()
        var received = [Data]()
        let gotResponse = DispatchSemaphore(value: 0)
        wrapper.onData = { data in
            received.append(data)
            gotResponse.signal()
        }
        wrapper.send(DNSOverTCP.encode(query))
        guard gotResponse.wait(timeout: .now() + 10) == .success else {
            XCTFail("no DNS response through direct-tcpip channel")
            return
        }
        // The response must echo our query ID.
        let combined = received.reduce(Data(), +)
        let (messages, _) = DNSOverTCP.decode(combined)
        XCTAssertFalse(messages.isEmpty, "expected at least one DNS message")
        XCTAssertEqual(messages[0][0], 0x42)
        XCTAssertEqual(messages[0][1], 0x42)
    }

    /// Stock sshd must ANSWER our protocol keepalive — SUCCESS, or the
    /// RFC 4254 §4-mandated FAILURE for requests it does not implement
    /// (Ubuntu's sshd refuses keepalive@openssh.com; real OpenSSH clients
    /// treat that identically). Either reply proves the exact keepalive bytes
    /// round-trip through a real server. Only silence/transport error fails.
    func testLiveProtocolKeepalive() throws {
        let creds = try liveCreds()
        let (handler, loop, factory) = try liveHandler(creds: creds)
        defer { withExtendedLifetime(factory) {} }

        let promise = loop.makePromise(of: ByteBuffer?.self)
        let empty = ByteBufferAllocator().buffer(capacity: 0)
        try loop.submit {
            handler.sendGlobalRequest(
                name: SSHCrowdProfile.keepaliveRequestName,
                payload: empty,
                wantReply: true,
                promise: promise)
        }.wait()

        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<ByteBuffer?, Error>?
        promise.futureResult.whenComplete { outcome = $0; sem.signal() }
        guard sem.wait(timeout: .now() + 15) == .success else {
            XCTFail("keepalive@openssh.com got no reply in 15s")
            return
        }
        switch outcome {
        case .success:
            break // REQUEST_SUCCESS — server implements keepalive.
        case .failure(let error as NIOSSHError)
            where error.type == .globalRequestRefused:
            break // REQUEST_FAILURE — server answered; peer is alive.
        default:
            XCTFail("keepalive@openssh.com transport failure (no answer at all): \(String(describing: outcome))")
        }
    }

    /// Mid-connection rekey against stock sshd, then a probe on the same
    /// connection: proves key rotation works with a real server AND leaves
    /// the tunnel usable (the pool rekeys on the 4G/1h schedule in prod).
    func testLiveRekeySurvives() throws {
        let creds = try liveCreds()
        let (handler, loop, factory) = try liveHandler(creds: creds)
        defer { withExtendedLifetime(factory) {} }

        // connect() returns at TCP time — authentication finishes async, and
        // rekey() traps pre-auth, so prove auth first with a probe.
        try SSHChannelProbe.probe(handler: handler, eventLoop: loop,
                                  host: "8.8.8.8", port: 53, timeoutSeconds: 20)
        try loop.submit {
            try handler.rekey()
        }.wait()
        // Rekey is a multi-round-trip exchange; give it room, then prove the
        // connection still forwards on its new keys.
        try SSHChannelProbe.probe(handler: handler, eventLoop: loop,
                                  host: "8.8.8.8", port: 53, timeoutSeconds: 20)
    }
}
