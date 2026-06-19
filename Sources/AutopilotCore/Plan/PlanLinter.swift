import Foundation

/// Static analysis of a plan beyond schema validity — flags the documented
/// footguns so authors catch them before a run.
public struct PlanLinter {
    public enum Severity: String, Sendable { case warning, error }
    public struct Finding: Sendable, Equatable {
        public var severity: Severity
        public var stepId: String?
        public var message: String
    }

    public init() {}

    /// Lint a (already schema-valid) plan. Returns findings in document order.
    public func lint(_ plan: Plan) -> [Finding] {
        var findings: [Finding] = []

        // Non-functional selector fields (documented as not working).
        for step in plan.steps {
            if let sel = step.target {
                if sel.label != nil {
                    findings.append(.init(severity: .warning, stepId: step.id,
                        message: "selector uses `label`, which is non-functional — use `identifier`, `title`, or `value`"))
                }
                if sel.path != nil {
                    findings.append(.init(severity: .warning, stepId: step.id,
                        message: "selector uses `path`, which is non-functional — it is silently ignored"))
                }
            }
        }

        // Visual actions whose missing args only bite at runtime get flagged here
        // too (parse already rejects them, but lint surfaces them with context).
        for step in plan.steps {
            if (step.action == .assertPixel || step.action == .assertRegion), step.args?.color == nil {
                findings.append(.init(severity: .error, stepId: step.id,
                    message: "\(step.action.rawValue) needs args.color (#RRGGBB)"))
            }
            if step.action == .snapshot, step.args?.reference == nil {
                findings.append(.init(severity: .error, stepId: step.id,
                    message: "snapshot needs args.reference"))
            }
        }

        // Missing terminate as the last step → leaks an app instance.
        if let last = plan.steps.last, last.action != .terminate {
            findings.append(.init(severity: .warning, stepId: nil,
                message: "plan does not end with a `terminate` step — the app will be left running"))
        }

        // captureTarget: true on a step with no target selector is a no-op.
        for step in plan.steps {
            if step.captureTarget == true, step.target == nil {
                findings.append(.init(severity: .warning, stepId: step.id,
                    message: "`captureTarget: true` has no effect — this step has no `target` selector"))
            }
        }

        // attach: true with launchArgs/launchFiles — those fields are ignored.
        if plan.target.attach == true {
            if plan.target.launchArgs != nil {
                findings.append(.init(severity: .warning, stepId: nil,
                    message: "`target.launchArgs` is ignored when `attach: true` — the app is already running"))
            }
            if plan.target.launchFiles != nil {
                findings.append(.init(severity: .warning, stepId: nil,
                    message: "`target.launchFiles` is ignored when `attach: true` — open files before running the plan"))
            }
        }

        // No window wait before the first input/assert step.
        let inputActions: Set<Action> = [.click, .doubleClick, .rightClick, .press,
                                         .type, .keyPress, .setValue, .scroll, .drag, .menu]
        if let firstInputIdx = plan.steps.firstIndex(where: { inputActions.contains($0.action) }) {
            let waitsBefore = plan.steps[..<firstInputIdx].contains {
                $0.action == .waitFor && $0.target?.role == "AXWindow"
            }
            if !waitsBefore {
                findings.append(.init(severity: .warning, stepId: plan.steps[firstInputIdx].id,
                    message: "no `waitFor` on an AXWindow before the first input step — the app may not be ready"))
            }
        }

        return findings
    }
}
