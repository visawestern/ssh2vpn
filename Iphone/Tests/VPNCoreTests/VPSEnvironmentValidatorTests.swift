import Network
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import VPNCore

final class VPSEnvironmentValidatorTests: XCTestCase {
    private func makeValidator(
        uname: @escaping () throws -> String = { "Linux host 6.1.30 aarch64 GNU/Linux" },
        osRelease: (() throws -> String)? = { "Ubuntu 22.04.3 LTS" },
        python: @escaping () throws -> String = { "Python 3.10.12 (main, Jun 11 2023)" },
        reachable: @escaping (String, Int, TimeInterval) throws -> Void = { _, _, _ in }
    ) -> VPSEnvironmentValidator {
        VPSEnvironmentValidator(
            unameText: uname,
            osReleaseText: osRelease,
            pythonVersionText: python,
            reachability: reachable
        )
    }

    func testValidatorAcceptsLinuxAarch64() throws {
        let environment = try makeValidator().validate(host: "203.0.113.5", port: 22, timeout: 1)
        XCTAssertEqual(environment.osFamily, "linux")
        XCTAssertEqual(environment.architecture, "aarch64")
        XCTAssertEqual(environment.pythonVersion, "3.10.12")
    }

    func testValidatorAcceptsLinuxX86_64() throws {
        let environment = try makeValidator(uname: { "Linux host 5.15.0-91-generic x86_64 GNU/Linux" })
            .validate(host: "203.0.113.6", port: 22, timeout: 1)
        XCTAssertEqual(environment.architecture, "x86_64")
    }

    func testOSFamilyAndLibcExtracted() throws {
        let glibc = try makeValidator().validate(host: "h", port: 22, timeout: 1)
        XCTAssertEqual(glibc.libc, "glibc")
        let musl = try makeValidator(osRelease: { "Alpine Linux v3.18" })
            .validate(host: "h", port: 22, timeout: 1)
        XCTAssertEqual(musl.libc, "musl")
        let unknown = try makeValidator(osRelease: nil)
            .validate(host: "h", port: 22, timeout: 1)
        XCTAssertNil(unknown.libc)
    }

    func testValidatorRejectsDarwinOS() {
        XCTAssertThrowsError(
            try makeValidator(uname: { "Darwin host 23.3.0 arm64" }).validate(host: "h", port: 22, timeout: 1)
        ) { error in
            XCTAssertEqual(error as? VPSValidationError, .unsupportedOS)
        }
    }

    func testValidatorRejectsUnknownOS() {
        XCTAssertThrowsError(
            try makeValidator(uname: { "FreeBSD host 13.2 amd64" }).validate(host: "h", port: 22, timeout: 1)
        ) { error in
            XCTAssertEqual(error as? VPSValidationError, .unsupportedOS)
        }
    }

    func testValidatorRejectsUnsupportedArchitecture() {
        XCTAssertThrowsError(
            try makeValidator(uname: { "Linux host armv7l GNU/Linux" }).validate(host: "h", port: 22, timeout: 1)
        ) { error in
            XCTAssertEqual(error as? VPSValidationError, .unsupportedArchitecture)
        }
    }

    func testPythonMinimumVersionEnforced() throws {
        for accepted in ["Python 3.8.0", "Python 3.9", "Python 3.12.1 (main)"] {
            let environment = try makeValidator(python: { accepted }).validate(host: "h", port: 22, timeout: 1)
            XCTAssertFalse(environment.pythonVersion.isEmpty)
        }
        for rejected in ["Python 3.7.16", "Python 2.7.18", "Python 3.7"] {
            XCTAssertThrowsError(
                try makeValidator(python: { rejected }).validate(host: "h", port: 22, timeout: 1)
            ) { error in
                XCTAssertEqual(error as? VPSValidationError, .unsupportedPython)
            }
        }
    }

    func testPythonGarbageRejected() {
        XCTAssertThrowsError(
            try makeValidator(python: { "python3: command not found" }).validate(host: "h", port: 22, timeout: 1)
        ) { error in
            XCTAssertEqual(error as? VPSValidationError, .unsupportedPython)
        }
    }

    func testValidationOrderOSBeforeArchitectureBeforePython() {
        let uname = "Darwin host x86_64"
        XCTAssertThrowsError(
            try makeValidator(uname: { uname }, python: { "Python 2.7.18" })
                .validate(host: "h", port: 22, timeout: 1)
        ) { error in
            XCTAssertEqual(error as? VPSValidationError, .unsupportedOS)
        }
        XCTAssertThrowsError(
            try makeValidator(uname: { "Linux host armv7l" }, python: { "Python 2.7.18" })
                .validate(host: "h", port: 22, timeout: 1)
        ) { error in
            XCTAssertEqual(error as? VPSValidationError, .unsupportedArchitecture)
        }
    }

