import Foundation

/// Wraparound-safe TCP sequence number arithmetic.
///
/// TCP sequence space is UInt32 with modular arithmetic.  Comparisons must
/// use signed distance, not raw `<`/`>`, because 0xFFFFFFFF < 0x00000001
/// numerically but the opposite is true in sequence space.
enum TCPSequence {
    /// True when `a` is strictly before `b` in sequence space.
    static func lessThan(_ a: UInt32, _ b: UInt32) -> Bool {
        Int32(bitPattern: a &- b) < 0
    }

    /// True when `a` is at or before `b` in sequence space.
    static func lessThanOrEqual(_ a: UInt32, _ b: UInt32) -> Bool {
        Int32(bitPattern: a &- b) <= 0
    }

    /// True when `a` is strictly after `b` in sequence space.
    static func greaterThan(_ a: UInt32, _ b: UInt32) -> Bool {
        Int32(bitPattern: a &- b) > 0
    }

    /// True when `a` is within [left, right] (inclusive, wraparound-safe).
    static func inRange(_ a: UInt32, left: UInt32, right: UInt32) -> Bool {
        if left == right { return a == left }
        if Int32(bitPattern: left &- right) < 0 {
            // left <= right (no wrap): a in [left, right]
            return lessThanOrEqual(left, a) && lessThanOrEqual(a, right)
        } else {
            // left > right (wrap): a in [left, UInt32.max] ∪ [0, right]
            return lessThanOrEqual(left, a) || lessThanOrEqual(a, right)
        }
    }

    /// Distance from `a` to `b` in sequence space (may be negative).
    static func distance(from a: UInt32, to b: UInt32) -> Int32 {
        Int32(bitPattern: b &- a)
    }

    /// Advance `seq` by `n` bytes, wrapping as needed.
    static func advance(_ seq: UInt32, by n: UInt32) -> UInt32 {
        seq &+ n
    }
}
