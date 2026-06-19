import Foundation

public enum PlanError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(String)
    case invalidTarget(String)
    case duplicateStepId(String)
    case missingTarget(stepId: String, action: String)
    case missingArgs(stepId: String, action: String, field: String)
    case includeCycle(path: String)
    case includeTooDeep(maxDepth: Int)
    case includeNotFound(path: String)
    case unsupportedKey(String)
    case tooManySteps(count: Int, max: Int)
    case decode(String)

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let v): return "Unsupported schemaVersion: \(v) (supported: 1.0)"
        case .invalidTarget(let m): return "Invalid target: \(m)"
        case .duplicateStepId(let id): return "Duplicate step id: \(id)"
        case .missingTarget(let id, let a): return "Step \(id): action '\(a)' requires a target selector"
        case .missingArgs(let id, let a, let f): return "Step \(id): action '\(a)' requires args.\(f)"
        case .includeCycle(let p): return "Include cycle detected at: \(p)"
        case .includeTooDeep(let d): return "Include nesting exceeds max depth \(d)"
        case .includeNotFound(let p): return "Included plan not found: \(p)"
        case .unsupportedKey(let k): return "Unsupported key in chord: \(k)"
        case .tooManySteps(let c, let m): return "Plan has \(c) steps, exceeding the maximum of \(m)"
        case .decode(let m): return "Plan decode error: \(m)"
        }
    }
}
