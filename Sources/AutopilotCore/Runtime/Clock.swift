import Foundation

/// Injectable time source so polling/timeout logic is testable without real sleeps.
public protocol Clock: Sendable {
    /// Seconds since an arbitrary fixed reference; monotonic.
    func now() -> TimeInterval
    /// Sleep for the given duration.
    func sleep(_ seconds: TimeInterval)
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
