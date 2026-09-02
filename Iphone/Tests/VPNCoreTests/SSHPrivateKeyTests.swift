import Crypto
import NIOSSH
import XCTest
@testable import VPNCore

final class SSHPrivateKeyTests: XCTestCase {
    func testImportsRawEd25519Seed() throws {
        let seed = Data(repeating: 0x11, count: 32)
        let key = try SSHPrivateKeyImporter.importEd25519(seed)
        XCTAssertEqual(key.publicKey, NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: seed)).publicKey)
    }

    func testRejectsEncryptedOpenSSHKeyExplicitly() {
        let payload = Data("openssh-key-v1\0none".utf8)
        let pem = Data("-----BEGIN OPENSSH PRIVATE KEY-----\n\(payload.base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----".utf8)
        XCTAssertThrowsError(try SSHPrivateKeyImporter.importEd25519(pem)) { error in
            XCTAssertEqual(error as? SSHPrivateKeyImporter.ImportError, .malformedKey)
        }
    }

    func testRejectsWrongRawKeyLength() {
        XCTAssertThrowsError(try SSHPrivateKeyImporter.importEd25519(Data(repeating: 1, count: 31))) { error in
            XCTAssertEqual(error as? SSHPrivateKeyImporter.ImportError, .unsupportedFormat)
        }
    }

    func testCanonicalizesBase64AndHexSeedsWithoutCrashing() throws {
        let seed = Data(repeating: 0xAB, count: 32)
        let hex = seed.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try SSHPrivateKeyImporter.canonicalSeed(from: Data(seed.base64EncodedString().utf8)), seed)
        XCTAssertEqual(try SSHPrivateKeyImporter.canonicalSeed(from: Data(hex.utf8)), seed)
    }
}
