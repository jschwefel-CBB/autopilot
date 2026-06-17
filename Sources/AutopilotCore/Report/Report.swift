import Foundation

public enum StepOutcome: String, Codable, Sendable { case pass, fail, error, skipped }

public struct StepResult: Codable, Sendable {
    public var id: String
    public var result: StepOutcome
    public var durationMs: Int
    public var expected: String?
    public var actual: String?
    public var message: String?
    public var screenshot: String?
    public var axDump: String?
    public init(id: String, result: StepOutcome, durationMs: Int,
                expected: String? = nil, actual: String? = nil, message: String? = nil,
                screenshot: String? = nil, axDump: String? = nil) {
        self.id = id; self.result = result; self.durationMs = durationMs
        self.expected = expected; self.actual = actual; self.message = message
        self.screenshot = screenshot; self.axDump = axDump
    }
}

public struct PermissionStatus: Codable, Sendable {
    public var accessibility: Bool
    public var automation: Bool
    public init(accessibility: Bool, automation: Bool) {
        self.accessibility = accessibility; self.automation = automation
    }
}

public struct Report: Codable, Sendable {
    public var plan: String
    public var result: StepOutcome
    public var durationMs: Int
    public var steps: [StepResult]
    public var permissions: PermissionStatus?

    public init(plan: String) {
        self.plan = plan; self.result = .pass; self.durationMs = 0
        self.steps = []; self.permissions = nil
    }

    public mutating func add(_ step: StepResult) { steps.append(step) }

    /// Compute overall result (any fail/error => that) and total duration.
    public mutating func finalize(permissions: PermissionStatus) {
        self.permissions = permissions
        durationMs = steps.reduce(0) { $0 + $1.durationMs }
        if steps.contains(where: { $0.result == .error }) { result = .error }
        else if steps.contains(where: { $0.result == .fail }) { result = .fail }
        else { result = .pass }
    }
}
