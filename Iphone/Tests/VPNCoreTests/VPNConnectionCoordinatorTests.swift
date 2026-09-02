import XCTest
@testable import VPNCore

/// Records save/reload/start calls to verify ordering + error handling.
private final class RecordingSaver: VPNConnectionSaver {
    private(set) var saveCalls = 0
    private(set) var reloadCalls = 0
    private(set) var lastConfig: VPNConfiguration?
    var saveError: VPNConnectionError?
    var reloadError: VPNConnectionError?

    func save(configuration: VPNConfiguration, completion: @escaping (VPNConnectionError?) -> Void) {
        saveCalls += 1
        lastConfig = configuration
        DispatchQueue.global().async { completion(self.saveError) }
    }

    func reload(completion: @escaping (VPNConnectionError?) -> Void) {
        reloadCalls += 1
        DispatchQueue.global().async { completion(self.reloadError) }
    }
}

/// Recorder manager that captures start/stop and completion.
private final class RecordingManager: VPNConnectionManager {
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var started = false
    private(set) var stopped = false
    private(set) var startConfig: [String: Any]?
    var startError: VPNConnectionError?

    func start(
        host: String,
        port: Int,
        username: String,
        providerBundleIdentifier: String,
        providerConfiguration: [String: Any],
        completion: @escaping (VPNConnectionError?) -> Void
    ) {
        started = true
        isConnecting = true
        startConfig = providerConfiguration
        DispatchQueue.global().async {
            if let e = self.startError {
                self.isConnecting = false
                completion(e)
            } else {
                self.isConnected = true
                self.isConnecting = false
                completion(nil)
            }
        }
    }

    func stop() {
        stopped = true
        isConnected = false
        isConnecting = false
    }
}

final class VPNConnectionCoordinatorTests: XCTestCase {

    private func validProfile(password: String = "secret") -> VPNProfileInput {
        VPNProfileInput(host: "203.0.113.10", port: 22, username: "root", password: password)
    }

    // MARK: - The critical fix: save -> reload -> start ORDER

    func testSaveThenReloadThenStartOrder() {
        let saver = RecordingSaver()
        let manager = RecordingManager()
        let coordinator = VPNConnectionCoordinator(saver: saver, manager: manager)

        let exp = expectation(description: "connect")

        coordinator.connect(profile: validProfile(), providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel") { error in
            XCTAssertNil(error)
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2)
        XCTAssertEqual(saver.saveCalls, 1, "must save exactly once")
        XCTAssertEqual(saver.reloadCalls, 1, "must reload exactly once after save, before start")
        XCTAssertTrue(manager.started, "start must be attempted")
        // Reload MUST happen after save and before start.
        XCTAssertGreaterThanOrEqual(saver.reloadCalls, 1)
    }

