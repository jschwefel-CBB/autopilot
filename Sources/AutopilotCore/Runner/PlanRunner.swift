import Foundation
import ApplicationServices

public struct RunOptions {
    public var keepGoing: Bool
    public var artifactsDir: URL
    public init(keepGoing: Bool = false, artifactsDir: URL) {
        self.keepGoing = keepGoing; self.artifactsDir = artifactsDir
    }
}

public struct PlanRunner {
    let clock: Clock
    let permissions = Permissions()
    let launcher = AppLauncher()
    let actions = ActionEngine()
    let assertions = AssertionEngine()
    let reporter = Reporter()

    public init(clock: Clock = SystemClock()) { self.clock = clock }

    /// Parse-and-run is the caller's job for include base-dir reasons; this takes a resolved Plan.
    public func run(_ plan: Plan, options: RunOptions) throws -> Report {
        var report = Report(plan: plan.name)
        let hasAX = permissions.hasAccessibility()
        let perm = PermissionStatus(accessibility: hasAX, automation: true)

        guard hasAX else {
            report.add(StepResult(id: "_preflight", result: .error, durationMs: 0,
                                  message: permissions.accessibilityInstructions()))
            report.finalize(permissions: perm)
            return report
        }

        let defaults = plan.defaults
        let timeoutMs = defaults?.timeoutMs ?? 5000
        let intervalMs = defaults?.retryIntervalMs ?? 100
        let targeting = Targeting(poller: Poller(clock: clock))

        let launched = try launcher.launch(plan.target)
        defer { /* leave app running unless a terminate step ran; harmless for tests */ }
        let appElement = AXTree.application(pid: launched.pid)
        // Give the app a beat to register its AX tree (polled, not a fixed sleep).
        _ = targeting.waitForPresence(Selector(role: "AXWindow"), present: true,
                                      app: appElement, timeoutMs: timeoutMs, intervalMs: intervalMs)

        for step in plan.steps {
            let stepTimeout = step.timeoutMs ?? timeoutMs
            let start = clock.now()
            do {
                let result = try runStep(step, app: appElement, launched: launched,
                                         targeting: targeting, timeoutMs: stepTimeout,
                                         intervalMs: intervalMs, options: options)
                let dur = Int((clock.now() - start) * 1000)
                var r = result; r.durationMs = dur
                report.add(r)
                if r.result != .pass && !options.keepGoing { break }
            } catch {
                let dur = Int((clock.now() - start) * 1000)
                let dump = writeAXDump(appElement, stepId: step.id, dir: options.artifactsDir)
                let shot = options.artifactsDir.appendingPathComponent("\(step.id).png").path
                Screenshot.captureMainDisplay(to: shot)
                report.add(StepResult(id: step.id, result: .error, durationMs: dur,
                                      message: String(describing: error),
                                      screenshot: shot, axDump: dump))
                if !options.keepGoing { break }
            }
        }
        report.finalize(permissions: perm)
        return report
    }

    private func runStep(_ step: Step, app: AXUIElement, launched: LaunchedApp,
                         targeting: Targeting, timeoutMs: Int, intervalMs: Int,
                         options: RunOptions) throws -> StepResult {
        switch step.action {
        case .launch:
            return StepResult(id: step.id, result: .pass, durationMs: 0)
        case .terminate:
            launcher.terminate(launched)
            return StepResult(id: step.id, result: .pass, durationMs: 0)
        case .wait:
            clock.sleep(step.args?.seconds ?? 0)
            return StepResult(id: step.id, result: .pass, durationMs: 0)
        case .screenshot:
            let path = step.args?.path ?? options.artifactsDir.appendingPathComponent("\(step.id).png").path
            let ok = Screenshot.captureMainDisplay(to: path)
            return StepResult(id: step.id, result: ok ? .pass : .fail, durationMs: 0,
                              screenshot: path)
        case .waitFor:
            let present = step.args?.present ?? true
            let ok = targeting.waitForPresence(step.target!, present: present, app: app,
                                               timeoutMs: timeoutMs, intervalMs: intervalMs)
            return StepResult(id: step.id, result: ok ? .pass : .fail, durationMs: 0,
                              message: ok ? nil : "element \(present ? "did not appear" : "did not disappear")")
        case .assert:
            return try runAssert(step, app: app, targeting: targeting,
                                 timeoutMs: timeoutMs, intervalMs: intervalMs, options: options)
        case .click, .doubleClick, .rightClick, .type, .keyPress, .setValue, .scroll:
            let ref = try targeting.resolve(step.target!, app: app,
                                            timeoutMs: timeoutMs, intervalMs: intervalMs)
            try actions.perform(action: step.action, args: step.args, ref: ref)
            return StepResult(id: step.id, result: .pass, durationMs: 0)
        }
    }

    private func runAssert(_ step: Step, app: AXUIElement, targeting: Targeting,
                           timeoutMs: Int, intervalMs: Int, options: RunOptions) throws -> StepResult {
        let assertion = step.assert!
        // exists / notExists assert on presence, not property value.
        if assertion.op == .exists || assertion.op == .notExists {
            let present = assertion.op == .exists
            let ok = targeting.waitForPresence(step.target!, present: present, app: app,
                                               timeoutMs: timeoutMs, intervalMs: intervalMs)
            return StepResult(id: step.id, result: ok ? .pass : .fail, durationMs: 0,
                              expected: present ? "exists" : "notExists",
                              actual: ok ? (present ? "exists" : "notExists") : (present ? "notExists" : "exists"))
        }
        guard case .ax(let el) = try targeting.resolve(step.target!, app: app,
                                                       timeoutMs: timeoutMs, intervalMs: intervalMs) else {
            return StepResult(id: step.id, result: .fail, durationMs: 0,
                              message: "cannot assert property on vision-only element")
        }
        let actual = assertions.readProperty(assertion.property, from: el) ?? ""
        let expected = assertion.expected ?? ""
        let ok = assertions.evaluate(op: assertion.op, actual: actual, expected: expected)
        var result = StepResult(id: step.id, result: ok ? .pass : .fail, durationMs: 0,
                                expected: expected, actual: actual)
        if !ok {
            let dump = writeAXDump(app, stepId: step.id, dir: options.artifactsDir)
            let shot = options.artifactsDir.appendingPathComponent("\(step.id).png").path
            Screenshot.captureMainDisplay(to: shot)
            result.axDump = dump; result.screenshot = shot
        }
        return result
    }

    private func writeAXDump(_ app: AXUIElement, stepId: String, dir: URL) -> String? {
        let snap = AXTree.snapshot(app)
        let url = dir.appendingPathComponent("\(stepId).axtree.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: snap, options: [.prettyPrinted])
            try data.write(to: url)
            return url.path
        } catch { return nil }
    }
}
