import Foundation

public struct PlanParser {
    public static let supportedSchemaVersion = "1.0"
    public static let maxIncludeDepth = 8

    public init() {}

    /// Parse raw JSON into a validated Plan. `baseDirectory` is the directory
    /// the plan file lives in, used to resolve `include` paths (Task 4).
    public func parse(data: Data, baseDirectory: URL) throws -> Plan {
        let plan: Plan
        do {
            plan = try JSONDecoder().decode(Plan.self, from: data)
        } catch {
            throw PlanError.decode(String(describing: error))
        }
        let resolved = try resolveIncludes(plan, baseDirectory: baseDirectory,
                                           stack: [], depth: 0)
        try validate(resolved)
        return resolved
    }

    /// Resolve `include` references by prepending included steps in order.
    /// `stack` holds canonical paths of plans currently being resolved (cycle detection).
    /// Host plan's target/defaults win; included steps are prepended before host steps.
    func resolveIncludes(_ plan: Plan, baseDirectory: URL,
                         stack: [String], depth: Int) throws -> Plan {
        guard let includes = plan.include, !includes.isEmpty else { return plan }
        if depth >= Self.maxIncludeDepth { throw PlanError.includeTooDeep(maxDepth: Self.maxIncludeDepth) }

        var prependedSteps: [Step] = []
        for rel in includes {
            let url = baseDirectory.appendingPathComponent(rel)
            let canonical = url.standardizedFileURL.path
            if stack.contains(canonical) { throw PlanError.includeCycle(path: canonical) }
            guard FileManager.default.fileExists(atPath: canonical) else {
                // Show both the declared string and what it resolved to on disk,
                // so the "relative to the plan file" rule is obvious from the error.
                throw PlanError.includeNotFound(path: "\(rel) (resolved to \(canonical))")
            }
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { throw PlanError.includeNotFound(path: rel) }
            let child: Plan
            do { child = try JSONDecoder().decode(Plan.self, from: data) }
            catch { throw PlanError.decode("in included \(rel): \(error)") }
            let resolvedChild = try resolveIncludes(
                child, baseDirectory: url.deletingLastPathComponent(),
                stack: stack + [canonical], depth: depth + 1)
            prependedSteps.append(contentsOf: resolvedChild.steps)
        }

        var flattened = plan
        flattened.steps = prependedSteps + plan.steps
        flattened.include = nil
        return flattened
    }

    func validate(_ plan: Plan) throws {
        guard plan.schemaVersion == Self.supportedSchemaVersion else {
            throw PlanError.unsupportedSchemaVersion(plan.schemaVersion)
        }
        if (plan.target.bundleId?.isEmpty ?? true) && (plan.target.path?.isEmpty ?? true) {
            throw PlanError.invalidTarget("must set either bundleId or path")
        }
        var seen = Set<String>()
        for step in plan.steps {
            if !seen.insert(step.id).inserted {
                throw PlanError.duplicateStepId(step.id)
            }
            try validateStep(step)
        }
    }

    private static let targetRequiringActions: Set<Action> = [
        .click, .doubleClick, .rightClick, .press, .type, .keyPress, .setValue,
        .scroll, .waitFor, .assert
    ]

    func validateStep(_ step: Step) throws {
        if Self.targetRequiringActions.contains(step.action), step.target == nil {
            throw PlanError.missingTarget(stepId: step.id, action: step.action.rawValue)
        }
        switch step.action {
        case .type, .setValue:
            if step.args?.text == nil {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "text")
            }
        case .keyPress:
            if step.args?.keys == nil {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "keys")
            }
        case .assert:
            if step.assert == nil {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "assert")
            }
        case .wait:
            if step.args?.seconds == nil {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "seconds")
            }
        case .menu:
            if step.args?.menuPath?.isEmpty ?? true {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "menuPath")
            }
        case .drag:
            if step.args?.to == nil && step.args?.toFiles == nil {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "to or toFiles")
            }
        default:
            break
        }
    }
}
