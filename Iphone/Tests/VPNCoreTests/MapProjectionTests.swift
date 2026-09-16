import XCTest
@testable import VPNCore

final class MapProjectionTests: XCTestCase {
    private func assertCanvas(lon: Double, lat: Double, x: Double, y: Double,
                              dx: Double = 18, dy: Double = 18, msg: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        let p = MapProjection.canvasPoint(lon: lon, lat: lat)
        XCTAssertEqual(p.x, x, accuracy: dx, "\(msg) x for (\(lon),\(lat))", file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: dy, "\(msg) y for (\(lon),\(lat))", file: file, line: line)
    }

    func testAnchorsReproduce() {
        // (lon, lat) -> measured drawn pixel. Tolerance covers my ±10px reads.
        assertCanvas(lon: -124.2, lat: 40.0, x: 122, y: 257, msg: "NorCal")
        assertCanvas(lon: -98.5, lat: 39.8, x: 233, y: 258, dx: 25, msg: "Kansas")
        assertCanvas(lon: -67.5, lat: 44.0, x: 471, y: 231, msg: "Maine")
        assertCanvas(lon: -77.5, lat: -12.0, x: 323, y: 595, msg: "Lima")
        assertCanvas(lon: -34.9, lat: -8.1, x: 573, y: 570, msg: "Recife")
        assertCanvas(lon: -9.3, lat: 38.0, x: 738, y: 270, msg: "Iberia")
        assertCanvas(lon: 1.5, lat: 51.5, x: 794, y: 180, msg: "Dover")
        assertCanvas(lon: 51.3, lat: 11.8, x: 1085, y: 470, dy: 30, msg: "Horn")
        assertCanvas(lon: 103.8, lat: 1.35, x: 1395, y: 476, msg: "Singapore")
        assertCanvas(lon: 140.5, lat: 35.9, x: 1554, y: 285, msg: "Tokyo")
        assertCanvas(lon: 151.3, lat: -34.0, x: 1642, y: 738, msg: "Sydney")
        assertCanvas(lon: 178.3, lat: -37.7, x: 1744, y: 795, dx: 25, msg: "NZ")
    }

    func testOldLinearFrameWouldMiss() {
        // Regression: the pre-calibration linear frame put Kansas in the
        // Atlantic (~x 416). The calibrated dot must sit well west of that.
        let p = MapProjection.canvasPoint(lon: -98.58, lat: 39.83)
        XCTAssertLessThan(p.x, 300, "Kansas dot must stay over the continent")
        XCTAssertGreaterThan(p.x, 150, "Kansas dot must not slide into the Pacific")
    }

    func testTablesAreSane() {
        let xs = MapProjection.xNodes.map(\.lon)
        XCTAssertEqual(xs, xs.sorted(), "x nodes must be sorted by lon")
        let ys = MapProjection.yNodes.map(\.lat)
        XCTAssertEqual(ys, ys.sorted(by: >), "y nodes must be sorted by lat desc")
        let yv = MapProjection.yNodes.map(\.y)
        XCTAssertEqual(yv, yv.sorted(), "y values must rise as lat falls")
    }

    func testClampsToCanvas() {
        for lon in [-200.0, -180.0, 0.0, 180.0, 200.0] {
            for lat in [-90.0, -60.0, 0.0, 80.0, 90.0] {
                let p = MapProjection.canvasPoint(lon: lon, lat: lat)
                XCTAssertTrue((0 ... MapProjection.canvasWidth).contains(p.x), "x clamp \(lon)")
                XCTAssertTrue((0 ... MapProjection.canvasHeight).contains(p.y), "y clamp \(lat)")
            }
        }
    }

    func testOverridesWin() {
        // Yemen: raw projection lands in the strait, override sits on Arabia.
        let raw = MapProjection.canvasPoint(lon: 48.0, lat: 15.5)
        let dot = MapProjection.dotPoint(countryCode: "YE", lon: 48.0, lat: 15.5)
        XCTAssertNotEqual(raw.x, dot.x, accuracy: 1)
        XCTAssertEqual(dot.x, 1190, accuracy: 1)
        XCTAssertEqual(dot.y, 408, accuracy: 1)
        // Case-insensitive + unknown codes fall back to projection.
        let lower = MapProjection.dotPoint(countryCode: "ye", lon: 48.0, lat: 15.5)
        XCTAssertEqual(lower.x, dot.x, accuracy: 0.001)
        let plain = MapProjection.dotPoint(countryCode: "DE", lon: 10.45, lat: 51.17)
        let direct = MapProjection.canvasPoint(lon: 10.45, lat: 51.17)
        XCTAssertEqual(plain.x, direct.x, accuracy: 0.001)
    }

    func testViewPointScales() {
        let p = MapProjection.viewPoint(lon: 10.45, lat: 51.17, mapWidth: 960, mapHeight: 477)
        let c = MapProjection.canvasPoint(lon: 10.45, lat: 51.17)
        XCTAssertEqual(p.x, c.x / 1920 * 960, accuracy: 0.001)
        XCTAssertEqual(p.y, c.y / 954 * 477, accuracy: 0.001)
    }
}
