import XCTest
@testable import VPNCore

/// Tests duplicate-server hygiene. Duplicates arise when the same machine is
/// saved under different ids (fresh UUID per connect while the extension-side
/// select never arrived, or an edit sheet opened without an id). Records are
/// identical when host+port+username match (host case-insensitive); secrets
/// and flags never participate in identity.
final class ServerDedupeTests: XCTestCase {

    private func server(id: String, host: String = "1.2.3.4", port: Int = 22, username: String = "root") -> ServerProfile {
        ServerProfile(id: id, name: host, host: host, port: port, username: username,
                      hostKey: "", dnsServers: [], hasPassword: false, hasPrivateKey: false)
    }

    // MARK: - duplicateIDs

    func testNoDuplicatesReturnsEmpty() {
        let servers = [server(id: "a"), server(id: "b", host: "2.2.2.2")]
        XCTAssertTrue(ServerDedupe.duplicateIDs(servers: servers, selectedID: nil).isEmpty)
    }

    func testExactDuplicateKeepsSelected() {
        let servers = [server(id: "a"), server(id: "b")]
        XCTAssertEqual(ServerDedupe.duplicateIDs(servers: servers, selectedID: "b"), ["a"])
    }

    func testExactDuplicateWithoutSelectionKeepsFirst() {
        let servers = [server(id: "a"), server(id: "b")]
        XCTAssertEqual(ServerDedupe.duplicateIDs(servers: servers, selectedID: nil), ["b"])
    }

    func testSameHostDifferentPortIsKept() {
        let servers = [server(id: "a", port: 22), server(id: "b", port: 2222)]
        XCTAssertTrue(ServerDedupe.duplicateIDs(servers: servers, selectedID: nil).isEmpty)
    }

    func testSameHostDifferentUserIsKept() {
        let servers = [server(id: "a", username: "root"), server(id: "b", username: "admin")]
        XCTAssertTrue(ServerDedupe.duplicateIDs(servers: servers, selectedID: nil).isEmpty)
    }

    func testHostMatchIsCaseInsensitive() {
        let servers = [server(id: "a", host: "Example.COM"), server(id: "b", host: "example.com")]
        XCTAssertEqual(ServerDedupe.duplicateIDs(servers: servers, selectedID: nil), ["b"])
    }

    func testThreeDuplicatesRemoveTwo() {
        let servers = [server(id: "a"), server(id: "b"), server(id: "c")]
        XCTAssertEqual(ServerDedupe.duplicateIDs(servers: servers, selectedID: "c"), ["a", "b"])
    }

    // MARK: - matchID

    func testMatchFindsSameCoordinates() {
        let servers = [server(id: "a"), server(id: "b", host: "9.9.9.9")]
        XCTAssertEqual(ServerDedupe.matchID(servers: servers, host: "1.2.3.4", port: 22, username: "root"), "a")
    }

    func testMatchReturnsNilWhenNothingMatches() {
        XCTAssertNil(ServerDedupe.matchID(servers: [server(id: "a")], host: "8.8.8.8", port: 22, username: "root"))
    }

    func testMatchIgnoresCase() {
        let servers = [server(id: "a", host: "Example.COM")]
        XCTAssertEqual(ServerDedupe.matchID(servers: servers, host: "example.com", port: 22, username: "root"), "a")
    }
}
