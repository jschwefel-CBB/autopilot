import Foundation
import ApplicationServices

public struct RunOptions {
    public var keepGoing: Bool
    public var artifactsDir: URL
    /// Directory of the plan file, used to resolve relative vision-template paths.
    public var planBaseDir: URL?
    /// Write/overwrite snapshot reference images. When false (default), a missing
    /// reference is a FAILURE, not a silent pass — the standard snapshot convention.
    public var updateSnapshots: Bool
    public init(keepGoing: Bool = false, artifactsDir: URL, planBaseDir: URL? = nil,
                updateSnapshots: Bool = false) {
        self.keepGoing = keepGoing; self.artifactsDir = artifactsDir
        self.planBaseDir = planBaseDir; self.updateSnapshots = updateSnapshots
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

    /// A filesystem-safe slug for a plan name, for per-plan artifact directories.
    static func slug(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let lowered = name.lowercased().map { allowed.contains($0) ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "plan" : collapsed
    }

    /// Parse-and-run is the caller's job for include base-dir reasons; this takes a resolved Plan.
    public func run(_ plan: Plan, options callerOptions: RunOptions) throws -> Report {
        // Namespace artifacts under a per-plan subdirectory so concurrent or
        // sequential multi-plan runs into one artifacts root don't clobber each
        // other's report.json / screenshots / AX dumps.
        var options = callerOptions
        options.artifactsDir = callerOptions.artifactsDir.appendingPathComponent(Self.slug(plan.name))

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
        // Bring the app frontmost and wait until it is key, so the first
        // synthesized keystroke/click is not dropped on a not-yet-active window.
        _ = launcher.activate(launched, timeoutMs: timeoutMs, intervalMs: intervalMs, clock: clock)

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
                let shot = captureFailureShot(step.id, dir: options.artifactsDir)
                // A targeting failure (element not found / ambiguous / timed out)
                // means the app's UI wasn't as the plan expected — that's a test
                // FAILURE. Everything else (launch failure, AX action failure,
                // unsupported key) is an infrastructure ERROR.
                let outcome: StepOutcome = (error is TargetingError) ? .fail : .error
                report.add(StepResult(id: step.id, result: outcome, durationMs: dur,
                                      message: String(describing: error),
                                      screenshot: shot, axDump: dump))
                if !options.keepGoing { break }
            }
        }
        report.finalize(permissions: perm)
        report.artifactsDir = options.artifactsDir.path
        // Write report.json into the per-plan artifacts dir so it travels with
        // its screenshots/AX dumps and never clobbers another plan's report.
        // Surface a write failure (e.g. unwritable artifacts dir) instead of
        // silently losing the report.
        do { try reporter.write(report, to: options.artifactsDir) }
        catch {
            FileHandle.standardError.write(Data(
                "autopilot: failed to write report.json to \(options.artifactsDir.path): \(error)\n".utf8))
        }
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
        case .assertPixel:
            return try runAssertPixel(step, app: app, targeting: targeting,
                                      timeoutMs: timeoutMs, intervalMs: intervalMs, options: options)
        case .assertRegion:
            return try runAssertRegion(step, app: app, targeting: targeting,
                                       timeoutMs: timeoutMs, intervalMs: intervalMs, options: options)
        case .snapshot:
            return try runSnapshot(step, app: app, targeting: targeting,
                                   timeoutMs: timeoutMs, intervalMs: intervalMs, options: options)
        case .menu:
            guard let path = step.args?.menuPath, !path.isEmpty else {
                throw PlanError.decode("menu needs args.menuPath")
            }
            try MenuNavigator().selectPath(path, app: app)
            return StepResult(id: step.id, result: .pass, durationMs: 0)
        case .drag:
            // File drag-and-drop (dragging external files onto a control) cannot
            // be synthesized with mouse events — it requires a real NSPasteboard
            // drag session the OS originates. Fail clearly rather than no-op.
            if step.args?.toFiles != nil {
                return StepResult(id: step.id, result: .error, durationMs: 0,
                    message: "file drag-and-drop is not supported via synthesized events; " +
                             "open files with target.launchFiles instead, or test the drop handler headlessly")
            }
            let ref = try targeting.resolve(step.target!, app: app,
                                            timeoutMs: timeoutMs, intervalMs: intervalMs,
                                            baseDir: options.planBaseDir)
            guard let dest = step.args?.to else { throw PlanError.decode("drag needs args.to or args.toFiles") }
            let destRef = try targeting.resolve(dest, app: app,
                                                timeoutMs: timeoutMs, intervalMs: intervalMs,
                                                baseDir: options.planBaseDir)
            guard let from = actions.point(for: ref), let to = actions.point(for: destRef) else {
                throw PlanError.decode("drag needs resolvable source and destination points")
            }
            EventSynthesizer.drag(from: from, to: to)
            return StepResult(id: step.id, result: .pass, durationMs: 0)
        case .click, .doubleClick, .rightClick, .press, .type, .keyPress, .setValue, .scroll:
            let ref = try targeting.resolve(step.target!, app: app,
                                            timeoutMs: timeoutMs, intervalMs: intervalMs,
                                            baseDir: options.planBaseDir)
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
                                                       timeoutMs: timeoutMs, intervalMs: intervalMs,
                                                       baseDir: options.planBaseDir) else {
            return StepResult(id: step.id, result: .fail, durationMs: 0,
                              message: "cannot assert property on vision-only element")
        }
        let expected = assertion.expected ?? ""
        // Poll the comparison on the same cadence as presence — a control's AX
        // value may update a beat after the action that triggered it. Succeed as
        // soon as it matches; only fail (and capture artifacts) at timeout.
        let outcome = assertions.pollEvaluate(
            op: assertion.op, expected: expected,
            timeoutMs: timeoutMs, intervalMs: intervalMs, clock: clock
        ) { assertions.readProperty(assertion.property, from: el) ?? "" }

