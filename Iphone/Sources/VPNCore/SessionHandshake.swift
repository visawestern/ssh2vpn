import Foundation

/// Application-level authentication for one SSH child session.
/// SSH authenticates the peer, while this nonce binds the gateway process
/// response to the session that the app just created and rejects replay.
///
/// The gateway appends a one-byte connectivity probe status (0 = reachable,
/// 1 = probe failed) after the nonce, so "SSH is up" is distinguishable from
/// "the VPS cannot actually reach the Internet".
public struct SessionHandshake: Sendable {
    public enum State: Equatable, Sendable {
        case waiting
        case authenticated
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case unexpectedFrame
        case wrongStream
        case nonceMismatch
        case replayedAcknowledgement
        case probeFailed
    }

    public let nonce: Data
    public private(set) var state: State = .waiting

    public init(nonce: Data) {
        self.nonce = nonce
    }

    /// Returns true only for the first exact HELLO_ACK for stream zero whose
    /// probe status reports a reachable VPS default route.
    public mutating func accept(_ frame: TransportFrame) throws -> Bool {
        guard frame.type == .helloAck else {
            throw Error.unexpectedFrame
        }
        guard frame.streamID == 0 else {
            throw Error.wrongStream
        }
        guard state == .waiting else {
            throw Error.replayedAcknowledgement
        }
        guard frame.payload.count == nonce.count + 1, frame.payload.prefix(nonce.count) == nonce else {
            throw Error.nonceMismatch
        }
        guard frame.payload.last == 0 else {
            throw Error.probeFailed
        }
        state = .authenticated
        return true
    }
}
