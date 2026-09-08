import XCTest
@testable import VPNCore

/// Deterministic fuzz: LCG-generated garbage must never crash the parser and
/// never produce a parse with an invalid host or out-of-range port.
final class CredentialParserFuzzTests: XCTestCase {

    func testDeterministicFuzzNeverCrashesAndNeverYieldsInvalidResults() {
        var gen = LCG(seed: 0xFEEDFACE)
        for _ in 0..<2_000 {
            let input = randomJunk(&gen)
            do {
                let p = try CredentialParser.parse(input)
                // Invariants on any successful parse.
                XCTAssertTrue(looksLikeHost(p.host), "fuzz produced non-host: \(p.host) from: \(input)")
                XCTAssertTrue((1...65535).contains(p.port), "fuzz produced bad port \(p.port) from: \(input)")
                XCTAssertFalse(p.username.isEmpty)
            } catch {
                // Errors are fine — must be a known ParseError.
                XCTAssertTrue(error is CredentialParser.ParseError, "unknown error \(error) for: \(input)")
            }
        }
    }

    func testTokenPermutationsOfValidParts() {
        var gen = LCG(seed: 0xD00D)
        let hosts = ["1.2.3.4", "vps.example.com", "45.33.32.156", "185.42.9.1"]
        let ports = ["22", "2222", "443"]
        let users = ["root", "ubuntu", "admin", "deploy"]
        let passes = ["secret", "pa:ss", "hunter2", "пароль", "🔑key"]
        for _ in 0..<2_000 {
            let sep = [":", " ", "\t", "@", ", "].randomElement(using: &gen)!
            let h = hosts.randomElement(using: &gen)!
            let u = users.randomElement(using: &gen)!
            let p = passes.randomElement(using: &gen)!
            let port = ports.randomElement(using: &gen)!
            // Various orderings users actually paste.
            let variants = [
                "\(h)\(sep)\(port)\(sep)\(u)\(sep)\(p)",
                "\(u)\(sep)\(p)@\(h):\(port)",
                "Host: \(h) Port: \(port) User: \(u) Password: \(p)",
            ]
            for v in variants {
                do {
                    let parsed = try CredentialParser.parse(v)
                    XCTAssertEqual(parsed.host, h, "variant: \(v)")
                } catch {
                    // Acceptable to fail — but never silently wrong host.
                }
            }
        }
    }

    // MARK: - Junk generator

    private func randomJunk(_ gen: inout LCG) -> String {
        let alphabet = Array("abcXYZ019.: @/\\-_$#!?*=+;|\"'`()[]{}%^\n\t~&<>".utf16)
        let len = Int(gen.next() % 120) + 1
        var chars: [UInt16] = []
        chars.reserveCapacity(len)
        for _ in 0..<len {
            chars.append(alphabet[Int(gen.next() % UInt64(alphabet.count))])
        }
        return String(decoding: chars, as: UTF16.self)
    }
}

private struct LCG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