    func testValidatorReportsUnreachableHost() {
        let port = makeClosedTCPPort()
        let validator = makeValidator(reachable: VPSEnvironmentValidator.defaultReachability)
        XCTAssertThrowsError(try validator.validate(host: "127.0.0.1", port: port, timeout: 0.4)) { error in
            XCTAssertEqual(error as? VPSValidationError, .unreachable)
        }
    }

    func testReachabilitySucceedsAgainstLocalListener() throws {
        let server = try makeTCPServer()
        defer { server.close() }
        let validator = makeValidator(reachable: VPSEnvironmentValidator.defaultReachability)
        _ = try validator.validate(host: "127.0.0.1", port: server.port, timeout: 1)
    }

    func testSkipRunsReachabilityOnly() throws {
        var pythonCalled = false
        var reachCalled = false
        var validator = makeValidator(
            python: { pythonCalled = true; return "Python 3.10.12" },
            reachable: { _, _, _ in reachCalled = true }
        )
        validator.skip = true
        _ = try validator.validate(host: "h", port: 22, timeout: 1)
        XCTAssertTrue(reachCalled)
        XCTAssertFalse(pythonCalled, "skip must bypass evidence collection")
    }

    func testCacheHitSkipsEvidenceClosures() throws {
        var pythonCalls = 0
        var validator = makeValidator(python: {
            pythonCalls += 1
            return "Python 3.10.12"
        })
        _ = try validator.validate(host: "cache-host", port: 22, timeout: 1)
        _ = try validator.validate(host: "cache-host", port: 22, timeout: 1)
        XCTAssertEqual(pythonCalls, 1, "classification must be cached per fingerprint")
    }

    func testCacheKeyDistinguishesHosts() throws {
        var pythonCalls = 0
        var validator = makeValidator(python: {
            pythonCalls += 1
            return "Python 3.10.12"
        })
        _ = try validator.validate(host: "host-a", port: 22, timeout: 1)
        _ = try validator.validate(host: "host-b", port: 22, timeout: 1)
        XCTAssertEqual(pythonCalls, 2)
    }

    func testReachabilityRunsEvenWhenClassificationCached() throws {
        var reachCalls = 0
        var validator = makeValidator(reachable: { _, _, _ in reachCalls += 1 })
        _ = try validator.validate(host: "cache-host", port: 22, timeout: 1)
        _ = try validator.validate(host: "cache-host", port: 22, timeout: 1)
        XCTAssertEqual(reachCalls, 2, "reachability is never cached, only classification")
    }

    func testCacheSkipsFailedClassifications() throws {
        var pythonCalls = 0
        var validator = makeValidator(python: {
            pythonCalls += 1
            if pythonCalls == 1 { return "Python 2.7.18" }
            return "Python 3.10.12"
        })
        XCTAssertThrowsError(try validator.validate(host: "h", port: 22, timeout: 1))
        _ = try validator.validate(host: "h", port: 22, timeout: 1)
        XCTAssertEqual(pythonCalls, 2, "failed classifications must not be cached")
    }

    func testConcurrentValidationsAreSafe() throws {
        var pythonCalls = 0
        let validator = makeValidator(python: {
            Thread.sleep(forTimeInterval: 0.02)
            pythonCalls += 1
            return "Python 3.10.12"
        })
        let group = DispatchGroup()
        let lock = NSLock()
        let queue = DispatchQueue(label: "test-concurrent", attributes: .concurrent)
        var results: [Error?] = []
        for _ in 0..<8 {
            group.enter()
            queue.async {
                let result = Result { _ = try validator.validate(host: "same-host", port: 22, timeout: 1) }
                lock.lock(); results.append(result.failure); lock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        lock.lock(); defer { lock.unlock() }
        XCTAssertTrue(results.allSatisfy { $0 == nil })
        XCTAssertEqual(pythonCalls, 1, "concurrent validation must classify once")
    }

    private func makeTCPServer() throws -> (port: Int, close: () -> Void) {
        let listener = try NWListener(using: .tcp, on: .any)
        let semaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { semaphore.signal() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
        }
        listener.start(queue: .global())
        guard semaphore.wait(timeout: .now() + 2) == .success else {
            listener.cancel()
            throw XCTSkip("cannot bind local listener")
        }
        let port = Int(listener.port?.rawValue ?? 0)
        return (port, { listener.cancel() })
    }

    private func makeClosedTCPPort() -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketFD) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        _ = length
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}