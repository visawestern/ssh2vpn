import Crypto
import NIOSSH
import XCTest
@testable import VPNCore

final class SSHPrivateKeyTests: XCTestCase {
    /// Real unencrypted ssh-keygen Ed25519 key (throwaway, generated for this
    /// test fixture). Regressions against the binary-blob-as-UTF-8 parsing
    /// bug — which silently broke key auth while passwords worked — fail here.
    private static let pemFixture = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACBbfPGo5GiHFA5VysCvx0ycgpUYLYZt8lEs35Odc+igTAAAAJC7o3gfu6N4
        HwAAAAtzc2gtZWQyNTUxOQAAACBbfPGo5GiHFA5VysCvx0ycgpUYLYZt8lEs35Odc+igTA
        AAAEDzcSiNundMeJRnXToKT5hUfojjay17wl61JorE+PN0i1t88ajkaIcUDlXKwK/HTJyC
        lRgthm3yUSzfk51z6KBMAAAADHRlc3QtZml4dHVyZQE=
        -----END OPENSSH PRIVATE KEY-----
        """

    func testImportsRawEd25519Seed() throws {
        let seed = Data(repeating: 0x11, count: 32)
        let key = try SSHPrivateKeyImporter.importEd25519(seed)
        XCTAssertEqual(key.publicKey, NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: seed)).publicKey)
    }

    func testImportsRealPEMKey() throws {
        let key = try SSHPrivateKeyImporter.importEd25519(Data(Self.pemFixture.utf8))
        // Deterministic seed -> deterministic public key: proves the 32-byte
        // prefix extraction, not just "some key came out".
        let seed = try SSHPrivateKeyImporter.canonicalSeed(from: Data(Self.pemFixture.utf8))
        XCTAssertEqual(seed.count, 32)
        XCTAssertEqual(key.publicKey, NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: seed)).publicKey)
    }

    func testCanonicalSeedMatchesPEMParse() throws {
        let viaPEM = try SSHPrivateKeyImporter.canonicalSeed(from: Data(Self.pemFixture.utf8))
        let direct = try SSHPrivateKeyImporter.importEd25519(Data(Self.pemFixture.utf8))
        // Both paths must produce the same key from the same seed.
        XCTAssertEqual(viaPEM.count, 32)
        XCTAssertEqual(direct.publicKey, NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: viaPEM)).publicKey)
    }

    func testImportsPEMWithCarriageReturns() throws {
        // Keys copied from Mail/Notes/Files arrive with \r\n line endings.
        let crlf = Self.pemFixture.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertNoThrow(try SSHPrivateKeyImporter.importEd25519(Data(crlf.utf8)))
        XCTAssertEqual(try SSHPrivateKeyImporter.canonicalSeed(from: Data(crlf.utf8)).count, 32)
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
