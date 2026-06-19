import Foundation

public struct PlanParser {
    public static let supportedSchemaVersion = "1.0"
    public static let maxIncludeDepth = 8
    public static let maxSteps = 1000

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
        // Bound plan size — a runaway/pathological plan shouldn't be able to
        // pin a (single-threaded, serialized) MCP server indefinitely.
        if plan.steps.count > Self.maxSteps {
            throw PlanError.tooManySteps(count: plan.steps.count, max: Self.maxSteps)
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
            guard let keys = step.args?.keys else {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "keys")
            }
            // Reject an unparseable chord at parse time, not partway through a
            // live run after earlier steps already mutated app state.
            _ = try ActionEngine.parseChord(keys)
        case .scroll:
            if step.args?.deltaX == nil && step.args?.deltaY == nil {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "deltaX or deltaY")
            }
        case .assert:
            guard let a = step.assert else {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "assert")
            }
            try validateAssertion(a, stepId: step.id)
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
        case .assertPixel, .assertRegion:
            if step.args?.color == nil {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "color")
            }
            if step.target == nil && (step.args?.atX == nil || step.args?.atY == nil) {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "target or atX/atY")
            }
        case .snapshot:
            if step.args?.reference == nil {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "reference")
            }
            if step.target == nil && (step.args?.atX == nil || step.args?.atY == nil) {
                throw PlanError.missingArgs(stepId: step.id, action: step.action.rawValue, field: "target or atX/atY")
            }
        default:
            break
        }
    }

    /// Validate an assertion at parse time so a malformed comparison surfaces as
    /// a plan error rather than masquerading as a normal assertion FAILURE.
    func validateAssertion(_ a: Assertion, stepId: String) throws {
        switch a.op {
        case .exists, .notExists:
            break   // presence ops need no expected value
        case .greaterThan, .lessThan:
            guard let e = a.expected, Double(e) != nil else {
                throw PlanError.missingArgs(stepId: stepId, action: "assert",
                                            field: "expected (a number for \(a.op.rawValue))")
            }
        case .matches:
            guard let e = a.expected else {
                throw PlanError.missingArgs(stepId: stepId, action: "assert", field: "expected (a regex)")
            }
            if (try? NSRegularExpression(pattern: e)) == nil {
                throw PlanError.decode("assert step \(stepId): invalid regex '\(e)'")
            }
        case .equals, .notEquals, .contains:
            if a.expected == nil {
                throw PlanError.missingArgs(stepId: stepId, action: "assert", field: "expected")
            }
        }
    }
}
