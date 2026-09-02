import XCTest
@testable import VPNCore

/// Tracks the sequence of lifecycle calls to verify correct ordering.
private final class MockVPNConnectionManager: VPNConnectionManager {
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var callSequence: [String] = []
    private(set) var lastConfig: [String: Any] = [:]
    private var startResult: VPNConnectionError? = nil

    func setResult(_ result: VPNConnectionError?) {
        startResult = result
    }

    func start(
        host: String,
        port: Int,
        username: String,
        providerBundleIdentifier: String,
        providerConfiguration: [String: Any],
        completion: @escaping (VPNConnectionError?) -> Void
    ) {
        callSequence.append("start")
        isConnecting = true
        lastConfig = providerConfiguration

        DispatchQueue.global().async { [self] in
            if let error = startResult {
                isConnecting = false
                completion(error)
                return
            }

            isConnected = true
            isConnecting = false
            completion(nil)
        }
    }

    func stop() {
        callSequence.append("stop")
        isConnected = false
        isConnecting = false
    }
}

final class VPNConnectionProtocolTests: XCTestCase {

    // MARK: - Sequence Tests

    func testStartSetsIsConnecting() {
        let mock = MockVPNConnectionManager()
        XCTAssertFalse(mock.isConnecting)

        mock.start(
            host: "1.2.3.4", port: 22, username: "root",
            providerBundleIdentifier: "com.test.tunnel",
            providerConfiguration: [:]
        ) { _ in }

        XCTAssertTrue(mock.isConnecting)
        XCTAssertFalse(mock.isConnected)
    }

    func testStartSuccessSetsIsConnected() {
        let mock = MockVPNConnectionManager()
        let exp = expectation(description: "connect")

        mock.start(
            host: "1.2.3.4", port: 22, username: "root",
            providerBundleIdentifier: "com.test.tunnel",
            providerConfiguration: [:]
        ) { error in
            XCTAssertNil(error)
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1)
        XCTAssertTrue(mock.isConnected)
        XCTAssertFalse(mock.isConnecting)
    }

    func testStopClearsState() {
        let mock = MockVPNConnectionManager()
        let exp = expectation(description: "connect")
        mock.start(
            host: "1.2.3.4", port: 22, username: "root",
            providerBundleIdentifier: "com.test.tunnel",
            providerConfiguration: [:]
        ) { error in
            XCTAssertNil(error)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)

        mock.stop()
        XCTAssertFalse(mock.isConnected)
        XCTAssertFalse(mock.isConnecting)
    }

    // MARK: - Error Cases

    func testStartErrorDoesNotSetConnected() {
        let mock = MockVPNConnectionManager()
        mock.setResult(.loadFailed("prefs error"))

        let exp = expectation(description: "fail")
        mock.start(
            host: "1.2.3.4", port: 22, username: "root",
            providerBundleIdentifier: "com.test.tunnel",
            providerConfiguration: [:]
        ) { error in
            XCTAssertEqual(error, .loadFailed("prefs error"))
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1)
        XCTAssertFalse(mock.isConnected)
    }

    func testStopWithoutStartIsNoOp() {
        let mock = MockVPNConnectionManager()
        mock.stop()
        XCTAssertFalse(mock.isConnected)
        XCTAssertFalse(mock.isConnecting)
    }

    // MARK: - Configuration Passthrough

    func testProviderConfigurationIsPassedThrough() {
        let mock = MockVPNConnectionManager()
        let config: [String: Any] = [
            "host": "1.2.3.4",
            "port": 22,
            "username": "root"
        ]

        mock.start(
            host: "1.2.3.4", port: 22, username: "root",
            providerBundleIdentifier: "com.test.tunnel",
            providerConfiguration: config
        ) { _ in }

        XCTAssertEqual(mock.lastConfig["host"] as? String, "1.2.3.4")
        XCTAssertEqual(mock.lastConfig["port"] as? Int, 22)
        XCTAssertEqual(mock.lastConfig["username"] as? String, "root")
    }

    func testEmptyProviderConfiguration() {
        let mock = MockVPNConnectionManager()

        mock.start(
            host: "1.2.3.4", port: 22, username: "root",
            providerBundleIdentifier: "com.test.tunnel",
            providerConfiguration: [:]
        ) { _ in }

        XCTAssertTrue(mock.lastConfig.isEmpty)
    }

    // MARK: - Multiple Start Calls

    func testMultipleStartCallsTrackSequence() {
        let mock = MockVPNConnectionManager()
        let exp1 = expectation(description: "connect1")
        mock.start(
            host: "1.2.3.4", port: 22, username: "root",
            providerBundleIdentifier: "com.test.tunnel",
            providerConfiguration: [:]
        ) { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 1)

        mock.stop()

        let exp2 = expectation(description: "connect2")
        mock.start(
            host: "5.6.7.8", port: 22, username: "admin",
            providerBundleIdentifier: "com.test.tunnel",
            providerConfiguration: [:]
        ) { _ in exp2.fulfill() }
        wait(for: [exp2], timeout: 1)

        XCTAssertEqual(mock.callSequence, ["start", "stop", "start"])
    }

    // MARK: - VPNConnectionError Equatable

    func testVPNErrorsAreEquatable() {
        XCTAssertEqual(VPNConnectionError.loadFailed("x"), VPNConnectionError.loadFailed("x"))
        XCTAssertNotEqual(VPNConnectionError.loadFailed("x"), VPNConnectionError.loadFailed("y"))
        XCTAssertNotEqual(VPNConnectionError.loadFailed("x"), VPNConnectionError.saveFailed("x"))
        XCTAssertNotEqual(VPNConnectionError.startFailed("x"), VPNConnectionError.invalidConfiguration("x"))
    }

    func testVPNErrorsDescriptions() {
        XCTAssertNotNil(VPNConnectionError.loadFailed("test").localizedDescription)
        XCTAssertNotNil(VPNConnectionError.saveFailed("test").localizedDescription)
        XCTAssertNotNil(VPNConnectionError.startFailed("test").localizedDescription)
        XCTAssertNotNil(VPNConnectionError.invalidConfiguration("test").localizedDescription)
        XCTAssertNotNil(VPNConnectionError.keychainError("test").localizedDescription)
        XCTAssertEqual(VPNConnectionError.alreadyConnected.localizedDescription, VPNConnectionError.alreadyConnected.localizedDescription)
        XCTAssertEqual(VPNConnectionError.notConfigured.localizedDescription, VPNConnectionError.notConfigured.localizedDescription)
    }
}
