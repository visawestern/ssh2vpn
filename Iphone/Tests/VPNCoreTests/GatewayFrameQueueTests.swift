import Foundation
import XCTest
@testable import VPNCore

/// Tests Chapter 5 item 96: the frame queue is bounded by both packet count and
/// byte size so a stalled handshake cannot grow memory forever. Pure decision
/// logic for chain C5 (raw-packet bridge).
final class GatewayFrameQueueTests: XCTestCase {
    private let limits = GatewayFrameQueue.Limits(maxPackets: 512, maxBytes: 256 * 1024)

    // MARK: - p.96: bounds

    func testAcceptsWhenUnderBothLimits() {
        let q = GatewayFrameQueue(limits: limits, count: 0, bytes: 0)
        XCTAssertEqual(q.accept(packetSize: 100), .accept)
    }

    func testRejectsWhenPacketCountFull() {
        let q = GatewayFrameQueue(limits: limits, count: 512, bytes: 0)
        XCTAssertEqual(q.accept(packetSize: 1), .backpressure)
    }

    func testRejectsWhenByteBudgetFull() {
        let q = GatewayFrameQueue(limits: limits, count: 0, bytes: 256 * 1024)
        XCTAssertEqual(q.accept(packetSize: 1), .backpressure)
    }

    func testRejectsWhenPacketExceedsByteBudget() {
        let q = GatewayFrameQueue(limits: limits, count: 0, bytes: 256 * 1024 - 50)
        XCTAssertEqual(q.accept(packetSize: 100), .backpressure)
    }

    func testAcceptsAtExactByteBoundary() {
        let q = GatewayFrameQueue(limits: limits, count: 0, bytes: 256 * 1024 - 100)
        XCTAssertEqual(q.accept(packetSize: 100), .accept)
    }

    // MARK: - state transitions

    func testEnqueueIncreasesCountAndBytes() {
        var q = GatewayFrameQueue(limits: limits, count: 0, bytes: 0)
        XCTAssertEqual(q.accept(packetSize: 100), .accept)
        q.enqueue(packetSize: 100)
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.bytes, 100)
    }

    func testDequeueDecreasesCountAndBytes() {
        var q = GatewayFrameQueue(limits: limits, count: 1, bytes: 100)
        q.dequeue(packetSize: 100)
        XCTAssertEqual(q.count, 0)
        XCTAssertEqual(q.bytes, 0)
    }

    func testDequeueNeverGoesNegative() {
        var q = GatewayFrameQueue(limits: limits, count: 0, bytes: 0)
        q.dequeue(packetSize: 100)
        XCTAssertEqual(q.count, 0)
        XCTAssertEqual(q.bytes, 0)
    }

    // MARK: - defaults

    func testDefaultLimitsMatchTransport() {
        let def = GatewayFrameQueue.Limits.default
        XCTAssertEqual(def.maxPackets, 512)
        XCTAssertEqual(def.maxBytes, 256 * 1024)
    }
}
