import XCTest
@testable import VPNCore

final class VPNConnectionAutomationTests: XCTestCase {

    // MARK: - Happy path

    func testBeginConnectStartsAtAttemptOne() {
        var a = VPNConnectionAutomation()
        XCTAssertEqual(a.beginConnect(), .attemptStarted(1))
        XCTAssertEqual(a.attempt, 1)
        XCTAssertTrue(a.isConnecting)
    }

    func testMarkConnectedSetsState() {
        var a = VPNConnectionAutomation()
        _ = a.beginConnect()
        XCTAssertEqual(a.markConnected(), .connected)
        XCTAssertTrue(a.isConnected)
        XCTAssertFalse(a.isConnecting)
    }

    // MARK: - Retry on transient error (bounded to maxRetries)

    func testTransientErrorRetriesUpToMax() {
        var a = VPNConnectionAutomation(maxRetries: 3)
        _ = a.beginConnect()

        XCTAssertEqual(a.reportFailure("network timeout"), .transientFailure(2, "network timeout"))
        XCTAssertEqual(a.attempt, 2)
        XCTAssertEqual(a.reportFailure("network timeout"), .transientFailure(3, "network timeout"))
        XCTAssertEqual(a.attempt, 3)
        XCTAssertEqual(a.reportFailure("network timeout"), .gaveUpAfterRetries("network timeout"))
        XCTAssertEqual(a.attempt, 3)
    }

    func testRecoversOnRetryBeforeExhausting() {
        var a = VPNConnectionAutomation(maxRetries: 5)
        _ = a.beginConnect()
        _ = a.reportFailure("timeout")
        _ = a.reportFailure("refused")
        // Recovers on 3rd attempt.
        XCTAssertEqual(a.markConnected(), .connected)
        XCTAssertTrue(a.isConnected)
    }

    func testDefaultRetriesIsThree() {
        var a = VPNConnectionAutomation()
        XCTAssertEqual(a.maxRetries, 3)
        _ = a.beginConnect()
        XCTAssertEqual(a.reportFailure("x"), .transientFailure(2, "x"))
        XCTAssertEqual(a.reportFailure("x"), .transientFailure(3, "x"))
        XCTAssertEqual(a.reportFailure("x"), .gaveUpAfterRetries("x"))
    }

    // MARK: - Fatal error never retries

    func testFatalConfigurationErrorDoesNotRetry() {
        var a = VPNConnectionAutomation(maxRetries: 3)
        _ = a.beginConnect()
        let result = a.reportFailure("NEVPNErrorDomain Code=1 configurationInvalid")
        XCTAssertEqual(result, .fatalFailure("NEVPNErrorDomain Code=1 configurationInvalid"))
        XCTAssertEqual(a.attempt, 1, "fatal error must NOT advance the attempt counter")
    }

    func testFatalErrorIsNotRetriedEvenOnFirstAttempt() {
        var a = VPNConnectionAutomation(maxRetries: 3)
        _ = a.beginConnect()
        XCTAssertEqual(a.reportFailure("Invalid configuration"), .fatalFailure("Invalid configuration"))
    }

    func testEmptyHostIsFatal() {
        XCTAssertTrue(ConnectionErrorClassifier.isFatal("empty host"))
    }

    func testInvalidPortIsFatal() {
        XCTAssertTrue(ConnectionErrorClassifier.isFatal("invalid port"))
    }

    func testNetworkTimeoutIsNotFatal() {
        XCTAssertFalse(ConnectionErrorClassifier.isFatal("Operation timed out after 30 seconds"))
    }

    func testConnectionRefusedIsNotFatal() {
        XCTAssertFalse(ConnectionErrorClassifier.isFatal("Connection refused"))
    }

    func testSSHAuthFailedIsNotFatal() {
        // Generic/vague auth strings stay transient (could be a blip, and the
        // 10-failure breaker still caps the storm). Only the extension's
        // precise stable codes are fatal (see below).
        XCTAssertFalse(ConnectionErrorClassifier.isFatal("SSH authentication failed: bad password"))
    }

    func testTypedAuthExhaustionIsFatal() {
        XCTAssertTrue(ConnectionErrorClassifier.isFatal("authFailedExhausted: server rejected all offered credentials (wrong password/key or method not allowed) — fix credentials, no auto-retry"))
        var a = VPNConnectionAutomation(maxRetries: 3)
        _ = a.beginConnect()
        let result = a.reportFailure("authFailedExhausted: server rejected all offered credentials")
        guard case .fatalFailure = result else {
            return XCTFail("auth exhaustion must be fatal (no retry), got \(result)")
        }
        XCTAssertEqual(a.attempt, 1, "fatal error must NOT advance the attempt counter")
    }

