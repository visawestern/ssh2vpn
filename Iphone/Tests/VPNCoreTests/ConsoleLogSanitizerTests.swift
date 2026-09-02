import XCTest
@testable import VPNCore

final class ConsoleLogSanitizerTests: XCTestCase {

    func testScrubPlainPassword() {
        let input = "Connecting with password: MySuperSecretPassword123! to 192.168.1.1"
        let output = ConsoleLogSanitizer.sanitize(input)
        XCTAssertFalse(output.contains("MySuperSecretPassword123!"))
        XCTAssertTrue(output.contains("***REDACTED***"))
        XCTAssertTrue(output.contains("192.168.1.1"))
    }

    func testScrubJsonPassword() {
        let input = "{\"username\": \"root\", \"password\": \"TopSecretPass99\", \"host\": \"10.0.0.1\"}"
        let output = ConsoleLogSanitizer.sanitize(input)
        XCTAssertFalse(output.contains("TopSecretPass99"))
        XCTAssertTrue(output.contains("root"))
        XCTAssertTrue(output.contains("10.0.0.1"))
    }

    func testScrubCliPasswordFlag() {
        let input = "ssh -p 22 -P SuperPassword! root@example.com"
        let output = ConsoleLogSanitizer.sanitize(input)
        XCTAssertFalse(output.contains("SuperPassword!"))
        XCTAssertTrue(output.contains("root@example.com"))
    }

    func testScrubOpenSSHPrivateKey() {
        let input = """
        Loading key:
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACD7Q2v1mZkE7eBwHw0q8s7N8z9L7j1k2m3n4o5p6q7r8sAAAJsAABCZAAAA
        -----END OPENSSH PRIVATE KEY-----
        Key successfully loaded.
        """
        let output = ConsoleLogSanitizer.sanitize(input)
        XCTAssertFalse(output.contains("b3BlbnNzaC1rZXktdjE"))
        XCTAssertTrue(output.contains("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertTrue(output.contains("-----END OPENSSH PRIVATE KEY-----"))
        XCTAssertTrue(output.contains("[PRIVATE_KEY_REDACTED]"))
        XCTAssertTrue(output.contains("Key successfully loaded."))
    }

    func testScrubRsaPrivateKey() {
        let input = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA0Y3y...secret...data...
        -----END RSA PRIVATE KEY-----
        """
        let output = ConsoleLogSanitizer.sanitize(input)
        XCTAssertFalse(output.contains("secret...data"))
        XCTAssertTrue(output.contains("[PRIVATE_KEY_REDACTED]"))
    }

    func testPreservesSafeServerResponses() {
        let input = "SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.6\nAccepted key fingerprint: SHA256:abc123xyz\nGateway bound to 127.0.0.1:8080"
        let output = ConsoleLogSanitizer.sanitize(input)
        XCTAssertEqual(input, output)
    }

    func testEmptyAndSpecialCharacters() {
        XCTAssertEqual(ConsoleLogSanitizer.sanitize(""), "")
        let special = ">>> [SYSTEM] ⚡️ \\n \\t ~!@#$%^&*()_+ {}[]|:;<>?,./"
        XCTAssertEqual(ConsoleLogSanitizer.sanitize(special), special)
    }

    func testLogStoreAppendAndScrub() {
        let store = ConsoleLogStore()
        store.clear()
        XCTAssertEqual(store.entries.count, 0)

        store.log(level: .ssh, tag: "AUTH", message: "Authenticating with password=UltraSecret!")
        XCTAssertEqual(store.entries.count, 1)

        let entry = store.entries[0]
        XCTAssertFalse(entry.message.contains("UltraSecret!"))
        XCTAssertTrue(entry.message.contains("***REDACTED***"))
        XCTAssertEqual(entry.tag, "AUTH")
        XCTAssertEqual(entry.level, .ssh)
    }

    func testLogStoreExportPlainText() {
        let store = ConsoleLogStore()
        store.clear()
        store.log(level: .info, tag: "INIT", message: "SSH2 Client initialized")
        store.log(level: .success, tag: "CONN", message: "Connected to 1.1.1.1:22")

        let export = store.exportPlainText()
        XCTAssertTrue(export.contains("SSH2 Client initialized"))
        XCTAssertTrue(export.contains("Connected to 1.1.1.1:22"))
        XCTAssertTrue(export.contains("[INIT]"))
        XCTAssertTrue(export.contains("[CONN]"))
    }

    func testConcurrentLoggingSafety() {
        let store = ConsoleLogStore()
        store.clear()
        let group = DispatchGroup()

        for i in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                store.log(level: .info, tag: "THREAD", message: "Message \(i) password: secret\(i)")
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5.0)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(store.entries.count, 50)
        for entry in store.entries {
            XCTAssertFalse(entry.message.contains("secret"))
        }
    }
}