        var result = StepResult(id: step.id, result: outcome.matched ? .pass : .fail, durationMs: 0,
                                expected: expected, actual: outcome.actual)
        if !outcome.matched {
            result.axDump = writeAXDump(app, stepId: step.id, dir: options.artifactsDir)
            result.screenshot = captureFailureShot(step.id, dir: options.artifactsDir)
        }
        return result
    }

    /// Assert a screen pixel's color — for visual features the AX API can't see
    /// (syntax colors, rainbow brackets, gutters). Samples at the target's center
    /// plus (offsetX,offsetY), or an absolute (atX,atY) when no target is given.
    private func runAssertPixel(_ step: Step, app: AXUIElement, targeting: Targeting,
                                timeoutMs: Int, intervalMs: Int, options: RunOptions) throws -> StepResult {
        let args = step.args
        guard let hex = args?.color, let expected = PixelColor.parseHex(hex) else {
            throw PlanError.decode("assertPixel needs args.color (#RRGGBB)")
        }
        if let err = screenRecordingError(step.id) { return err }
        let tolerance = args?.tolerance ?? 16

        // Determine the sample point.
        let point: CGPoint
        if let ax = step.target {
            let ref = try targeting.resolve(ax, app: app, timeoutMs: timeoutMs,
                                            intervalMs: intervalMs, baseDir: options.planBaseDir)
            guard let center = actions.point(for: ref) else {
                throw PlanError.decode("assertPixel target has no resolvable point")
            }
            point = CGPoint(x: center.x + CGFloat(args?.offsetX ?? 0),
                            y: center.y + CGFloat(args?.offsetY ?? 0))
        } else if let ax = args?.atX, let ay = args?.atY {
            point = CGPoint(x: ax, y: ay)
        } else {
            throw PlanError.decode("assertPixel needs a target or absolute at(X,Y)")
        }

        // Poll: the color may settle a frame after the action that produced it.
        var lastActual = PixelColor.RGB(r: -1, g: -1, b: -1)
        let matched = Poller(clock: clock).waitUntil(timeoutMs: timeoutMs, intervalMs: intervalMs) {
            guard let actual = PixelColor.sample(at: point) else { return false }
            lastActual = actual
            return PixelColor.matches(actual, expected, tolerance: tolerance)
        }
        let actualHex = String(format: "#%02X%02X%02X", lastActual.r, lastActual.g, lastActual.b)
        var result = StepResult(id: step.id, result: matched ? .pass : .fail, durationMs: 0,
                                expected: "\(hex) ±\(Int(tolerance))", actual: actualHex)
        if !matched {
            result.screenshot = captureFailureShot(step.id, dir: options.artifactsDir)
        }
        return result
    }

    /// Assert the average or dominant color over a rectangle — robust where a
    /// single-pixel `assertPixel` is fragile (thin anti-aliased glyphs). The rect
    /// is `width`×`height` centered on the target (+offset) or at absolute (atX,atY).
    private func runAssertRegion(_ step: Step, app: AXUIElement, targeting: Targeting,
                                 timeoutMs: Int, intervalMs: Int, options: RunOptions) throws -> StepResult {
        let args = step.args
        guard let hex = args?.color, let expected = PixelColor.parseHex(hex) else {
            throw PlanError.decode("assertRegion needs args.color (#RRGGBB)")
        }
        if let err = screenRecordingError(step.id) { return err }
        let tolerance = args?.tolerance ?? 24
        let w = args?.width ?? 8, h = args?.height ?? 8
        let dominant = (args?.mode ?? "average") == "dominant"

        let center: CGPoint
        if let ax = step.target {
            let ref = try targeting.resolve(ax, app: app, timeoutMs: timeoutMs,
                                            intervalMs: intervalMs, baseDir: options.planBaseDir)
            guard let c = actions.point(for: ref) else {
                throw PlanError.decode("assertRegion target has no resolvable point")
            }
            center = CGPoint(x: c.x + CGFloat(args?.offsetX ?? 0), y: c.y + CGFloat(args?.offsetY ?? 0))
        } else if let ax = args?.atX, let ay = args?.atY {
            center = CGPoint(x: ax, y: ay)
        } else {
            throw PlanError.decode("assertRegion needs a target or absolute at(X,Y)")
        }
        let rect = CGRect(x: center.x - CGFloat(w) / 2, y: center.y - CGFloat(h) / 2,
                          width: CGFloat(w), height: CGFloat(h))

        var lastActual = PixelColor.RGB(r: -1, g: -1, b: -1)
        let matched = Poller(clock: clock).waitUntil(timeoutMs: timeoutMs, intervalMs: intervalMs) {
            let pixels = PixelColor.sampleRegion(rect)
            guard let c = dominant ? PixelColor.dominant(of: pixels) : PixelColor.average(of: pixels) else { return false }
            lastActual = c
            return PixelColor.matches(c, expected, tolerance: tolerance)
        }
        let actualHex = String(format: "#%02X%02X%02X", lastActual.r, lastActual.g, lastActual.b)
        var result = StepResult(id: step.id, result: matched ? .pass : .fail, durationMs: 0,
                                expected: "\(hex) ±\(Int(tolerance)) (\(dominant ? "dominant" : "average"))",
                                actual: actualHex)
        if !matched {
            result.screenshot = captureFailureShot(step.id, dir: options.artifactsDir)
        }
        return result
    }

    /// Region snapshot test: capture a rectangle; if no reference exists yet,
    /// write it and pass (baseline established). Otherwise compare and fail if
    /// more than `maxDiff` of pixels differ.
    private func runSnapshot(_ step: Step, app: AXUIElement, targeting: Targeting,
                             timeoutMs: Int, intervalMs: Int, options: RunOptions) throws -> StepResult {
        let args = step.args
        guard let refRel = args?.reference else {
            throw PlanError.decode("snapshot needs args.reference (path to the reference PNG)")
        }
        if let err = screenRecordingError(step.id) { return err }
        // Resolve the reference relative to the plan dir (like include/vision).
        let refPath = (options.planBaseDir.map { Targeting.resolveImagePath(refRel, baseDir: $0) }) ?? refRel
        let maxDiff = args?.maxDiff ?? 0.02
        let w = args?.width ?? 64, h = args?.height ?? 32

        let center: CGPoint
        if let ax = step.target {
            let ref = try targeting.resolve(ax, app: app, timeoutMs: timeoutMs,
                                            intervalMs: intervalMs, baseDir: options.planBaseDir)
            guard let c = actions.point(for: ref) else { throw PlanError.decode("snapshot target has no point") }
            center = CGPoint(x: c.x + CGFloat(args?.offsetX ?? 0), y: c.y + CGFloat(args?.offsetY ?? 0))
        } else if let ax = args?.atX, let ay = args?.atY {
            center = CGPoint(x: ax, y: ay)
        } else {
            throw PlanError.decode("snapshot needs a target or absolute at(X,Y)")
        }
        let rect = CGRect(x: center.x - CGFloat(w) / 2, y: center.y - CGFloat(h) / 2,
                          width: CGFloat(w), height: CGFloat(h))

        // Missing reference: only write it when explicitly updating snapshots.
        // Otherwise this is a FAILURE — a silent first-run "pass" would let a bad
        // or absent baseline slip through (standard snapshot-testing convention).
        if !FileManager.default.fileExists(atPath: refPath) {
            guard options.updateSnapshots else {
                return StepResult(id: step.id, result: .fail, durationMs: 0,
                                  expected: "reference at \(refRel)",
                                  actual: "missing",
                                  message: "no reference image; re-run with --update-snapshots to create it")
            }
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: refPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            let ok = Screenshot.captureRegion(rect, to: refPath)
            return StepResult(id: step.id, result: ok ? .pass : .error, durationMs: 0,
                              message: ok ? "reference written: \(refPath)" : "failed to write reference")
        }
        // Updating: overwrite the reference and pass.
        if options.updateSnapshots {
            let ok = Screenshot.captureRegion(rect, to: refPath)
            return StepResult(id: step.id, result: ok ? .pass : .error, durationMs: 0,
                              message: ok ? "reference updated: \(refPath)" : "failed to update reference")
        }

        // Subsequent runs: capture live and diff against the reference.
        let livePath = options.artifactsDir.appendingPathComponent("\(step.id).live.png").path
        try? FileManager.default.createDirectory(at: options.artifactsDir, withIntermediateDirectories: true)
        guard Screenshot.captureRegion(rect, to: livePath),
              let live = PixelColor.loadPNG(livePath),
              let ref = PixelColor.loadPNG(refPath) else {
            return StepResult(id: step.id, result: .error, durationMs: 0, message: "snapshot capture/load failed")
        }
        let frac = PixelColor.diffFraction(ref, live, perPixelTolerance: 24)
        let ok = frac <= maxDiff
        return StepResult(id: step.id, result: ok ? .pass : .fail, durationMs: 0,
                          expected: "≤\(maxDiff) diff", actual: String(format: "%.3f diff", frac),
                          screenshot: ok ? nil : livePath)
    }

    /// Capture a failure screenshot; return its path only if the write actually
    /// succeeded, so the report never points at a file that doesn't exist.
    private func captureFailureShot(_ stepId: String, dir: URL) -> String? {
        let shot = dir.appendingPathComponent("\(stepId).png").path
        return Screenshot.captureMainDisplay(to: shot) ? shot : nil
    }

    /// Visual actions require Screen Recording. If it's missing, return a clear
    /// `.error` rather than letting the capture silently yield no pixels and the
    /// assertion poll to a misleading `.fail` with a bogus actual color.
    private func screenRecordingError(_ stepId: String) -> StepResult? {
        guard !permissions.hasScreenRecording() else { return nil }
        return StepResult(id: stepId, result: .error, durationMs: 0,
                          message: permissions.screenRecordingInstructions())
    }

    private func writeAXDump(_ app: AXUIElement, stepId: String, dir: URL) -> String? {
        let snap = AXTree.snapshot(app)
        let payload: [String: Any] = [
            "truncated": snap.truncated,   // never let a capped tree look complete
            "nodeCount": snap.nodes.count,
            "nodes": snap.nodes,
        ]
        let url = dir.appendingPathComponent("\(stepId).axtree.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: url)
            return url.path
        } catch { return nil }
    }
}