    func testHostKeyMismatchIsFatal() {
        XCTAssertTrue(ConnectionErrorClassifier.isFatal("hostKeyMismatch: server host key differs from pinned — verify the server or update the pinned key, no auto-retry"))
    }

    func testForwardingRefusedIsFatal() {
        XCTAssertTrue(ConnectionErrorClassifier.isFatal("forwardingRefused (8.8.8.8:53): channel open rejected — check AllowTcpForwarding on server, no auto-retry"))
    }

    func testEnglishAndRussianFatalMarkers() {
        XCTAssertTrue(ConnectionErrorClassifier.isFatal("некорректная конфигурация"))
        XCTAssertTrue(ConnectionErrorClassifier.isFatal("пустой хост"))
        XCTAssertFalse(ConnectionErrorClassifier.isFatal("нет сети"))
    }

    // MARK: - Timer

    func testTickOnlyAdvancesWhileConnected() {
        var a = VPNConnectionAutomation()
        _ = a.beginConnect()
        a.tick()
        XCTAssertEqual(a.activeSeconds, 0, "tick must not advance while not connected")

        _ = a.markConnected()
        a.tick(); a.tick(); a.tick()
        XCTAssertEqual(a.activeSeconds, 3)
    }

    func testResetClearsTimer() {
        var a = VPNConnectionAutomation()
        _ = a.beginConnect()
        _ = a.markConnected()
        a.tick(); a.tick()
        XCTAssertEqual(a.activeSeconds, 2)
        a.reset()
        XCTAssertEqual(a.activeSeconds, 0)
        XCTAssertEqual(a.attempt, 0)
        XCTAssertNil(a.errorMessage)
        XCTAssertFalse(a.isConnected)
    }

    func testDisconnectClearsTimer() {
        var a = VPNConnectionAutomation()
        _ = a.beginConnect()
        _ = a.markConnected()
        a.tick(); a.tick()
        let result = a.markDisconnected()
        XCTAssertEqual(result, .disconnected)
        XCTAssertEqual(a.activeSeconds, 0)
    }

    // MARK: - Error-aware classification (VPNConfigurationError is fatal)

    func testVPNConfigurationErrorIsFatalViaTypedOverload() {
        var a = VPNConnectionAutomation(maxRetries: 3)
        _ = a.beginConnect()
        let result = a.reportFailure(VPNConfigurationError.missingCredentials)
        guard case .fatalFailure = result else {
            return XCTFail("missingCredentials must be fatal, got \(result)")
        }
        XCTAssertEqual(a.attempt, 1, "config error must NEVER advance the attempt counter")
    }

    func testAllVPNConfigurationCasesAreFatal() {
        for error in [VPNConfigurationError.emptyHost,
                      VPNConfigurationError.invalidPort,
                      VPNConfigurationError.missingCredentials,
                      VPNConfigurationError.emptyProviderBundleIdentifier] as [VPNConfigurationError] {
            var a = VPNConnectionAutomation(maxRetries: 3)
            _ = a.beginConnect()
            XCTAssertEqual(a.reportFailure(error), .fatalFailure(error.localizedDescription), "\(error) must be fatal")
        }
    }

    // MARK: - User-idiot edge cases (defensive)

    func testGenericCodeEqualOneIsNotFatalWithoutNEVPNDomain() {
        // Regression guard for BUG7: a bare "code=1" from an unrelated source
        // (e.g. "HTTP status code=1") must NOT be misclassified as fatal.
        XCTAssertFalse(ConnectionErrorClassifier.isFatal("HTTP status code=1 continues"))
        XCTAssertFalse(ConnectionErrorClassifier.isFatal("zlib error code=1"))
    }

    func testReportFailureBeforeBeginConnectReturnsTransient() {
        // Even if called out of order, logic stays bounded and safe.
        var a = VPNConnectionAutomation(maxRetries: 3)
        let r = a.reportFailure("boom")
        XCTAssertEqual(r, .transientFailure(1, "boom")) // treated as first transient attempt
    }

    func testUpperCaseFatalMarker() {
        XCTAssertTrue(ConnectionErrorClassifier.isFatal("NEVPNErrorDomain Code=1"))
    }

    func testWhitespaceFatalMarker() {
        XCTAssertTrue(ConnectionErrorClassifier.isFatal("  Invalid configuration  "))
    }

    func testDoubleMarkConnectedIsIdempotent() {
        var a = VPNConnectionAutomation()
        _ = a.beginConnect()
        _ = a.markConnected()
        XCTAssertEqual(a.markConnected(), .connected)
        XCTAssertTrue(a.isConnected)
    }
}
