import XCTest
@testable import VPNCore

/// DNS-over-TCP multiplexer for the relay: many concurrent phone DNS queries
/// share ONE upstream TCP connection; responses are routed back to the right
/// flow by DNS query ID. Pure bytes in/out — fully unit-testable.
final class DNSRelayTests: XCTestCase {

    private func flow(port: UInt16) -> RelayFlow {
        RelayFlow(srcAddr: [10, 0, 0, 2], srcPort: port,
                  dstAddr: [8, 8, 8, 8], dstPort: 53, transport: .udp)
    }

    /// Minimal DNS query with the given ID (12-byte header + dummy question).
    private func query(id: UInt16) -> Data {
        var q = Data(count: 12)
        q[0] = UInt8(id >> 8); q[1] = UInt8(id & 0xFF)
        q[2] = 0x01 // RD
        return q + Data([0x03, 0x77, 0x77, 0x77, 0x00, 0x00, 0x01, 0x00, 0x01])
    }

    func testQueryProducesLengthPrefixedBytes() {
        var relay = DNSRelay(upstreamHost: "8.8.8.8")
        let out = relay.query(query(id: 0x1234), from: flow(port: 1111))
        XCTAssertNotNil(out)
        XCTAssertEqual(Array(out!.prefix(2)), [0x00, 0x15]) // 21 bytes
    }

    func testMalformedQueryReturnsNil() {
        var relay = DNSRelay(upstreamHost: "8.8.8.8")
        XCTAssertNil(relay.query(Data([0x01, 0x02, 0x03]), from: flow(port: 1111)))
    }

    func testResponseRoutedToFlow() {
        var relay = DNSRelay(upstreamHost: "8.8.8.8")
        _ = relay.query(query(id: 0x1234), from: flow(port: 1111))
        let resp = query(id: 0x1234) // echo with same ID
        let routed = relay.receive(DNSOverTCP.encode(resp))
        XCTAssertEqual(routed.count, 1)
        XCTAssertEqual(routed[0].0.srcPort, 1111)
        XCTAssertEqual(routed[0].1, resp)
    }

    func testPartialResponseBuffered() {
        var relay = DNSRelay(upstreamHost: "8.8.8.8")
        let q = query(id: 0x1234)
        XCTAssertNotNil(relay.query(q, from: flow(port: 1111)))
        let full = DNSOverTCP.encode(q)
        let first = relay.receive(Data(full.prefix(5)))
        XCTAssertTrue(first.isEmpty, "partial message buffered, nothing routed")
        let second = relay.receive(Data(full.dropFirst(5)))
        XCTAssertEqual(second.count, 1)
    }

    func testSameIDFromTwoFlowsBothAnswered() {
        var relay = DNSRelay(upstreamHost: "8.8.8.8")
        _ = relay.query(query(id: 0x7777), from: flow(port: 1111))
        _ = relay.query(query(id: 0x7777), from: flow(port: 2222))
        let routed = relay.receive(DNSOverTCP.encode(query(id: 0x7777)))
        XCTAssertEqual(routed.count, 2)
        XCTAssertEqual(Set(routed.map(\.0.srcPort)), [1111, 2222])
    }

    func testUnknownIDResponseDropped() {
        var relay = DNSRelay(upstreamHost: "8.8.8.8")
        let routed = relay.receive(DNSOverTCP.encode(query(id: 0x9999)))
        XCTAssertTrue(routed.isEmpty)
    }
}
