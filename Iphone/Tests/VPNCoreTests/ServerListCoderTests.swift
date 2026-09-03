import XCTest
@testable import VPNCore

/// Tests the pure JSON coding logic the app uses to talk to the extension's
/// server-list API. Isolated from any real VPN manager — only (de)serialization
/// is exercised here.
final class ServerListCoderTests: XCTestCase {

    // MARK: - Encode (app → extension)

    func testEncodeServerSetProducesAllFields() {
        let profile = ServerProfile(
            id: "abc", name: "My VPS", host: "1.2.3.4", port: 2222, username: "root",
            hostKey: "AAAAB3", dnsServers: ["8.8.8.8"], hasPassword: true, hasPrivateKey: false,
            password: "sekret", privateKey: nil
        )
        let dict = ServerListCoder.encodeServerSet(profile)

        XCTAssertEqual(dict["id"] as? String, "abc")
        XCTAssertEqual(dict["host"] as? String, "1.2.3.4")
        XCTAssertEqual(dict["port"] as? Int, 2222)
        XCTAssertEqual(dict["username"] as? String, "root")
        XCTAssertEqual(dict["password"] as? String, "sekret")
        XCTAssertNil(dict["privateKey"], "nil secret must not be encoded")
    }

    func testEncodeServerSetWithoutSecrets() {
        let profile = ServerProfile(
            id: "x", name: "X", host: "9.9.9.9", port: 22, username: "admin",
            hostKey: "", dnsServers: [], hasPassword: false, hasPrivateKey: false
        )
        let dict = ServerListCoder.encodeServerSet(profile)
        XCTAssertNil(dict["password"])
        XCTAssertNil(dict["privateKey"])
    }

    // MARK: - Decode (extension → app)

    func testDecodeServerListParsesProfiles() {
        let data: [String: String] = [
            "servers": "[{\"id\":\"1\",\"name\":\"A\",\"host\":\"1.1.1.1\",\"port\":22,\"username\":\"root\",\"hostKey\":\"\",\"dnsServers\":[\"8.8.8.8\"],\"hasPassword\":true,\"hasPrivateKey\":false}]",
            "selectedID": "1"
        ]
        let (servers, selectedID) = ServerListCoder.decodeServerList(data: data)

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].id, "1")
        XCTAssertEqual(servers[0].host, "1.1.1.1")
        XCTAssertTrue(servers[0].hasPassword)
        XCTAssertEqual(selectedID, "1")
    }

    func testDecodeServerListEmpty() {
        let (servers, selectedID) = ServerListCoder.decodeServerList(data: ["servers": "[]"])
        XCTAssertTrue(servers.isEmpty)
        XCTAssertNil(selectedID)
    }

    func testDecodeServerListMultiplePreservesOrder() {
        let data: [String: String] = [
            "servers": "[{\"id\":\"a\",\"name\":\"A\",\"host\":\"1.1.1.1\",\"port\":22,\"username\":\"r\",\"hostKey\":\"\",\"dnsServers\":[],\"hasPassword\":false,\"hasPrivateKey\":false},{\"id\":\"b\",\"name\":\"B\",\"host\":\"2.2.2.2\",\"port\":22,\"username\":\"r\",\"hostKey\":\"\",\"dnsServers\":[],\"hasPassword\":true,\"hasPrivateKey\":false}]"
        ]
        let (servers, _) = ServerListCoder.decodeServerList(data: data)
        XCTAssertEqual(servers.map(\.id), ["a", "b"])
    }

    func testDecodeServerListWithMissingFieldsUsesDefaults() {
        // Robustness: a partial JSON must not crash the decoder.
        let data: [String: String] = [
            "servers": "[{\"id\":\"1\",\"host\":\"1.1.1.1\"}]"
        ]
        let (servers, _) = ServerListCoder.decodeServerList(data: data)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].id, "1")
        XCTAssertEqual(servers[0].port, 22) // default
    }

    func testDecodeServerListWithoutSecrets() {
        // The extension strips secrets; verify the app never receives them even
        // if a buggy extension leaked them (defense in depth).
        let data: [String: String] = [
            "servers": "[{\"id\":\"1\",\"host\":\"1.1.1.1\",\"port\":22,\"username\":\"r\",\"hostKey\":\"\",\"dnsServers\":[],\"hasPassword\":true,\"hasPrivateKey\":false,\"password\":\"LEAKED\",\"privateKey\":\"KEY\"}]"
        ]
        let (servers, _) = ServerListCoder.decodeServerList(data: data)
        XCTAssertEqual(servers[0].password, nil, "app must not retain leaked secrets")
        XCTAssertEqual(servers[0].privateKey, nil, "app must not retain leaked secrets")
    }
}
