import Foundation

/// Pixel mapping for the bundled `world_map` asset (1920x954 canvas).
///
/// The asset is a decorative, hand-distorted drawing — not a true geographic
/// projection (continents are drawn at slightly different scales, verified
/// pixel-by-pixel against coastlines). A single linear frame misplaces dots
/// by up to ~170px (e.g. the US dot landed in the Atlantic). So the mapping
/// is piecewise-linear through measured anchor points, forward-only
/// (lon/lat -> pixel; the table intentionally folds where the drawing does).
///
/// Anchors: (real lon/lat of a sharp coastal feature -> drawn pixel).
/// Re-measure with `python3` + PIL if the asset is ever replaced.
public enum MapProjection {
    public static let canvasWidth: Double = 1920
    public static let canvasHeight: Double = 954

    /// Real longitude -> drawn x (px on the 1920 canvas). Sorted by lon.
    static let xNodes: [(lon: Double, x: Double)] = [
        (-124.2, 122),   // US west coast (NorCal)
        (-77.5, 323),    // Peru coast (Lima)
        (-75.5, 366),    // US east coast (Hatteras)
        (-67.5, 471),    // US east coast (Maine)
        (-34.9, 573),    // Brazil east tip (Recife)
        (-17.4, 688),    // Dakar peninsula
        (-9.3, 738),     // Iberia west coast
        (1.5, 794),      // UK east coast (Dover)
        (5.2, 848),      // Norway west coast
        (19.5, 893.5),   // Cape Agulhas
        (26.0, 935),     // North Cape
        (45.0, 1150),    // Arabia south coast (Aden) — folds vs Horn, see below
        (51.3, 1085),    // Horn of Africa tip (Guardafui)
        (72.8, 1257),    // India west coast (Mumbai)
        (77.5, 1321),    // India tip (Kanyakumari)
        (99.0, 1352),    // Malay Peninsula west coast
        (103.8, 1395),   // Malay tip (Singapore)
        (109.0, 1487),   // Vietnam east coast
        (115.8, 1431),   // Australia west coast (Perth)
        (130.8, 1520),   // Australia north coast (Darwin)
        (140.5, 1554),   // Honshu east coast (Tokyo)
        (146.5, 1564),   // Tasmania south
        (151.3, 1642),   // Australia east coast (Sydney)
        (162.0, 1573),   // Kamchatka east coast
        (178.0, 1748),   // NZ/Fiji compromise (see dotOverrides for exact)
    ]

    /// Real latitude -> drawn y (px on the 954 canvas). Sorted by lat desc.
    static let yNodes: [(lat: Double, y: Double)] = [
        (71.0, 58),      // North Cape
        (65.0, 118),     // Iceland
        (55.0, 159),     // Labrador/Hudson area
        (52.0, 180),     // Dover latitude
        (44.0, 231),     // Maine latitude
        (40.0, 257),     // NorCal latitude
        (38.0, 270),     // Iberia latitude
        (35.9, 285),     // Tokyo latitude
        (35.2, 288),     // Hatteras latitude
        (19.0, 394),     // Mumbai latitude
        (14.7, 430),     // Dakar latitude
        (12.2, 439),     // Vietnam coast latitude
        (8.1, 456),      // Kanyakumari latitude
        (1.35, 476),     // Singapore latitude
        (-8.1, 570),     // Recife latitude
        (-12.0, 595),    // Lima latitude
        (-32.0, 725),    // Perth latitude
        (-34.0, 738),    // Sydney latitude
        (-34.8, 764),    // Agulhas latitude
        (-37.7, 795),    // NZ latitude
        (-43.6, 799),    // Tasmania latitude
        (-54.5, 884),    // South America tip
    ]

