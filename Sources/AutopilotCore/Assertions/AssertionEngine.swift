import Foundation

public struct AssertionEngine {
    public init() {}

    /// Outcome of a polled assertion: whether it matched, and the last observed value.
    public struct PollOutcome { public var matched: Bool; public var actual: String }

    /// Re-evaluate `op` against the value returned by `readActual` on the same
    /// poll cadence used for element presence, succeeding as soon as it matches
    /// and only failing at timeout. This removes the one-shot race where a
    /// control's AX value updates a beat after the action that triggered it.
    /// Returns the final match state and the last value observed.
    public func pollEvaluate(op: AssertOp, expected: String,
                             timeoutMs: Int, intervalMs: Int,
                             clock: Clock = SystemClock(),
                             readActual: () -> String) -> PollOutcome {
        let poller = Poller(clock: clock)
        var last = ""
        let matched = poller.waitUntil(timeoutMs: timeoutMs, intervalMs: intervalMs) {
            last = readActual()
            return evaluate(op: op, actual: last, expected: expected)
        }
        return PollOutcome(matched: matched, actual: last)
    }

    /// Pure comparison. `exists`/`notExists` are handled by the runner (element presence),
    /// not here. Numeric ops parse both sides as Double; non-numeric => false.
    public func evaluate(op: AssertOp, actual: String, expected: String) -> Bool {
        switch op {
        case .equals: return actual == expected
        case .notEquals: return actual != expected
        case .contains: return actual.contains(expected)
        case .matches:
            guard let re = try? NSRegularExpression(pattern: expected) else { return false }
            let range = NSRange(actual.startIndex..., in: actual)
            return re.firstMatch(in: actual, range: range) != nil
        case .greaterThan:
            guard let a = Double(actual), let b = Double(expected) else { return false }
            return a > b
        case .lessThan:
            guard let a = Double(actual), let b = Double(expected) else { return false }
            return a < b
        case .exists, .notExists:
            return false // presence handled by runner
        }
    }
}
