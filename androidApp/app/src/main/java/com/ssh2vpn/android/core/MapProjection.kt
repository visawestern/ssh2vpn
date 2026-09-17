package com.ssh2vpn.android.core

/** Порт MapProjection.swift: калибровка под ТОТ ЖЕ world_map 1920x954 (копия ассета в drawable-nodpi). */
object MapProjection {
    const val CANVAS_W = 1920.0
    const val CANVAS_H = 954.0

    private val xNodes: List<Pair<Double, Double>> = listOf(
        -124.2 to 122.0,
        -77.5 to 323.0,
        -75.5 to 366.0,
        -67.5 to 471.0,
        -34.9 to 573.0,
        -17.4 to 688.0,
        -9.3 to 738.0,
        1.5 to 794.0,
        5.2 to 848.0,
        19.5 to 893.5,
        26.0 to 935.0,
        45.0 to 1150.0,
        51.3 to 1085.0,
        72.8 to 1257.0,
        77.5 to 1321.0,
        99.0 to 1352.0,
        103.8 to 1395.0,
        109.0 to 1487.0,
        115.8 to 1431.0,
        130.8 to 1520.0,
        140.5 to 1554.0,
        146.5 to 1564.0,
        151.3 to 1642.0,
        162.0 to 1573.0,
        178.0 to 1748.0
    )
    private val yNodes: List<Pair<Double, Double>> = listOf(
        71.0 to 58.0,
        65.0 to 118.0,
        55.0 to 159.0,
        52.0 to 180.0,
        44.0 to 231.0,
        40.0 to 257.0,
        38.0 to 270.0,
        35.9 to 285.0,
        35.2 to 288.0,
        19.0 to 394.0,
        14.7 to 430.0,
        12.2 to 439.0,
        8.1 to 456.0,
        1.35 to 476.0,
        -8.1 to 570.0,
        -12.0 to 595.0,
        -32.0 to 725.0,
        -34.0 to 738.0,
        -34.8 to 764.0,
        -37.7 to 795.0,
        -43.6 to 799.0,
        -54.5 to 884.0
    )
    private val dotOverrides: Map<String, Pair<Double, Double>> = mapOf(
        "YE" to (1190.0 / 1920 * 1920 to 408.0 / 954 * 954),
        "SO" to (1050.0 / 1920 * 1920 to 500.0 / 954 * 954),
        "DJ" to (1103.0 / 1920 * 1920 to 445.0 / 954 * 954),
        "CU" to (365.0 / 1920 * 1920 to 392.0 / 954 * 954),
        "JM" to (367.0 / 1920 * 1920 to 397.0 / 954 * 954),
        "PR" to (442.0 / 1920 * 1920 to 396.0 / 954 * 954),
        "BS" to (415.0 / 1920 * 1920 to 375.0 / 954 * 954),
        "VN" to (1460.0 / 1920 * 1920 to 426.0 / 954 * 954),
        "PH" to (1570.0 / 1920 * 1920 to 415.0 / 954 * 954),
        "TW" to (1540.0 / 1920 * 1920 to 358.0 / 954 * 954),
        "KR" to (1502.0 / 1920 * 1920 to 318.0 / 954 * 954),
        "FJ" to (1704.0 / 1920 * 1920 to 586.0 / 954 * 954),
        "NZ" to (1715.0 / 1920 * 1920 to 810.0 / 954 * 954),
        "ID" to (1540.0 / 1920 * 1920 to 530.0 / 954 * 954),
        "BN" to (1505.0 / 1920 * 1920 to 485.0 / 954 * 954),
        "CV" to (625.0 / 1920 * 1920 to 420.0 / 954 * 954),
        "VU" to (1665.0 / 1920 * 1920 to 588.0 / 954 * 954),
        "NC" to (1662.0 / 1920 * 1920 to 642.0 / 954 * 954),
        "SB" to (1640.0 / 1920 * 1920 to 552.0 / 954 * 954),
    )
    fun canvasPoint(lon: Double, lat: Double): Pair<Double, Double> {
        val x = lerp(xNodes, lon).coerceIn(0.0, CANVAS_W)
        val y = lerp(yNodes, lat).coerceIn(0.0, CANVAS_H)
        return x to y
    }
    fun dotPoint(countryCode: String, lon: Double, lat: Double): Pair<Double, Double> {
        // Оверрайды в iOS уже даны в пикселях канвы (x/1920*1920) — храним как есть.
        dotOverrides[countryCode.uppercase()]?.let { return it }
        return canvasPoint(lon, lat)
    }
    fun viewPoint(lon: Double, lat: Double, mapW: Double, mapH: Double, countryCode: String? = null): Pair<Double, Double> {
        val p = if (!countryCode.isNullOrEmpty()) dotPoint(countryCode, lon, lat) else canvasPoint(lon, lat)
        return p.first / CANVAS_W * mapW to p.second / CANVAS_H * mapH
    }
    internal fun lerp(nodes: List<Pair<Double, Double>>, key: Double): Double {
        val s = nodes.sortedBy { it.first }
        val first = s.firstOrNull() ?: return 0.0
        val last = s.lastOrNull() ?: return 0.0
        if (key <= first.first) {
            if (s.size < 2 || s[1].first == first.first) return first.second
            val slope = (s[1].second - first.second) / (s[1].first - first.first)
            return first.second + (key - first.first) * slope
        }
        if (key >= last.first) {
            if (s.size < 2) return last.second
            val p = s[s.size - 2]
            if (last.first == p.first) return last.second
            val slope = (last.second - p.second) / (last.first - p.first)
            return last.second + (key - last.first) * slope
        }
        for (i in 1 until s.size) {
            val a = s[i - 1]; val b = s[i]
            if (key <= b.first) {
                if (b.first == a.first) return a.second
                val f = (key - a.first) / (b.first - a.first)
                return a.second + f * (b.second - a.second)
            }
        }
        return last.second
    }
}
