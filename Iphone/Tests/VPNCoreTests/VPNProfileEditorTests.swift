import XCTest
@testable import VPNCore

final class VPNProfileEditorTests: XCTestCase {

    func testEditKeepsExistingPasswordWhenFieldEmpty() {
        let existing = EditableServerProfile(
            host: "1.2.3.4", port: 22, username: "root",
            password: "secret", privateKey: "", hostKey: ""
        )
        let edited = EditableServerProfile(
            host: "5.6.7.8", port: 2222, username: "admin",
            password: "", privateKey: "", hostKey: ""
        )
        let merged = VPNProfileEditor.merge(existing: existing, edited: edited)
        XCTAssertEqual(merged.host, "5.6.7.8")
        XCTAssertEqual(merged.port, 2222)
        XCTAssertEqual(merged.username, "admin")
        XCTAssertEqual(merged.password, "secret", "Empty password field must keep the saved password")
    }

    func testEditOverwritesPasswordWhenProvided() {
        let existing = EditableServerProfile(
            host: "1.2.3.4", port: 22, username: "root",
            password: "oldpass", privateKey: "", hostKey: ""
        )
        let edited = EditableServerProfile(
            host: "1.2.3.4", port: 22, username: "root",
            password: "newpass", privateKey: "", hostKey: ""
        )
        let merged = VPNProfileEditor.merge(existing: existing, edited: edited)
        XCTAssertEqual(merged.password, "newpass")
    }

    func testEditKeepsHostKeyWhenEmpty() {
        let existing = EditableServerProfile(
            host: "1.2.3.4", port: 22, username: "root",
            password: "p", privateKey: "", hostKey: "aaa:bbb"
        )
        let edited = EditableServerProfile(
            host: "1.2.3.4", port: 22, username: "root",
            password: "", privateKey: "", hostKey: ""
        )
        let merged = VPNProfileEditor.merge(existing: existing, edited: edited)
        XCTAssertEqual(merged.hostKey, "aaa:bbb")
        XCTAssertEqual(merged.password, "p")
    }

    func testEditCanClearHostKeyWhenExplicitlyChanged() {
        let existing = EditableServerProfile(
            host: "1.2.3.4", port: 22, username: "root",
            password: "p", privateKey: "", hostKey: "old"
        )
        let edited = EditableServerProfile(
            host: "1.2.3.4", port: 22, username: "root",
            password: "p", privateKey: "", hostKey: "new"
        )
        let merged = VPNProfileEditor.merge(existing: existing, edited: edited)
        XCTAssertEqual(merged.hostKey, "new")
    }

    func testEditKeepsPrivateKeyWhenEmpty() {
        let existing = EditableServerProfile(
            host: "1.2.3.4", port: 22, username: "root",
            password: "", privateKey: "KEYDATA", hostKey: ""
        )
        let edited = EditableServerProfile(
            host: "1.2.3.4", port: 22, username: "root",
            password: "", privateKey: "", hostKey: ""
        )
        let merged = VPNProfileEditor.merge(existing: existing, edited: edited)
        XCTAssertEqual(merged.privateKey, "KEYDATA")
    }
}
