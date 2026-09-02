import Foundation
import XCTest
@testable import VPNCore

/// Tests Chapter 5 items 86, 93, 94: transport configuration and flow admission.
/// Pure config + pure decision logic, fully testable. Converges chains C5
/// (raw-packet bridge) and C7 (flow mode).
final class GatewayTransportConfigTests: XCTestCase {
    // MARK: - p.86: MTU sizes

    func testIPv4MTU() {
        XCTAssertEqual(GatewayTransportConfig.default.ipv4MTU, 1400)
    }

    func testIPv6MTU() {
        XCTAssertEqual(GatewayTransportConfig.default.ipv6MTU, 1380)
    }

    func testMTUsArePositive() {
        XCTAssertGreaterThan(GatewayTransportConfig.default.ipv4MTU, 0)
        XCTAssertGreaterThan(GatewayTransportConfig.default.ipv6MTU, 0)
    }

    // MARK: - p.93: max flow count

    func testDefaultMaxFlows() {
        XCTAssertEqual(GatewayTransportConfig.default.maxActiveFlows, 4096)
    }

    // MARK: - p.94: flow exhaustion

    func testCustomMaxFlows() {
        let config = GatewayTransportConfig(maxActiveFlows: 100)
        XCTAssertEqual(config.maxActiveFlows, 100)
    }

    func testMaxFlowsClampedToMinimum() {
        let config = GatewayTransportConfig(maxActiveFlows: 0)
        XCTAssertEqual(config.maxActiveFlows, 1)
    }

    // MARK: - timeouts

    func testDefaultTimeouts() {
        let config = GatewayTransportConfig.default
        XCTAssertEqual(config.tcpIdleTimeout, 300)
        XCTAssertEqual(config.udpIdleTimeout, 60)
    }
}

/// Tests the flow-admission policy (p.93, p.94): accept or reject a new flow
/// based on the active count. Pure decision logic for chain C7.
final class GatewayFlowAdmissionTests: XCTestCase {
    private let config = GatewayTransportConfig(maxActiveFlows: 3)

    func testAcceptsFlowUnderLimit() {
        XCTAssertEqual(GatewayFlowAdmission.decide(activeFlows: 0, config: config), .accept)
        XCTAssertEqual(GatewayFlowAdmission.decide(activeFlows: 1, config: config), .accept)
        XCTAssertEqual(GatewayFlowAdmission.decide(activeFlows: 2, config: config), .accept)
    }

    func testRejectsFlowAtLimit() {
        XCTAssertEqual(GatewayFlowAdmission.decide(activeFlows: 3, config: config), .reject)
    }

    func testRejectsFlowOverLimit() {
        XCTAssertEqual(GatewayFlowAdmission.decide(activeFlows: 4, config: config), .reject)
        XCTAssertEqual(GatewayFlowAdmission.decide(activeFlows: 100, config: config), .reject)
    }

    func testZeroActiveFlowsAccepts() {
        XCTAssertEqual(GatewayFlowAdmission.decide(activeFlows: 0, config: config), .accept)
    }
}
