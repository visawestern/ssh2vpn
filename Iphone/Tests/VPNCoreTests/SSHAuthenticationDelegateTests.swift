import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import XCTest
@testable import VPNCore

/// Tests the MITM security boundary: host-key pinning and auth-method selection.
///
/// These delegates were `private` and untested. Host-key pinning is the single
/// defence against man-in-the-middle attacks, so it must be covered by tests
/// (TDD concept: security boundaries are never left to inspection alone).
final class SSHAuthenticationDelegateTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
        group = nil
        super.tearDown()
    }

    private func ed25519Key(_ byte: UInt8) -> NIOSSHPrivateKey {
        let seed = Data(repeating: byte, count: 32)
        return NIOSSHPrivateKey(ed25519Key: try! Curve25519.Signing.PrivateKey(rawRepresentation: seed))
    }

    // MARK: - PinnedHostKeyDelegate

    func testHostKeyFailsWhenNothingPinned() {
        let delegate = PinnedHostKeyDelegate(expected: nil)
        let key = ed25519Key(0x11)
        let promise = group.next().makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: key.publicKey, validationCompletePromise: promise)

        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            XCTAssertEqual(error as? SSHTransportError, .hostKeyNotPinned)
        }
    }

    func testHostKeyFailsOnMismatch() {
        let pinned = ed25519Key(0x11)
        let delegate = PinnedHostKeyDelegate(expected: pinned.publicKey)
        let intruder = ed25519Key(0x22)
        let promise = group.next().makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: intruder.publicKey, validationCompletePromise: promise)

        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            XCTAssertEqual(error as? SSHTransportError, .hostKeyMismatch)
        }
    }

    func testHostKeySucceedsOnMatch() {
        let pinned = ed25519Key(0x11)
        let delegate = PinnedHostKeyDelegate(expected: pinned.publicKey)
        let promise = group.next().makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: pinned.publicKey, validationCompletePromise: promise)

        XCTAssertNoThrow(try promise.futureResult.wait())
    }

    // MARK: - UserAuthenticationDelegate

    func testAuthOffersPublicKeyWhenAvailable() {
        let key = ed25519Key(0x11)
        let delegate = UserAuthenticationDelegate(username: "alice", password: "secret", privateKey: key)
        let promise = group.next().makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.publicKey, .password], nextChallengePromise: promise)

        guard let offer = (try? promise.futureResult.wait()) ?? nil else {
            return XCTFail("expected an offer, got nil")
        }
        guard case .privateKey(let pk) = offer.offer else {
            return XCTFail("expected privateKey offer, got \(offer.offer)")
        }
        XCTAssertEqual(pk.privateKey.publicKey, key.publicKey)
    }

    func testAuthFallsBackToPasswordWhenPublicKeyNotOffered() {
        let key = ed25519Key(0x11)
        let delegate = UserAuthenticationDelegate(username: "alice", password: "secret", privateKey: key)
        let promise = group.next().makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.password], nextChallengePromise: promise)

        guard let offer = (try? promise.futureResult.wait()) ?? nil else {
            return XCTFail("expected an offer, got nil")
        }
        guard case .password(let pw) = offer.offer else {
            return XCTFail("expected password offer, got \(offer.offer)")
        }
        XCTAssertEqual(pw.password, "secret")
    }

    func testAuthFailsWhenNothingAvailable() {
        let delegate = UserAuthenticationDelegate(username: "alice", password: nil, privateKey: nil)
        let promise = group.next().makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.publicKey, .password], nextChallengePromise: promise)

        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            XCTAssertEqual(error as? SSHTransportError, .passwordAuthenticationUnavailable)
        }
    }

    func testAuthConsumesPrivateKeySoPasswordFollows() {
        let key = ed25519Key(0x11)
        let delegate = UserAuthenticationDelegate(username: "alice", password: "secret", privateKey: key)

        let first = group.next().makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.publicKey, .password], nextChallengePromise: first)
        let firstOffer = (try? first.futureResult.wait()) ?? nil
        guard case .privateKey = firstOffer?.offer else {
            return XCTFail("first challenge should offer the private key, got \(String(describing: firstOffer?.offer))")
        }

        let second = group.next().makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.publicKey, .password], nextChallengePromise: second)
        let secondOffer = (try? second.futureResult.wait()) ?? nil
        guard case .password = secondOffer?.offer else {
            return XCTFail("second challenge must fall back to password, got \(String(describing: secondOffer?.offer))")
        }
    }
}
