import Foundation

public struct RunOptions {
    public var keepGoing: Bool
    public var artifactsDir: URL
    /// Directory of the plan file, used to resolve relative vision-template paths.
    public var planBaseDir: URL?
    /// Write/overwrite snapshot reference images. When false (default), a missing
    /// reference is a FAILURE, not a silent pass — the standard snapshot convention.
    public var updateSnapshots: Bool
    /// Human-readable plan name, threaded into PNG tEXt metadata on failure shots.
    /// Set automatically by PlanRunner.run(_:options:) from plan.name.
    var planName: String = ""
    public init(keepGoing: Bool = false, artifactsDir: URL, planBaseDir: URL? = nil,
                updateSnapshots: Bool = false) {
        self.keepGoing = keepGoing; self.artifactsDir = artifactsDir
        self.planBaseDir = planBaseDir; self.updateSnapshots = updateSnapshots
    }
}

public struct PlanRunner {
    let driver: any AppDriver
    let clock: Clock
    let assertions = AssertionEngine()   // now pure: evaluate/pollEvaluate only
    let reporter = Reporter()

    public init(driver: any AppDriver, clock: Clock = SystemClock()) {
        self.driver = driver; self.clock = clock
    }

    /// Resolve a vision/snapshot template path: absolute paths are used as-is;
    /// relative paths resolve against the plan's directory (matching `include`),
    /// falling back to the current working directory when no base is known.
    public static func resolveImagePath(_ image: String, baseDir: URL?) -> String {
        if image.hasPrefix("/") { return image }
        if let baseDir { return baseDir.appendingPathComponent(image).path }
        return image
    }

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
        options.planName = plan.name

        var report = Report(plan: plan.name)
        let hasAX = driver.hasAccessibility()
        let perm = PermissionStatus(accessibility: hasAX, screenRecording: driver.hasScreenRecording())

        guard hasAX else {
            report.add(StepResult(id: "_preflight", result: .error, durationMs: 0,
                                  message: driver.accessibilityInstructions()))
            report.finalize(permissions: perm)
            return report
        }

        let defaults = plan.defaults
        let timeoutMs = defaults?.timeoutMs ?? 5000
        let intervalMs = defaults?.retryIntervalMs ?? 100

        let app: LaunchedHandle
        if plan.target.attach == true {
            // Attach mode: use the frontmost already-running instance without
            // terminating/relaunching it. The caller is responsible for having
            // the app in the desired state before running the plan.
            app = try driver.attach(plan.target)
        } else {
            app = try driver.launch(plan.target)
        }
        defer { /* leave app running unless a terminate step ran; harmless for tests */ }
        // Give the app a beat to register its AX tree (polled, not a fixed sleep).
        _ = driver.waitForPresence(Selector(role: "AXWindow"), present: true,
                                   app: app, timeoutMs: timeoutMs, intervalMs: intervalMs)
        // Bring the app frontmost and wait until it is key, so the first
        // synthesized keystroke/click is not dropped on a not-yet-active window.
        _ = driver.activate(app, timeoutMs: timeoutMs, intervalMs: intervalMs)