    /// Explicit dot positions (fractions of canvas w/h) for countries where
    /// even the calibrated mapping misses — micro-islands and the distorted
    /// Arabia/Horn corner. Measured off the asset, same as the anchors.
    static let dotOverrides: [String: (fx: Double, fy: Double)] = [
        "YE": (1190.0 / 1920, 408.0 / 954),   // Yemen (drawn Arabia)
        "SO": (1050.0 / 1920, 500.0 / 954),   // Somalia (Mogadishu coast)
        "DJ": (1103.0 / 1920, 445.0 / 954),   // Djibouti
        "CU": (365.0 / 1920, 392.0 / 954),    // Cuba island
        "JM": (367.0 / 1920, 397.0 / 954),    // Jamaica
        "PR": (442.0 / 1920, 396.0 / 954),    // Puerto Rico
        "BS": (415.0 / 1920, 375.0 / 954),    // Bahamas
        "VN": (1460.0 / 1920, 426.0 / 954),   // Vietnam (long N-S coast)
        "PH": (1570.0 / 1920, 415.0 / 954),   // Luzon
        "TW": (1540.0 / 1920, 358.0 / 954),   // Taiwan
        "KR": (1502.0 / 1920, 318.0 / 954),   // Korea peninsula
        "FJ": (1704.0 / 1920, 586.0 / 954),   // Fiji blob
        "NZ": (1715.0 / 1920, 810.0 / 954),   // between the two islands
        "ID": (1540.0 / 1920, 530.0 / 954),   // Sulawesi mass
        "BN": (1505.0 / 1920, 485.0 / 954),   // Brunei
        "CV": (625.0 / 1920, 420.0 / 954),    // Cape Verde
        "VU": (1665.0 / 1920, 588.0 / 954),   // Vanuatu chain
        "NC": (1662.0 / 1920, 642.0 / 954),   // New Caledonia
        "SB": (1640.0 / 1920, 552.0 / 954),   // Solomons chain
    ]

    // MARK: - API

    /// Canvas pixel for geo coords (clamped to the canvas).
    public static func canvasPoint(lon: Double, lat: Double) -> (x: Double, y: Double) {
        (x: clamp(lerp(xNodes.map { ($0.lon, $0.x) }, lon), 0, canvasWidth),
         y: clamp(lerp(yNodes.map { ($0.lat, $0.y) }, lat), 0, canvasHeight))
    }

    /// Map dot for a server: override wins (distorted areas), else projection
    /// from the country centroid. Output is canvas pixels; scale to view size.
    public static func dotPoint(countryCode: String, lon: Double, lat: Double) -> (x: Double, y: Double) {
        if let o = dotOverrides[countryCode.uppercased()] {
            return (o.fx * canvasWidth, o.fy * canvasHeight)
        }
        return canvasPoint(lon: lon, lat: lat)
    }

    /// Canvas pixel scaled into a live view size (keeps the call sites tiny).
    public static func viewPoint(lon: Double, lat: Double, mapWidth: Double, mapHeight: Double,
                                 countryCode: String? = nil) -> (x: Double, y: Double) {
        let p: (x: Double, y: Double)
        if let cc = countryCode, !cc.isEmpty {
            p = dotPoint(countryCode: cc, lon: lon, lat: lat)
        } else {
            p = canvasPoint(lon: lon, lat: lat)
        }
        return (p.x / canvasWidth * mapWidth, p.y / canvasHeight * mapHeight)
    }

    // MARK: - Internals

    static func lerp(_ nodes: [(k: Double, v: Double)], _ key: Double) -> Double {
        let nodes = nodes.sorted { $0.k < $1.k }
        guard let first = nodes.first, let last = nodes.last else { return 0 }
        if key <= first.k { // extrapolate first segment
            guard nodes.count > 1, nodes[1].k != first.k else { return first.v }
            let s = nodes[1]
            let slope = (s.v - first.v) / (s.k - first.k)
            return first.v + (key - first.k) * slope
        }
        if key >= last.k { // extrapolate last segment
            guard nodes.count > 1 else { return last.v }
            let p = nodes[nodes.count - 2]
            guard last.k != p.k else { return last.v }
            let slope = (last.v - p.v) / (last.k - p.k)
            return last.v + (key - last.k) * slope
        }
        for i in 1 ..< nodes.count {
            let a = nodes[i - 1], b = nodes[i]
            if key <= b.k {
                guard b.k != a.k else { return a.v }
                let f = (key - a.k) / (b.k - a.k)
                return a.v + f * (b.v - a.v)
            }
        }
        return last.v
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}
