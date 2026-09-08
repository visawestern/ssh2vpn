import XCTest
@testable import VPNCore

/// Happy-path formats a real user pastes after buying a VPS.
/// Every provider email/panel format from the plan spec must parse.
final class CredentialParserHappyPathTests: XCTestCase {

    func testColonFormHostPortUserPass() throws {
        let p = try CredentialParser.parse("1.2.3.4:22:root:secret")
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.port, 22)
        XCTAssertEqual(p.username, "root")
        XCTAssertEqual(p.password, "secret")
    }

    func testColonFormWithoutPort() throws {
        let p = try CredentialParser.parse("1.2.3.4:root:secret")
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.port, 22)
        XCTAssertEqual(p.username, "root")
        XCTAssertEqual(p.password, "secret")
    }

    func testColonFormPasswordContainsColons() throws {
        let p = try CredentialParser.parse("example.com:2222:admin:pa:ss:wo:rd")
        XCTAssertEqual(p.host, "example.com")
        XCTAssertEqual(p.port, 2222)
        XCTAssertEqual(p.username, "admin")
        XCTAssertEqual(p.password, "pa:ss:wo:rd")
    }

    func testUserinfoForm() throws {
        let p = try CredentialParser.parse("root:secret@1.2.3.4")
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.port, 22)
        XCTAssertEqual(p.username, "root")
        XCTAssertEqual(p.password, "secret")
    }

    func testUserinfoFormWithPort() throws {
        let p = try CredentialParser.parse("admin:p@ss@vps.example.org:2222")
        XCTAssertEqual(p.host, "vps.example.org")
        XCTAssertEqual(p.port, 2222)
        XCTAssertEqual(p.username, "admin")
        XCTAssertEqual(p.password, "p@ss")
    }

    func testSchemeURL() throws {
        let p = try CredentialParser.parse("ssh://root:secret@1.2.3.4:22")
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.port, 22)
        XCTAssertEqual(p.username, "root")
        XCTAssertEqual(p.password, "secret")
    }

    func testSftpSchemeURL() throws {
        let p = try CredentialParser.parse("sftp://ubuntu:hunter2@server.example.com:2222/path")
        XCTAssertEqual(p.host, "server.example.com")
        XCTAssertEqual(p.port, 2222)
        XCTAssertEqual(p.username, "ubuntu")
        XCTAssertEqual(p.password, "hunter2")
    }

    func testSchemeURLNoCredentials() throws {
        let p = try CredentialParser.parse("ssh://1.2.3.4:2222")
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.port, 2222)
        XCTAssertEqual(p.username, "root")
        XCTAssertNil(p.password)
    }

    func testLabeledEnglish() throws {
        let labeled = """
        Host: 45.33.32.156
        Port: 22
        Username: root
        Password: MyP@ssw0rd
        """
        let p = try CredentialParser.parse(labeled)
        XCTAssertEqual(p.host, "45.33.32.156")
        XCTAssertEqual(p.port, 22)
        XCTAssertEqual(p.username, "root")
        XCTAssertEqual(p.password, "MyP@ssw0rd")
    }

    func testLabeledRussian() throws {
        let labeled = """
        IP-адрес: 185.12.34.56
        Порт: 2222
        Логин: ubuntu
        Пароль: дерзкий
        """
        let p = try CredentialParser.parse(labeled)
        XCTAssertEqual(p.host, "185.12.34.56")
        XCTAssertEqual(p.port, 2222)
        XCTAssertEqual(p.username, "ubuntu")
        XCTAssertEqual(p.password, "дерзкий")
    }

    func testLabeledSingleLineSlashes() throws {
        let p = try CredentialParser.parse("IP: 1.2.3.4 / Port: 22 / Username: root / Password: xyz")
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.port, 22)
        XCTAssertEqual(p.username, "root")
        XCTAssertEqual(p.password, "xyz")
    }

    func testSSHCommandPrefix() throws {
        let p = try CredentialParser.parse("ssh root@1.2.3.4")
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.username, "root")
    }

    func testSSHCommandPrefixWithPortFlag() throws {
        let p = try CredentialParser.parse("ssh root@1.2.3.4 -p 2222")
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.port, 2222)
        XCTAssertEqual(p.username, "root")
    }

    func testJSONCredentials() throws {
        let json = """
        {"host": "1.2.3.4", "port": 2222, "username": "root", "password": "secret"}
        """
        let p = try CredentialParser.parse(json)
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.port, 2222)
        XCTAssertEqual(p.username, "root")
        XCTAssertEqual(p.password, "secret")
    }

    func testJSONAlternateKeys() throws {
        let json = """
        {"ip": "vps.example.com", "ssh_port": 443, "user": "admin", "ssh_password": "pwn"}
        """
        let p = try CredentialParser.parse(json)
        XCTAssertEqual(p.host, "vps.example.com")
        XCTAssertEqual(p.port, 443)
        XCTAssertEqual(p.username, "admin")
        XCTAssertEqual(p.password, "pwn")
    }

    func testWhitespaceTokenForm() throws {
        let p = try CredentialParser.parse("1.2.3.4 22 root secret")
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.port, 22)
        XCTAssertEqual(p.username, "root")
        XCTAssertEqual(p.password, "secret")
    }

    func testTabSeparated() throws {
        let p = try CredentialParser.parse("1.2.3.4\t22\troot\tsecret")
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.port, 22)
        XCTAssertEqual(p.username, "root")
        XCTAssertEqual(p.password, "secret")
    }

    func testDomainHost() throws {
        let p = try CredentialParser.parse("vps-01.example.org:22:ubuntu:s3cret")
        XCTAssertEqual(p.host, "vps-01.example.org")
        XCTAssertEqual(p.username, "ubuntu")
        XCTAssertEqual(p.password, "s3cret")
    }

    func testDefaults() throws {
        let p = try CredentialParser.parse("1.2.3.4:22")
        XCTAssertEqual(p.host, "1.2.3.4")
        XCTAssertEqual(p.port, 22)
        XCTAssertEqual(p.username, "root")
        XCTAssertNil(p.password)
    }
}
