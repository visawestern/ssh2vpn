import XCTest
@testable import VPNCore

final class GatewayCommandBuilderTests: XCTestCase {
    func testPythonCommandContainsOnlyBase64ScriptAndNoShellScriptText() {
        let command = GatewayCommandBuilder.pythonInline(script: Data("print('ready')".utf8))
        XCTAssertTrue(command.hasPrefix("python3 -c "))
        XCTAssertTrue(command.contains("cHJpbnQoJ3JlYWR5Jyk="))
        XCTAssertFalse(command.contains("print('ready')"))
        XCTAssertFalse(command.contains("ssh -D"))
    }
}