        for step in plan.steps {
            let stepTimeout = step.timeoutMs ?? timeoutMs
            let start = clock.now()
            do {
                let result = try runStep(step, app: app, timeoutMs: stepTimeout,
                                         intervalMs: intervalMs, options: options)
                let dur = Int((clock.now() - start) * 1000)
                var r = result; r.durationMs = dur
                // captureTarget: crop + save a screenshot of the step's target
                // element on ANY outcome (pass or fail) when the author opts in.
                if step.captureTarget == true, let t = step.target,
                   case .element(let h)? = try? driver.resolve(t, app: app,
                                                               timeoutMs: stepTimeout, intervalMs: intervalMs,
                                                               baseDir: options.planBaseDir) {
                    let shotPath = options.artifactsDir
                        .appendingPathComponent("\(step.id)-target.png").path
                    let padding = Int(step.args?.padding ?? 8)
                    let outcome = r.result == .pass ? "pass" : "fail"
                    let meta = stepMetadata(step, plan: options.planName)
                        .merging(["autopilot-result": outcome]) { _, new in new }
                    if driver.captureElementScreenshot(h, to: shotPath, padding: padding, metadata: meta) == nil {
                        r.screenshot = r.screenshot ?? shotPath
                    }
                }
                report.add(r)
                if r.result != .pass && !options.keepGoing { break }
            } catch {
                let dur = Int((clock.now() - start) * 1000)
                let dump = writeAXDump(app, stepId: step.id, dir: options.artifactsDir)
                // Full-display failure shot (always).
                var shot = captureFailureShot(step.id, dir: options.artifactsDir,
                                              step: step, planName: options.planName)
                // If the step had a target and we can still resolve it, also save
                // a tighter element-scoped crop as "<id>-target.png". Useful when
                // the element is visible but had wrong content.
                if let t = step.target,
                   case .element(let h)? = try? driver.resolve(t, app: app,
                                                              timeoutMs: stepTimeout, intervalMs: intervalMs,
                                                              baseDir: options.planBaseDir) {
                    let elShot = options.artifactsDir.appendingPathComponent("\(step.id)-target.png").path
                    let meta = stepMetadata(step, plan: plan.name).merging(["autopilot-result": "fail"]) { _, new in new }
                    if driver.captureElementScreenshot(h, to: elShot, padding: Int(step.args?.padding ?? 8), metadata: meta) == nil {
                        shot = shot ?? elShot
                    }
                }
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

    private func runStep(_ step: Step, app: LaunchedHandle, timeoutMs: Int, intervalMs: Int,
                         options: RunOptions) throws -> StepResult {
        switch step.action {
        case .launch:
            return StepResult(id: step.id, result: .pass, durationMs: 0)
        case .terminate:
            driver.terminate(app)
            return StepResult(id: step.id, result: .pass, durationMs: 0)
        case .wait:
            clock.sleep(step.args?.seconds ?? 0)
            return StepResult(id: step.id, result: .pass, durationMs: 0)
        case .screenshot:
            let path = step.args?.path ?? options.artifactsDir.appendingPathComponent("\(step.id).png").path
            let padding = Int(step.args?.padding ?? 0)
            let meta = stepMetadata(step, plan: options.planName)
            let ok: Bool
            var fallbackMessage: String? = nil
            if let t = step.target {
                // Resolve the target; if it fails, fall back to full display and
                // record a message so the author knows the crop didn't happen.
                if case .element(let h)? = try? driver.resolve(t, app: app,
                                                              timeoutMs: timeoutMs, intervalMs: intervalMs,
                                                              baseDir: options.planBaseDir) {
                    if let reason = driver.captureElementScreenshot(h, to: path, padding: padding, metadata: meta) {
                        // Element resolved but crop failed — fall back to full display.
                        fallbackMessage = "element crop failed (\(reason)); fell back to full display"
                        ok = driver.captureMainDisplay(to: path, metadata: meta)
                    } else {
                        ok = true
                    }
                } else {
                    fallbackMessage = "target did not resolve; fell back to full display"
                    ok = driver.captureMainDisplay(to: path, metadata: meta)
                }
            } else if let ax = step.args?.atX, let ay = step.args?.atY,
                      let w = step.args?.width, let h = step.args?.height {
                // Absolute region capture.
                let rect = Rect(x: Double(ax), y: Double(ay), width: Double(w), height: Double(h))
                ok = driver.captureRegion(rect, to: path, metadata: meta)
            } else {
                // Full display.
                ok = driver.captureMainDisplay(to: path, metadata: meta)
            }
            return StepResult(id: step.id, result: ok ? .pass : .fail, durationMs: 0,
                              message: fallbackMessage, screenshot: ok ? path : nil)
        case .waitFor:
            let present = step.args?.present ?? true
            let ok = driver.waitForPresence(step.target!, present: present, app: app,
                                            timeoutMs: timeoutMs, intervalMs: intervalMs)
            return StepResult(id: step.id, result: ok ? .pass : .fail, durationMs: 0,
                              message: ok ? nil : "element \(present ? "did not appear" : "did not disappear")")
        case .assert:
            return try runAssert(step, app: app, timeoutMs: timeoutMs, intervalMs: intervalMs, options: options)
        case .assertPixel:
            return try runAssertPixel(step, app: app, timeoutMs: timeoutMs, intervalMs: intervalMs, options: options)
        case .assertRegion:
            return try runAssertRegion(step, app: app, timeoutMs: timeoutMs, intervalMs: intervalMs, options: options)
        case .snapshot:
            return try runSnapshot(step, app: app, timeoutMs: timeoutMs, intervalMs: intervalMs, options: options)
        case .menu:
            guard let path = step.args?.menuPath, !path.isEmpty else {
                throw PlanError.decode("menu needs args.menuPath")
            }
            try driver.selectMenuPath(path, app: app)
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
            let ref = try driver.resolve(step.target!, app: app,
                                         timeoutMs: timeoutMs, intervalMs: intervalMs,
                                         baseDir: options.planBaseDir)
            guard let dest = step.args?.to else { throw PlanError.decode("drag needs args.to or args.toFiles") }
            let destRef = try driver.resolve(dest, app: app,
                                             timeoutMs: timeoutMs, intervalMs: intervalMs,
                                             baseDir: options.planBaseDir)
            guard let from = driver.point(for: ref), let to = driver.point(for: destRef) else {
                throw PlanError.decode("drag needs resolvable source and destination points")
            }
            try driver.performDrag(from: from, to: to)
            return StepResult(id: step.id, result: .pass, durationMs: 0)
        case .click, .doubleClick, .rightClick, .press, .type, .keyPress, .setValue, .scroll:
            let ref = try driver.resolve(step.target!, app: app,
                                         timeoutMs: timeoutMs, intervalMs: intervalMs,
                                         baseDir: options.planBaseDir)
            try driver.perform(action: step.action, args: step.args, on: ref)
            return StepResult(id: step.id, result: .pass, durationMs: 0)
        }
    }

    private func runAssert(_ step: Step, app: LaunchedHandle,
                           timeoutMs: Int, intervalMs: Int, options: RunOptions) throws -> StepResult {
        let assertion = step.assert!
        // exists / notExists assert on presence, not property value.
        if assertion.op == .exists || assertion.op == .notExists {
            let present = assertion.op == .exists
            let ok = driver.waitForPresence(step.target!, present: present, app: app,
                                            timeoutMs: timeoutMs, intervalMs: intervalMs)
            return StepResult(id: step.id, result: ok ? .pass : .fail, durationMs: 0,
                              expected: present ? "exists" : "notExists",
                              actual: ok ? (present ? "exists" : "notExists") : (present ? "notExists" : "exists"))
        }
        // `count` asserts the number of matching elements — relaxing the single-
        // match rule so you can test collections ("5 results", "2 cart items").
        if assertion.property == .count {
            let expected = assertion.expected ?? ""
            let outcome = assertions.pollEvaluate(
                op: assertion.op, expected: expected,
                timeoutMs: timeoutMs, intervalMs: intervalMs, clock: clock
            ) { String(driver.matchCount(step.target!, app: app)) }
            return StepResult(id: step.id, result: outcome.matched ? .pass : .fail, durationMs: 0,
                              expected: expected, actual: outcome.actual)
        }
        guard case .element(let h) = try driver.resolve(step.target!, app: app,
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
        ) { driver.readProperty(assertion.property, of: h) ?? "" }

        var result = StepResult(id: step.id, result: outcome.matched ? .pass : .fail, durationMs: 0,
                                expected: expected, actual: outcome.actual)
        if !outcome.matched {
            result.axDump = writeAXDump(app, stepId: step.id, dir: options.artifactsDir)
            result.screenshot = captureFailureShot(step.id, dir: options.artifactsDir,
                                                   step: step, planName: options.planName)
        }
        return result
    }

    /// Assert a screen pixel's color — for visual features the AX API can't see
    /// (syntax colors, rainbow brackets, gutters). Samples at the target's center
    /// plus (offsetX,offsetY), or an absolute (atX,atY) when no target is given.
    private func runAssertPixel(_ step: Step, app: LaunchedHandle,
                                timeoutMs: Int, intervalMs: Int, options: RunOptions) throws -> StepResult {
        let args = step.args
        guard let hex = args?.color, let expected = PixelColor.parseHex(hex) else {
            throw PlanError.decode("assertPixel needs args.color (#RRGGBB)")
        }
        if let err = screenRecordingError(step.id) { return err }
        let tolerance = args?.tolerance ?? 16

        // Determine the sample point.
        let point: Point
        if let ax = step.target {
            let ref = try driver.resolve(ax, app: app, timeoutMs: timeoutMs,
                                         intervalMs: intervalMs, baseDir: options.planBaseDir)
            guard let center = driver.point(for: ref) else {
                throw PlanError.decode("assertPixel target has no resolvable point")
            }
            point = Point(x: center.x + Double(args?.offsetX ?? 0),
                          y: center.y + Double(args?.offsetY ?? 0))
        } else if let ax = args?.atX, let ay = args?.atY {
            point = Point(x: Double(ax), y: Double(ay))
        } else {
            throw PlanError.decode("assertPixel needs a target or absolute at(X,Y)")
        }

        // Poll: the color may settle a frame after the action that produced it.
        var lastActual = PixelColor.RGB(r: -1, g: -1, b: -1)
        let matched = Poller(clock: clock).waitUntil(timeoutMs: timeoutMs, intervalMs: intervalMs) {
            guard let actual = driver.samplePixel(at: point) else { return false }
            lastActual = PixelColor.RGB(actual)
            return PixelColor.matches(lastActual, expected, tolerance: tolerance)
        }
        let actualHex = String(format: "#%02X%02X%02X", lastActual.r, lastActual.g, lastActual.b)
        var result = StepResult(id: step.id, result: matched ? .pass : .fail, durationMs: 0,
                                expected: "\(hex) ±\(Int(tolerance))", actual: actualHex)
        if !matched {
            result.screenshot = captureFailureShot(step.id, dir: options.artifactsDir,
                                                   step: step, planName: options.planName)
        }
        return result
    }

    /// Assert the average or dominant color over a rectangle — robust where a
    /// single-pixel `assertPixel` is fragile (thin anti-aliased glyphs). The rect
    /// is `width`×`height` centered on the target (+offset) or at absolute (atX,atY).
    private func runAssertRegion(_ step: Step, app: LaunchedHandle,
                                 timeoutMs: Int, intervalMs: Int, options: RunOptions) throws -> StepResult {
        let args = step.args
        guard let hex = args?.color, let expected = PixelColor.parseHex(hex) else {
            throw PlanError.decode("assertRegion needs args.color (#RRGGBB)")
        }
        if let err = screenRecordingError(step.id) { return err }
        let tolerance = args?.tolerance ?? 24
        let w = args?.width ?? 8, h = args?.height ?? 8
        let dominant = (args?.mode ?? "average") == "dominant"

        let center: Point
        if let ax = step.target {
            let ref = try driver.resolve(ax, app: app, timeoutMs: timeoutMs,
                                         intervalMs: intervalMs, baseDir: options.planBaseDir)
            guard let c = driver.point(for: ref) else {
                throw PlanError.decode("assertRegion target has no resolvable point")
            }
            center = Point(x: c.x + Double(args?.offsetX ?? 0), y: c.y + Double(args?.offsetY ?? 0))
        } else if let ax = args?.atX, let ay = args?.atY {
            center = Point(x: Double(ax), y: Double(ay))
        } else {
            throw PlanError.decode("assertRegion needs a target or absolute at(X,Y)")
        }
        let rect = Rect(x: center.x - Double(w) / 2, y: center.y - Double(h) / 2,
                        width: Double(w), height: Double(h))

        var lastActual = PixelColor.RGB(r: -1, g: -1, b: -1)
        let matched = Poller(clock: clock).waitUntil(timeoutMs: timeoutMs, intervalMs: intervalMs) {
            let pixels = driver.sampleRegion(rect).map { PixelColor.RGB($0) }
            guard let c = dominant ? PixelColor.dominant(of: pixels) : PixelColor.average(of: pixels) else { return false }
            lastActual = c
            return PixelColor.matches(c, expected, tolerance: tolerance)
        }
        let actualHex = String(format: "#%02X%02X%02X", lastActual.r, lastActual.g, lastActual.b)
        var result = StepResult(id: step.id, result: matched ? .pass : .fail, durationMs: 0,
                                expected: "\(hex) ±\(Int(tolerance)) (\(dominant ? "dominant" : "average"))",
                                actual: actualHex)
        if !matched {
            result.screenshot = captureFailureShot(step.id, dir: options.artifactsDir,
                                                   step: step, planName: options.planName)
        }
        return result
    }

    /// Region snapshot test: capture a rectangle; if no reference exists yet,
    /// write it and pass (baseline established). Otherwise compare and fail if
    /// more than `maxDiff` of pixels differ.
    private func runSnapshot(_ step: Step, app: LaunchedHandle,
                             timeoutMs: Int, intervalMs: Int, options: RunOptions) throws -> StepResult {
        let args = step.args
        guard let refRel = args?.reference else {
            throw PlanError.decode("snapshot needs args.reference (path to the reference PNG)")
        }
        if let err = screenRecordingError(step.id) { return err }
        // Resolve the reference relative to the plan dir (like include/vision).
        let refPath = (options.planBaseDir.map { Self.resolveImagePath(refRel, baseDir: $0) }) ?? refRel
        let maxDiff = args?.maxDiff ?? 0.02
        let w = args?.width ?? 64, h = args?.height ?? 32

        let center: Point
        if let ax = step.target {
            let ref = try driver.resolve(ax, app: app, timeoutMs: timeoutMs,
                                         intervalMs: intervalMs, baseDir: options.planBaseDir)
            guard let c = driver.point(for: ref) else { throw PlanError.decode("snapshot target has no point") }
            center = Point(x: c.x + Double(args?.offsetX ?? 0), y: c.y + Double(args?.offsetY ?? 0))
        } else if let ax = args?.atX, let ay = args?.atY {
            center = Point(x: Double(ax), y: Double(ay))
        } else {
            throw PlanError.decode("snapshot needs a target or absolute at(X,Y)")
        }
        let rect = Rect(x: center.x - Double(w) / 2, y: center.y - Double(h) / 2,
                        width: Double(w), height: Double(h))

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
            let ok = driver.captureRegion(rect, to: refPath, metadata: [:])
            return StepResult(id: step.id, result: ok ? .pass : .error, durationMs: 0,
                              message: ok ? "reference written: \(refPath)" : "failed to write reference")
        }
        // Updating: overwrite the reference and pass.
        if options.updateSnapshots {
            let ok = driver.captureRegion(rect, to: refPath, metadata: [:])
            return StepResult(id: step.id, result: ok ? .pass : .error, durationMs: 0,
                              message: ok ? "reference updated: \(refPath)" : "failed to update reference")
        }

        // Subsequent runs: capture live and diff against the reference.
        let livePath = options.artifactsDir.appendingPathComponent("\(step.id).live.png").path
        try? FileManager.default.createDirectory(at: options.artifactsDir, withIntermediateDirectories: true)
        guard driver.captureRegion(rect, to: livePath, metadata: [:]),
              let live = driver.loadPNG(livePath)?.map({ PixelColor.RGB($0) }),
              let ref = driver.loadPNG(refPath)?.map({ PixelColor.RGB($0) }) else {
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
    /// Build the PNG tEXt metadata dict for a step screenshot.
    private func stepMetadata(_ step: Step, plan: String) -> [String: String] {
        var m: [String: String] = ["autopilot-step": step.id, "autopilot-action": step.action.rawValue]
        if !plan.isEmpty { m["autopilot-plan"] = plan }
        return m
    }

    private func captureFailureShot(_ stepId: String, dir: URL,
                                     step: Step? = nil, planName: String = "") -> String? {
        let shot = dir.appendingPathComponent("\(stepId).png").path
        var meta: [String: String] = ["autopilot-step": stepId, "autopilot-result": "fail"]
        if !planName.isEmpty { meta["autopilot-plan"] = planName }
        if let s = step { meta["autopilot-action"] = s.action.rawValue }
        return driver.captureMainDisplay(to: shot, metadata: meta) ? shot : nil
    }

    /// Visual actions require Screen Recording. If it's missing, return a clear
    /// `.error` rather than letting the capture silently yield no pixels and the
    /// assertion poll to a misleading `.fail` with a bogus actual color.
    private func screenRecordingError(_ stepId: String) -> StepResult? {
        guard !driver.hasScreenRecording() else { return nil }
        return StepResult(id: stepId, result: .error, durationMs: 0,
                          message: driver.screenRecordingInstructions())
    }

    private func writeAXDump(_ app: LaunchedHandle, stepId: String, dir: URL) -> String? {
        let snap = driver.dumpTree(app: app)
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