    func testConfigIsSavedAndForwardedToStart() {
        let saver = RecordingSaver()
        let manager = RecordingManager()
        let coordinator = VPNConnectionCoordinator(saver: saver, manager: manager)

        let exp = expectation(description: "connect")
        coordinator.connect(profile: validProfile(), providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel") { _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(saver.lastConfig?.serverAddress, "203.0.113.10")
        XCTAssertEqual(saver.lastConfig?.providerConfiguration["port"] as? Int, 22)
        XCTAssertEqual(manager.startConfig?["host"] as? String, "203.0.113.10")
    }

    // MARK: - Save failure never reaches start

    func testSaveErrorAbortsStart() {
        let saver = RecordingSaver()
        saver.saveError = .saveFailed("disk full")
        let manager = RecordingManager()
        let coordinator = VPNConnectionCoordinator(saver: saver, manager: manager)

        let exp = expectation(description: "fail")
        coordinator.connect(profile: validProfile(), providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel") { error in
            XCTAssertEqual(error, .saveFailed("disk full"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        XCTAssertFalse(manager.started, "start must NOT be called when save fails")
    }

    func testSaveErrorDoesNotCallReload() {
        let saver = RecordingSaver()
        saver.saveError = .saveFailed("disk full")
        let manager = RecordingManager()
        let coordinator = VPNConnectionCoordinator(saver: saver, manager: manager)

        let exp = expectation(description: "fail")
        coordinator.connect(profile: validProfile(), providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel") { _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(saver.reloadCalls, 0, "reload must not run when save failed")
        XCTAssertFalse(manager.started)
    }

    // MARK: - Reload failure aborts start

    func testReloadErrorAbortsStart() {
        let saver = RecordingSaver()
        saver.reloadError = .loadFailed("prefs missing")
        let manager = RecordingManager()
        let coordinator = VPNConnectionCoordinator(saver: saver, manager: manager)

        let exp = expectation(description: "fail")
        coordinator.connect(profile: validProfile(), providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel") { error in
            XCTAssertEqual(error, .loadFailed("prefs missing"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        XCTAssertFalse(manager.started, "start must NOT be called when reload fails")
    }

    // MARK: - disconnect stops the manager

    func testDisconnectStopsManager() {
        let saver = RecordingSaver()
        let manager = RecordingManager()
        let coordinator = VPNConnectionCoordinator(saver: saver, manager: manager)
        coordinator.disconnect()
        XCTAssertTrue(manager.stopped)
    }

    // MARK: - Configuration validation failures (no save/start)

    func testEmptyHostNeverSavesOrStarts() {
        let saver = RecordingSaver()
        let manager = RecordingManager()
        let coordinator = VPNConnectionCoordinator(saver: saver, manager: manager)

        let exp = expectation(description: "fail")
        coordinator.connect(
            profile: VPNProfileInput(host: "", port: 22, username: "root", password: "x"),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        ) { error in
            XCTAssertEqual(error, .invalidConfiguration("Empty host"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(saver.saveCalls, 0)
        XCTAssertFalse(manager.started)
    }

    func testInvalidPortNeverSavesOrStarts() {
        let saver = RecordingSaver()
        let manager = RecordingManager()
        let coordinator = VPNConnectionCoordinator(saver: saver, manager: manager)

        let exp = expectation(description: "fail")
        coordinator.connect(
            profile: VPNProfileInput(host: "203.0.113.10", port: 99999, username: "root", password: "x"),
            providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel"
        ) { error in
            XCTAssertEqual(error, .invalidConfiguration("Invalid port"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(saver.saveCalls, 0)
        XCTAssertFalse(manager.started)
    }

    func testStartErrorPropagates() {
        let saver = RecordingSaver()
        let manager = RecordingManager()
        manager.startError = .startFailed("tunnel refused")
        let coordinator = VPNConnectionCoordinator(saver: saver, manager: manager)

        let exp = expectation(description: "fail")
        coordinator.connect(profile: validProfile(), providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel") { error in
            XCTAssertEqual(error, .startFailed("tunnel refused"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    // MARK: - Double-connect guard

    func testDoubleConnectWhileInFlightIsRejected() {
        let saver = RecordingSaver()
        let manager = RecordingManager()
        let coordinator = VPNConnectionCoordinator(saver: saver, manager: manager)

        // First connect: our delays keep it in-flight long enough.
        let firstExp = expectation(description: "first")
        coordinator.connect(profile: validProfile(), providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel") { _ in
            firstExp.fulfill()
        }

        // Second connect while first is in flight: must be rejected.
        let rejected = expectation(description: "rejected")
        coordinator.connect(profile: validProfile(), providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel") { error in
            XCTAssertEqual(error, .alreadyConnected)
            rejected.fulfill()
        }

        wait(for: [rejected], timeout: 2)
        wait(for: [firstExp], timeout: 2)

        // Only the first attempt should save/start.
        XCTAssertEqual(saver.saveCalls, 1, "second connect must not save again")
        XCTAssertGreaterThanOrEqual(saver.reloadCalls, 1)
    }

    func testIsBusyIsTrueWhileInFlightAndFalseAfter() {
        let saver = RecordingSaver()
        let manager = RecordingManager()
        let coordinator = VPNConnectionCoordinator(saver: saver, manager: manager)

        XCTAssertFalse(coordinator.isBusy, "not busy before connect")
        let exp = expectation(description: "connect")
        coordinator.connect(profile: validProfile(), providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel") { _ in
            exp.fulfill()
        }
        // Immediately after initiating, the attempt is in flight.
        XCTAssertTrue(coordinator.isBusy, "busy while in-flight")
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(coordinator.isBusy, "no longer busy after completion")
    }

    func testDoubleConnectAfterCompletionIsAllowed() {
        let saver = RecordingSaver()
        let manager = RecordingManager()
        let coordinator = VPNConnectionCoordinator(saver: saver, manager: manager)

        let exp1 = expectation(description: "first")
        coordinator.connect(profile: validProfile(), providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel") { _ in
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 2)

        // After the first completes, a second connect is permitted.
        let exp2 = expectation(description: "second")
        coordinator.connect(profile: validProfile(), providerBundleIdentifier: "com.sshtunnel.app.packet-tunnel") { error in
            XCTAssertNil(error)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 2)

        XCTAssertEqual(saver.saveCalls, 2, "two sequential connects should each save once")
    }
}
