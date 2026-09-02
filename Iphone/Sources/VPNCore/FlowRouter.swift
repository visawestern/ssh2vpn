import Foundation

public struct FlowRouter: Sendable {
    public let transportCount: Int
    private var assignments: [UInt64: Int] = [:]
    private var nextTransport = 0

    public init(transportCount: Int) {
        self.transportCount = max(1, transportCount)
    }

    public mutating func transport(for streamID: UInt64) -> Int {
        if let assigned = assignments[streamID] { return assigned }
        let assigned = nextTransport % transportCount
        nextTransport = (nextTransport + 1) % transportCount
        assignments[streamID] = assigned
        return assigned
    }

    public mutating func close(streamID: UInt64) {
        assignments.removeValue(forKey: streamID)
    }

    public func isAssigned(_ streamID: UInt64) -> Bool {
        assignments[streamID] != nil
    }
}
